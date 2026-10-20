"""
Pre-call tweaks applied to every request that hits the LiteLLM proxy:

1. Always strip Anthropic-proxy-only fields that Bedrock Converse rejects
   even when the target IS a Claude model (e.g. `context_management`).

2. For NON-Claude target models only, strip Claude-specific inference-control
   fields (`adaptive_thinking`, `thinking`) that Bedrock's Qwen / Kimi / GLM
   / DeepSeek endpoints reject. Claude models legitimately consume these —
   do NOT strip them on Anthropic targets, or extended thinking breaks.

   Special-case: `thinking.type == "adaptive"` is ONLY supported on a subset
   of Anthropic models (Sonnet 4.5+, Opus 4.5+). On Claude Haiku 4.5 and on
   any non-Claude target, Bedrock returns 400 "adaptive thinking is not
   supported on this model". Because the `auto` router may land on Haiku,
   we *demote* `type: "adaptive"` to omitted (let the model decide statically)
   on every auto-router entrypoint. Regular explicit Claude calls with
   `type: "enabled"|"disabled"` are left untouched.

3. When the top-level model name is an `auto_router/*` group, rewrite each
   multimodal user `content` array into a single plain string so that
   LiteLLM's AutoRouter.async_pre_routing_hook hands a string to the
   embedding encoder. Cohere Embed v4 on Bedrock rejects list-of-dict input
   with "Malformed request".

   Claude Code in particular sends 3 text blocks per user turn:
     [0] the actual user prompt
     [1] <system-reminder>…available skills…</system-reminder>
     [2] <system-reminder>…codebase context…</system-reminder>
   Joining them all puts the user prompt under thousands of system-reminder
   chars, which destroys routing accuracy (everything lands on Haiku). We
   deliberately DROP any block whose text is wrapped in `<system-reminder>`
   tags before flattening, so only the real query survives.

IMPORTANT:
   The LiteLLM proxy places the ENTIRE parsed request body into
   `data["proxy_server_request"]["body"]`, and stores a reference (not a
   copy) that transitively points back to `data`. Any generic recursive
   walker over `data` will infinite-loop or explode Python's recursion
   limit. Consequence: an earlier `_scrub` implementation silently swallowed
   a `RecursionError` in the broad `except Exception: pass` and NEVER
   removed `thinking`. We now:
     - iterate an explicit safe whitelist of top-level + well-known nested
       locations (no generic recursion into proxy_server_request), and
     - guard all recursion with an `id(obj)` visited set as belt-and-braces.
"""
from litellm.integrations.custom_logger import CustomLogger

ALWAYS_DROP_KEYS = ["context_management"]
# Claude-only inference controls that Bedrock rejects for other models
CLAUDE_ONLY_KEYS = ["adaptive_thinking", "thinking"]
AUTO_ROUTER_PREFIXES = ("auto", "smart-router", "semantic-router")
# Keys that are metadata / cyclic containers LiteLLM populates — never walk
# into them, they may reference `data` itself.
_SKIP_RECURSE_KEYS = frozenset({
    "proxy_server_request",
    "litellm_logging_obj",
    "litellm_metadata",
    "metadata",
    "litellm_params",
    "secret_fields",
    "user_api_key_auth",
    "user_api_key_dict",
})


def _is_claude_model(model_name):
    if not isinstance(model_name, str):
        return False
    n = model_name.lower()
    return ("claude" in n) or ("anthropic" in n)


def _is_auto_router(model_name):
    if not isinstance(model_name, str):
        return False
    n = model_name.lower()
    return any(n == p or n.startswith(p + "-") or n.startswith(p + "/")
               for p in AUTO_ROUTER_PREFIXES)


def _scrub(obj, drop_keys, _seen=None):
    """Recursively remove keys in `drop_keys` from nested dicts/lists.
    Skips proxy-metadata containers and self-referential cycles."""
    if _seen is None:
        _seen = set()
    oid = id(obj)
    if oid in _seen:
        return
    if isinstance(obj, (dict, list)):
        _seen.add(oid)
    if isinstance(obj, dict):
        for k in list(obj.keys()):
            if k in drop_keys:
                obj.pop(k, None)
                continue
            if k in _SKIP_RECURSE_KEYS:
                continue
            _scrub(obj[k], drop_keys, _seen)
    elif isinstance(obj, list):
        for item in obj:
            _scrub(item, drop_keys, _seen)


def _scrub_body_aliases(data, drop_keys):
    """Also scrub the parsed body copy that the proxy squirrels away under
    `data["proxy_server_request"]["body"]`. This copy is what some
    passthrough code paths re-read, so top-level removal alone is not
    always enough. Uses shallow access (no generic recursion)."""
    if not isinstance(data, dict):
        return
    psr = data.get("proxy_server_request")
    if isinstance(psr, dict):
        body = psr.get("body")
        if isinstance(body, dict):
            for k in drop_keys:
                body.pop(k, None)


