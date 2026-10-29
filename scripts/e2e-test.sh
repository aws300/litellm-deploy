#!/usr/bin/env bash
# e2e-test.sh — end-to-end check of a deployed CloudNativeFormationLitellm stack.
#
# Why: the stack's guarantees are all "negative" ones that a healthy-looking
# deployment does not prove — no load balancer with a public IP, model calls
# served by Global Accelerator only (never CloudFront), the master key unable
# to call models or mint keys. This script asserts each of them with real
# requests, plus one real call per model (they are billed: a few tokens each).
#
#   1. network : every load balancer in the stack VPC is `internal`; CloudFront
#                reaches the gateway through a VPC origin; GA points at the
#                internal NLB.
#   2. GA      : liveness, the public model list == the 11 expected models.
#   3. auth    : no key -> 401; master key -> 403 on model calls and on
#                /key/generate, and it cannot sign in to the UI.
#   4. models  : every chat model via /v1/chat/completions, plus /v1/messages
#                (Claude), /v1/responses (GPT-6) and /v1/embeddings (Cohere).
#   5. CF      : the UI and the model list load; every model call is 403.
#   6. cache   : UI behaviours key on Host and hit on a 2nd GET; the default and
#                every API prefix use CachingDisabled and never hit.
#
# It reads endpoints from the stack outputs and touches nothing: no key is
# created or deleted. LITELLM_KEY must be a virtual key (admin UI -> Virtual
# Keys -> Create, see API.md §2); without it, steps 4 and the keyed checks of
# 5 are skipped.
#
# Usage: LITELLM_KEY=sk-... ./scripts/e2e-test.sh [--stack litellm-usw1] [--region us-west-1]
set -euo pipefail

STACK=litellm-usw1
REGION=us-west-1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack) STACK=$2; shift 2 ;;
    --region) REGION=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
