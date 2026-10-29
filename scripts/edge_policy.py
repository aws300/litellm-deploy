"""Edge policy of the litellm/ stack: model calls only through Global Accelerator.

The stack has two public entry points onto one Envoy Gateway, both private
behind it (no public load balancer):
  - CloudFront -> VPC Origin -> internal ALB -> Envoy, HTTPRoute litellm-cf:
    the admin UI and its SSO login;
  - Global Accelerator -> internal NLB -> Envoy, HTTPRoute litellm-ga: the API.
Envoy stamps every request with X-LiteLLM-Edge (a `set`, so a client cannot pick
the value): `cloudfront` on litellm-cf, `global-accelerator` on litellm-ga.
CloudFront also adds its origin header X-CloudFront-Secret to every request,
which a viewer cannot remove.

A request that came through CloudFront may not call a model: every LLM,
pass-through, MCP, agent and search route — LiteLLM's own
RouteChecks.is_llm_api_route, the classification its key permissions use —
answers 403 whatever the key, before authentication. The model listing
(/v1/models, /models) stays: the UI reads it. Management routes (/key/*,
/user/*, /spend/*, /sso/*, /ui) are not LLM routes and keep working, so the UI
does; only its playground (it calls /chat/completions) is refused.

Not done at Envoy with a path list: LiteLLM serves hundreds of LLM routes and
aliases (/chat/completions, /engines/{model}/..., /openai/deployments/...,
/bedrock/*, /anthropic/*, /mcp, ...) and adds more every release; its own
classifier is the only list that keeps up.

Hooks the same auth builder as access_policy.py (load it after that one), plus
the pre-call hook as a second line on the model-call path. Coupled to the
pinned image like access_policy.py: the import fails loudly if internals move.
"""

from litellm._logging import verbose_proxy_logger
from litellm.integrations.custom_logger import CustomLogger
from litellm.proxy._types import ProxyException
from litellm.proxy.auth import user_api_key_auth as _auth
from litellm.proxy.auth.route_checks import RouteChecks

EDGE_HEADER = "x-litellm-edge"
CLOUDFRONT_HEADER = "x-cloudfront-secret"
LISTING_ROUTES = frozenset({"/v1/models", "/models"})


def _via_cloudfront(headers) -> bool:
    if not headers:
        return False
    lower = {str(k).lower(): v for k, v in dict(headers).items()}
    return str(lower.get(EDGE_HEADER, "")).lower() == "cloudfront" or bool(lower.get(CLOUDFRONT_HEADER))


def _deny(route: str) -> ProxyException:
    return ProxyException(
        message=(
            f"model calls are not served through CloudFront ({route}). "
            "Call the Global Accelerator endpoint (stack output LiteLLMApiServer)."
        ),
        type="auth_error",
        param="api_key",
        code=403,
    )


def _check(request) -> None:
    if request is None or not _via_cloudfront(getattr(request, "headers", None)):
        return
    route = _auth.get_request_route(request=request)
    if route not in LISTING_ROUTES and RouteChecks.is_llm_api_route(route=route):
        raise _deny(route)


# v1.106.0 renamed the builder to user_api_key_auth_builder and kept
# _user_api_key_auth_builder as an unused alias: wrap the real one, point both
# names at the wrapper (as access_policy.py does, whose wrapper this wraps).
_BUILDER_NAMES = ("user_api_key_auth_builder", "_user_api_key_auth_builder")
_builder = getattr(_auth, "user_api_key_auth_builder", None) or _auth._user_api_key_auth_builder
if not getattr(_builder, "_edge_policy", False):

    async def _edge_guarded_builder(*args, **kwargs):
        _check(kwargs.get("request", args[0] if args else None))
        return await _builder(*args, **kwargs)

    _edge_guarded_builder._edge_policy = True  # type: ignore[attr-defined]
    _edge_guarded_builder._access_policy = getattr(_builder, "_access_policy", False)  # type: ignore[attr-defined]
    for _name in _BUILDER_NAMES:
        if hasattr(_auth, _name):
            setattr(_auth, _name, _edge_guarded_builder)
    verbose_proxy_logger.warning("edge_policy: no model calls through CloudFront (header %s)", EDGE_HEADER)


class CloudFrontModelCallGuard(CustomLogger):
    """Second line of defence on the LLM call path itself."""

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        request = (data or {}).get("proxy_server_request") or {}
        if _via_cloudfront(request.get("headers")):
            raise _deny(str(request.get("url") or call_type))
        return data


proxy_handler_instance = CloudFrontModelCallGuard()
