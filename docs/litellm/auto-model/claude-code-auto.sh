#!/usr/bin/env bash
# claude-code-auto.sh
#
# Run Claude Code in print (-p) mode against the Autel LiteLLM proxy's
# semantic "auto" model. The proxy picks one of
#   - claude-haiku-4-5-20251001   (trivial Q&A)
#   - qwen3-coder-480b            (boilerplate / code generation)
#   - claude-sonnet-4-6           (review, debug)
#   - claude-opus-4-7             (architecture, multi-step reasoning)
# based on the embedding similarity of the prompt.
#
# Usage:
#   ./claude-code-auto.sh "write a python function to reverse a linked list"
#   echo "design a distributed payment system" | ./claude-code-auto.sh
#   ./claude-code-auto.sh -m claude-opus-4-7 "audit this crypto code"   # override
#
# Requires: claude CLI (>= 2.0), jq (optional, for pretty JSON).

set -euo pipefail

# ─── 1. LiteLLM proxy endpoint + auth ─────────────────────────────────────
# Replace these two values for your environment, or set them in your shell
# before invoking this script. Do NOT commit a real virtual key to source.
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:?set ANTHROPIC_API_KEY to your LiteLLM virtual key (sk-...)}"
export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-https://litellm.example.com}"

# Make sure we talk to ANTHROPIC_BASE_URL (LiteLLM), not direct Bedrock/Vertex.
# If any of these are set in the caller's shell, Claude Code ignores
# ANTHROPIC_BASE_URL and goes straight to the cloud provider.
unset CLAUDE_CODE_USE_BEDROCK
unset CLAUDE_CODE_USE_VERTEX
unset CLAUDE_CODE_USE_FOUNDRY

# Path to the Claude Code settings file that registers all picker models.
# Override with SETTINGS_FILE=... if you relocated it.
SETTINGS_FILE="${SETTINGS_FILE:-$(dirname "$(readlink -f "$0")")/claude-code-settings.json}"

# ─── 2. Model selection ───────────────────────────────────────────────────
# Main reasoning/coding model: our semantic auto router.
export ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-auto}"
# The small/fast model Claude Code uses for haiku-style background tasks
# (summarization of tool output, title generation, etc.). Pointing this at
# Haiku 4.5 on our proxy keeps those calls cheap and in-region.
export ANTHROPIC_SMALL_FAST_MODEL="${ANTHROPIC_SMALL_FAST_MODEL:-claude-haiku-4-5-20251001}"

# ─── 3. Behaviour tweaks for non-interactive runs ─────────────────────────
# Don't try to hot-update the CLI while running in CI / scripts.
export DISABLE_AUTOUPDATER="${DISABLE_AUTOUPDATER:-1}"
# Don't ping Anthropic telemetry from a shared proxy environment.
export DISABLE_TELEMETRY="${DISABLE_TELEMETRY:-1}"
# Opus 4.7 can emit long replies (up to 128K). Keep a sane default.
export CLAUDE_CODE_MAX_OUTPUT_TOKENS="${CLAUDE_CODE_MAX_OUTPUT_TOKENS:-16384}"
# Verify TLS (default true) — override to 0 only if your proxy has a self-signed cert.
export CLAUDE_CODE_SKIP_SSL_VERIFICATION="${CLAUDE_CODE_SKIP_SSL_VERIFICATION:-0}"

# ─── 4. Parse args: optional -m/--model override, then prompt (or stdin) ──
MODEL_OVERRIDE=""
MAX_TURNS="${MAX_TURNS:-20}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-json}"   # text | json | stream-json

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--model)        MODEL_OVERRIDE="$2"; shift 2 ;;
    --text)            OUTPUT_FORMAT="text"; shift ;;
    --stream)          OUTPUT_FORMAT="stream-json"; shift ;;
    --max-turns)       MAX_TURNS="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *) break ;;
  esac
done

# Prompt: first positional arg, else stdin.
if [[ $# -gt 0 ]]; then
  PROMPT="$*"
elif [[ ! -t 0 ]]; then
  PROMPT="$(cat)"
else
  echo "error: no prompt supplied (pass as arg or pipe via stdin)" >&2
  exit 2
fi

MODEL="${MODEL_OVERRIDE:-$ANTHROPIC_MODEL}"

# ─── 5. Invoke Claude Code in print mode ──────────────────────────────────
# -p                 : print mode (non-interactive)
# --model            : route selector (auto / claude-sonnet-4-6 / etc.)
# --output-format    : text | json | stream-json
# --max-turns        : cap agent-loop iterations for safety
# --permission-mode  : bypassPermissions in scripts (no interactive confirm)

CLAUDE_ARGS=(
  -p
  --model "$MODEL"
  --output-format "$OUTPUT_FORMAT"
  --max-turns "$MAX_TURNS"
  --permission-mode bypassPermissions
)

# Apply settings file (picker allowlist + per-model display names/caps) if present.
if [[ -f "$SETTINGS_FILE" ]]; then
  CLAUDE_ARGS+=(--settings "$SETTINGS_FILE")
fi

# stream-json requires --verbose
if [[ "$OUTPUT_FORMAT" == "stream-json" ]]; then
  CLAUDE_ARGS+=(--verbose --input-format text)
fi

# If output is JSON and jq exists, pretty-print; otherwise stream raw.
if [[ "$OUTPUT_FORMAT" == "json" && -x "$(command -v jq)" ]]; then
  claude "${CLAUDE_ARGS[@]}" "$PROMPT" | jq .
else
  claude "${CLAUDE_ARGS[@]}" "$PROMPT"
fi
