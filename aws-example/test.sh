#!/usr/bin/env bash
# test.sh — checks the four aws-example integrations end to end through LiteLLM.
#
# Why: each integration is "configured" the moment its API call returns 200,
# which proves nothing about the request path (IAM, SigV4 signing, payload
# shapes, every replica having loaded the object). This sends real requests
# with an ordinary virtual key through the GA endpoint and checks the answers:
#   1. guardrail : a normal prompt passes; a denied topic is blocked (400) on
#                  every try — six tries, so every replica is hit; an e-mail
#                  address comes back anonymised as {EMAIL};
#   2. agent     : the agent card, A2A message/send (the agent's utc_now tool must
#                  answer) and message/stream;
#   3. search    : /v1/search/aws-example returns web results;
#   4. vectors   : /v1/vector_stores/<id>/search finds the sample document, and a
#                  chat completion with file_search answers from it.
# Calls are billed (a few cents). Changes nothing.
#
# Usage: LITELLM_KEY=sk-... ./test.sh     (any virtual key; the admin key works too)
source "$(dirname "$0")/lib.sh"

KEY=${LITELLM_KEY:-${LITELLM_ADMIN_KEY:-}}
[[ -n $KEY ]] || die "set LITELLM_KEY (a virtual key)"
STORE_ID=litellm-$NAME-$ACCOUNT-$REGION:$NAME
PASS=0 FAIL=0
pass() { ok "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
post() { curl -sS -m 240 -o /tmp/aws-example.body -w '%{http_code}' "$GA$1" -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' -d "$2" || echo 000; }
chat() { jq -n --arg m "$1" --arg c "$2" '{model: $m, max_tokens: 200, guardrails: ["aws-example"], messages: [{role: "user", content: $c}]}'; }

say "1. Bedrock Guardrails ($NAME)"
code=$(post /v1/chat/completions "$(chat claude-haiku-5-5 'Say hello in one word.')")
if [[ $code == 200 ]]; then pass "normal prompt passes"; else fail "normal prompt -> $code $(head -c 300 /tmp/aws-example.body)"; fi
blocked=0
for _ in 1 2 3 4 5 6; do
  code=$(post /v1/chat/completions "$(chat claude-haiku-5-5 'Should I put my savings into bitcoin? Give me a yes or no recommendation.')")
  [[ $code == 400 ]] && grep -q "investment-advice" /tmp/aws-example.body && blocked=$((blocked + 1))
done
if [[ $blocked == 6 ]]; then pass "denied topic blocked 6/6 (400, topic investment-advice)"; else fail "denied topic blocked $blocked/6"; fi
code=$(post /v1/chat/completions "$(chat claude-haiku-5-5 'Repeat exactly: my email is jane.doe@example.com')")
if [[ $code == 200 ]] && jq -e '.choices[0].message.content | test("\\{EMAIL\\}")' /tmp/aws-example.body >/dev/null; then
  pass "e-mail anonymised: $(jq -r '.choices[0].message.content' /tmp/aws-example.body)"
else fail "PII: $code $(head -c 300 /tmp/aws-example.body)"; fi

say "2. Bedrock AgentCore agent ($NAME)"
code=$(curl -sS -m 60 -o /tmp/aws-example.body -w '%{http_code}' "$GA/a2a/$NAME/.well-known/agent-card.json" -H "Authorization: Bearer $KEY")
if [[ $code == 200 ]]; then pass "agent card: $(jq -r '.name + " -> " + .url' /tmp/aws-example.body)"; else fail "agent card -> $code"; fi
code=$(post "/a2a/$NAME" '{"jsonrpc":"2.0","id":"t1","method":"message/send","params":{"message":{"role":"user","messageId":"t1","parts":[{"kind":"text","text":"What is the current UTC date? Answer with the date only."}]}}}')
today=$(date -u +%Y-%m-%d); text=$(jq -r '.result.parts[0].text // .error.message // ""' /tmp/aws-example.body)
if [[ $code == 200 && ( $text == *"$today"* || $text == *"$(date -u '+%B %-d')"* ) ]]; then pass "message/send (tool utc_now): $text"
else fail "message/send -> $code: ${text:0:300}"; fi
sse=$(curl -sS -N -m 240 "$GA/a2a/$NAME" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":"t2","method":"message/stream","params":{"message":{"role":"user","messageId":"t2","parts":[{"kind":"text","text":"Say hi in three words."}]}}}' || true)
if [[ $sse == *'"kind": "message"'* || $sse == *'"kind":"message"'* ]]; then pass "message/stream: $(grep -o '"text": *"[^"]*"' <<<"$sse" | head -1)"
else fail "message/stream: ${sse:0:300}"; fi

say "3. Web Search on Amazon Bedrock ($NAME)"
code=$(post "/v1/search/$NAME" '{"query":"Amazon S3 Vectors general availability","max_results":3}')
n=$(jq '.results | length' /tmp/aws-example.body 2>/dev/null || echo 0)
if [[ $code == 200 && $n -gt 0 ]]; then pass "$n results, first: $(jq -r '.results[0].title' /tmp/aws-example.body)"
else fail "search -> $code $(head -c 300 /tmp/aws-example.body)"; fi

say "4. Amazon S3 Vectors ($STORE_ID)"
code=$(post "/v1/vector_stores/$STORE_ID/search" '{"query":"Which tools does the AgentCore agent have?","max_num_results":2}')
if [[ $code == 200 ]] && jq -e '.data[0].content[0].text | test("utc_now")' /tmp/aws-example.body >/dev/null; then
  pass "search finds the agent section (score $(jq -r '.data[0].score' /tmp/aws-example.body))"
else fail "vector search -> $code $(head -c 300 /tmp/aws-example.body)"; fi
# file_search RAG: kimi-k3 / gpt-6-*; see README §4 for Claude / GLM.
code=$(post /v1/chat/completions "$(jq -n --arg id "$STORE_ID" '{model: "kimi-k3", max_tokens: 300,
  tools: [{type: "file_search", vector_store_ids: [$id]}],
  messages: [{role: "user", content: "How many dimensions does the aws-example S3 Vectors index have? Answer with the number only."}]}')")
if [[ $code == 200 ]] && jq -e '.choices[0].message.content | test("1,?536")' /tmp/aws-example.body >/dev/null; then
  pass "chat + file_search answers from the store: $(jq -r '.choices[0].message.content' /tmp/aws-example.body)"
else fail "chat + file_search -> $code $(head -c 300 /tmp/aws-example.body)"; fi

say "result: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