ok() { printf '  \033[32mok\033[0m   %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf '  \033[33mskip\033[0m %s\n' "$*"; }
PASS=0 FAIL=0

out() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
GA=$(out LiteLLMApiServer); GA=${GA%/}
CF=$(out CloudFrontDomain); CF="https://$CF"
MASTER=$(out LiteLLMMasterKey)
VPC=$(out VpcId)
KEY=${LITELLM_KEY:-}

EXPECTED_MODELS="claude-haiku-5-5 claude-opus-5-5 claude-sonnet-5-5 cohere.embed-v4 glm-5.3 gpt-6-astra gpt-6-luna gpt-6-sol gpt-6.1-sol gpt-6.1-terra kimi-k3"
CHAT_MODELS="claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5 glm-5.3 kimi-k3 gpt-6-astra gpt-6-sol gpt-6-luna gpt-6.1-sol gpt-6.1-terra"

# req METHOD URL KEY [JSON] -> "<status> <body>" (body cut to 300 chars)
req() {
  local method=$1 url=$2 key=$3 body=${4:-} args=(-sS -m 180 -o /tmp/e2e.body -w '%{http_code}' -X "$method" "$url")
  [[ -n $key ]] && args+=(-H "Authorization: Bearer $key")
  [[ -n $body ]] && args+=(-H 'Content-Type: application/json' -d "$body")
  local code; code=$(curl "${args[@]}" || echo 000)
  printf '%s %s' "$code" "$(head -c 300 /tmp/e2e.body 2>/dev/null | tr '\n' ' ')"
}
expect() { # expect WANT_CODE LABEL RESULT [BODY_SUBSTRING]
  local want=$1 label=$2 res=$3 sub=${4:-}
  if [[ ${res%% *} == "$want" && ( -z $sub || $res == *"$sub"* ) ]]; then ok "$label -> $want"
  else bad "$label: want $want${sub:+ ($sub)}, got ${res:0:300}"; fi
}
chat() { printf '{"model":"%s","max_tokens":%s,"messages":[{"role":"user","content":"Reply with the single word: pong"}]}' "$1" "${2:-64}"; }

say "1. network ($VPC)"
lbs=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?VpcId=='$VPC'].[Type,Scheme,LoadBalancerName]" --output text)
if [[ -z $lbs ]]; then bad "no load balancer found in $VPC"; fi
while read -r type scheme name; do
  [[ -z $type ]] && continue
  if [[ $scheme == internal ]]; then ok "$type $name is internal"; else bad "$type $name is $scheme"; fi
done <<<"$lbs"
dist=$(aws cloudfront list-distributions --query "DistributionList.Items[?DomainName=='${CF#https://}'].Id" --output text)
vpco=$(aws cloudfront get-distribution-config --id "$dist" \
  --query 'DistributionConfig.Origins.Items[0].VpcOriginConfig.VpcOriginId' --output text)
if [[ $vpco == vo_* ]]; then ok "CloudFront origin is VPC origin $vpco"; else bad "CloudFront origin is not a VPC origin ($vpco)"; fi
ga_arn=$(aws globalaccelerator list-accelerators --region us-west-2 \
  --query "Accelerators[?DualStackDnsName=='${GA#https://}'].AcceleratorArn" --output text)
for l in $(aws globalaccelerator list-listeners --region us-west-2 --accelerator-arn "$ga_arn" --query 'Listeners[].ListenerArn' --output text); do
  for ep in $(aws globalaccelerator list-endpoint-groups --region us-west-2 --listener-arn "$l" \
    --query 'EndpointGroups[].EndpointDescriptions[].EndpointId' --output text); do
    scheme=$(aws elbv2 describe-load-balancers --region "$REGION" --load-balancer-arns "$ep" --query 'LoadBalancers[0].Scheme' --output text)
    if [[ $scheme == internal ]]; then ok "GA listener -> ${ep##*/} (internal)"; else bad "GA endpoint ${ep##*/} is $scheme"; fi
  done
done

say "2. GA $GA"
expect 200 "GET /health/liveliness" "$(req GET "$GA/health/liveliness" "")"
models=$(curl -sS -m 30 "$GA/v1/models" | jq -r '[.data[].id] | sort | join(" ")')
if [[ $models == "$EXPECTED_MODELS" ]]; then ok "GET /v1/models (no key) = the 11 discovery models"
else bad "GET /v1/models = [$models], want [$EXPECTED_MODELS]"; fi

say "3. auth"
expect 401 "chat without a key" "$(req POST "$GA/v1/chat/completions" "" "$(chat claude-haiku-5-5)")"
expect 403 "chat with the master key" "$(req POST "$GA/v1/chat/completions" "$MASTER" "$(chat claude-haiku-5-5)")" "read-only"
expect 403 "/v1/messages with the master key" "$(req POST "$GA/v1/messages" "$MASTER" "$(chat claude-haiku-5-5)")" "read-only"
expect 403 "POST /key/generate with the master key" "$(req POST "$GA/key/generate" "$MASTER" '{"max_budget":1,"budget_duration":"1d"}')" "read-only"
expect 200 "GET /model/info with the master key (read-only)" "$(req GET "$GA/model/info" "$MASTER")"
login=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X POST "$GA/login" --data-urlencode username=admin --data-urlencode "password=$MASTER")
if [[ $login != 200 && $login != 303 ]]; then ok "UI sign-in with the master key refused ($login)"; else bad "UI sign-in with the master key returned $login"; fi

say "4. models through GA (virtual key)"
if [[ -z $KEY ]]; then skip "LITELLM_KEY not set"; else
  for m in $CHAT_MODELS; do
    expect 200 "chat $m" "$(req POST "$GA/v1/chat/completions" "$KEY" "$(chat "$m")")" '"choices"'
  done
  expect 200 "/v1/messages claude-sonnet-5-5 (Anthropic API)" \
    "$(req POST "$GA/v1/messages" "$KEY" "$(chat claude-sonnet-5-5)")" '"content"'
  expect 200 "/v1/responses gpt-6-luna" \
    "$(req POST "$GA/v1/responses" "$KEY" '{"model":"gpt-6-luna","input":"Reply with the single word: pong"}')" '"output"'
  expect 200 "/v1/embeddings cohere.embed-v4" \
    "$(req POST "$GA/v1/embeddings" "$KEY" '{"model":"cohere.embed-v4","input":["hello"]}')" '"embedding"'
fi

say "5. CloudFront $CF"
expect 200 "GET /ui/" "$(req GET "$CF/ui/" "")"
expect 200 "GET /v1/models" "$(req GET "$CF/v1/models" "")"
expect 403 "chat with the master key" "$(req POST "$CF/v1/chat/completions" "$MASTER" "$(chat claude-haiku-5-5)")" "CloudFront"
if [[ -z $KEY ]]; then skip "keyed CloudFront checks: LITELLM_KEY not set"; else
  for path in /v1/chat/completions /chat/completions /v1/messages /v1/responses /v1/embeddings /bedrock/model/global.anthropic.claude-haiku-5-5/converse; do
    expect 403 "POST $path (virtual key)" "$(req POST "$CF$path" "$KEY" "$(chat claude-haiku-5-5)")" "CloudFront"
  done
  res=$(curl -sS -m 30 -o /tmp/e2e.body -w '%{http_code}' -X POST "$CF/v1/chat/completions" \
    -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    -H 'X-LiteLLM-Edge: global-accelerator' -d "$(chat claude-haiku-5-5)")
  expect 403 "chat with a forged X-LiteLLM-Edge header" "$res $(head -c 200 /tmp/e2e.body)" "CloudFront"
  expect 200 "GET /key/info (UI management API stays)" "$(req GET "$CF/key/info" "$KEY")"
fi

say "6. CloudFront cache"
xcache() { curl -sS -m 30 -o /dev/null -D - "$1" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-cache"{print $2}'; }
pol=$(aws cloudfront get-distribution-config --id "$dist" --output json)
for p in /ui /ui/* /ui/_next/static/*; do
  cp=$(jq -r --arg p "$p" '.DistributionConfig.CacheBehaviors.Items[] | select(.PathPattern==$p) | .CachePolicyId' <<<"$pol")
  hk=$(aws cloudfront get-cache-policy --id "$cp" --query 'CachePolicy.CachePolicyConfig.ParametersInCacheKeyAndForwardedToOrigin.HeadersConfig.Headers.Items' --output text)
  if [[ $hk == *Host* ]]; then ok "$p cache key includes Host"; else bad "$p cache key headers: $hk"; fi
done
nocache=$(jq -r '[.DistributionConfig.DefaultCacheBehavior.CachePolicyId] + [.DistributionConfig.CacheBehaviors.Items[] | select(.PathPattern | startswith("/ui") | not) | .CachePolicyId] | unique | join(",")' <<<"$pol")
if [[ $nocache == 4135ea2d-6df8-44a3-9df3-4b5a84be39ad ]]; then ok "default + API prefixes use CachingDisabled"; else bad "API behaviours use cache policies $nocache"; fi
asset=$(curl -sS -m 30 "$CF/ui/" | grep -o '/ui/_next/static/[^"]*\.js' | head -1)
for u in "$CF/ui/" "$CF$asset"; do
  xcache "$u" >/dev/null; x=$(xcache "$u")
  if [[ $x == Hit* || $x == RefreshHit* ]]; then ok "${u#$CF} cached on 2nd GET ($x)"; else bad "${u#$CF} not cached on 2nd GET ($x)"; fi
done
for u in "$CF/v1/models" "$CF/health/liveliness"; do
  xcache "$u" >/dev/null; x=$(xcache "$u")
  if [[ $x != Hit* ]]; then ok "${u#$CF} not cached ($x)"; else bad "${u#$CF} served from cache ($x)"; fi
done

say "result: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