def _downgrade_adaptive_thinking(data):
    """If `thinking.type == 'adaptive'` and the request enters via an
    auto-router (which may route to Haiku 4.5 — adaptive unsupported),
    drop the `thinking` field entirely so Bedrock doesn't 400.

    Done on top-level and on the proxy_server_request.body alias."""
    def _maybe_drop(container):
        if not isinstance(container, dict):
            return
        th = container.get("thinking")
        if isinstance(th, dict) and th.get("type") in ("adaptive", "auto"):
            container.pop("thinking", None)

    _maybe_drop(data)
    if isinstance(data, dict):
        psr = data.get("proxy_server_request")
        if isinstance(psr, dict):
            _maybe_drop(psr.get("body"))


def _is_system_reminder(text):
    if not isinstance(text, str):
        return False
    s = text.lstrip()
    return s.startswith("<system-reminder>")


def _flatten_routing_text(content):
    """
    Turn a user message `content` into a plain routing string.

    Rules:
      - If content is already a str, return it.
      - If content is a list of blocks, concatenate text from blocks that are
        NOT wrapped in `<system-reminder>`. If nothing remains, fall back to
        concatenating every text block.
    """
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        texts = []
        for blk in content:
            if isinstance(blk, dict) and isinstance(blk.get("text"), str):
                texts.append(blk["text"])
            elif isinstance(blk, str):
                texts.append(blk)
        real = [t for t in texts if not _is_system_reminder(t)]
        return "\n".join(real if real else texts)
    return str(content)


def _sanitize_history_for_non_claude(messages):
    """
    Non-Claude Bedrock models (DeepSeek R1, Qwen, Kimi, GLM, Mistral) reject
    content blocks that Anthropic produces on reasoning turns:

      - `type: "thinking"` — non-Claude targets don't understand it
      - `type: "text"` with empty `text` — Bedrock Converse errors:
           "The text field in the ContentBlock object at messages.N.content.K
            is blank. Add text to the text field, and try again."

    When Claude Code replays history with prior assistant turns that contain
    these blocks (very common on DeepSeek R1 after the first turn), the call
    fails. Filter them out before dispatch.
    """
    if not isinstance(messages, list):
        return
    for msg in messages:
        if not isinstance(msg, dict):
            continue
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        cleaned = []
        for blk in content:
            if not isinstance(blk, dict):
                cleaned.append(blk)
                continue
            btype = blk.get("type")
            # Drop reasoning-only blocks entirely
            if btype == "thinking":
                continue
            # Drop empty text blocks
            if btype == "text" and not (blk.get("text") or "").strip():
                continue
            cleaned.append(blk)
        if not cleaned:
            # Never leave content=[] (Bedrock rejects). Insert a minimal
            # placeholder so the turn structure is preserved.
            cleaned = [{"type": "text", "text": "(continued)"}]
        msg["content"] = cleaned


class ProxyPreCallFixups(CustomLogger):
    async def async_pre_call_hook(
        self, user_api_key_dict, cache, data, call_type
    ):
        try:
            model = data.get("model") or ""

            # (1) Always drop Anthropic-proxy-only extras on every target.
            _scrub(data, ALWAYS_DROP_KEYS)
            _scrub_body_aliases(data, ALWAYS_DROP_KEYS)

            # (2) Strip Claude-only thinking params on non-Claude targets
            #     and on auto-router entrypoints (may dispatch to Qwen/Kimi
            #     /GLM/DeepSeek). Users who need Claude thinking should call
            #     a Claude alias directly.
            if not _is_claude_model(model) or _is_auto_router(model):
                _scrub(data, CLAUDE_ONLY_KEYS)
                _scrub_body_aliases(data, CLAUDE_ONLY_KEYS)

            # (2b) Even on auto-router, if it lands on Claude Haiku 4.5
            #      (which does NOT support adaptive thinking), Bedrock
            #      400s. Because the scrub in (2) above already removes
            #      `thinking` entirely on auto-router, this is a no-op
            #      there — but we keep it as defense in depth against
            #      future field renames.
            if _is_auto_router(model):
                _downgrade_adaptive_thinking(data)

            # (3) For non-Claude targets (and auto-router, which may land on
            #     one), strip `thinking` blocks and empty-text blocks from
            #     assistant history. Otherwise multi-turn replays on models
            #     like DeepSeek R1 fail on turn 2.
            if not _is_claude_model(model) or _is_auto_router(model):
                _sanitize_history_for_non_claude(data.get("messages"))

            # (4) Flatten + denoise user content for auto-router entrypoints.
            #     Runs AFTER (3) so sanitized list → string conversion sees
            #     a clean input.
            if _is_auto_router(model):
                msgs = data.get("messages")
                if isinstance(msgs, list):
                    for m in msgs:
                        if isinstance(m, dict) and "content" in m:
                            m["content"] = _flatten_routing_text(m["content"])
        except Exception:
            pass
        return data


proxy_handler_instance = ProxyPreCallFixups()
