#!/usr/bin/env bash
# 30-web-search.sh — Web Search on Amazon Bedrock as a LiteLLM search tool (`aws-example`).
#
# Why: Amazon Bedrock's managed web search is an AgentCore Gateway connector
# (connector `web-search`); LiteLLM's `agentcore` search provider calls a
# gateway's MCP tools/call SigV4-signed with its Pod role (00-iam.sh) and serves
# it as POST /v1/search/<tool> (Perplexity Search API shape). This script:
#   1. creates the gateway role aws-example-websearch-gateway (AgentCore assumes
#      it; it may InvokeGateway and call the managed web-search tool);
#   2. creates the AgentCore Gateway aws-example-websearch (MCP, IAM auth) and
#      its target `web-search-tool` (connector web-search 1.1.0). The target
#      name makes the MCP tool `web-search-tool___WebSearch`, LiteLLM's default,
#      so no LiteLLM env var is needed (else set AGENTCORE_SEARCH_TOOL_NAME);
#   3. registers the search tool `aws-example` in LiteLLM (POST /search_tools,
#      DB-stored, every pod reloads it).
# Idempotent: existing gateway / target / tool are reused (the tool is updated).
#
# Web search is offered in us-east-1 and us-west-2 (the tool ARNs below); the
# gateway must be in one of them — set WEB_SEARCH_REGION when $REGION is not.
#
# Usage: LITELLM_ADMIN_KEY=sk-... ./30-web-search.sh
source "$(dirname "$0")/lib.sh"

WS_REGION=${WEB_SEARCH_REGION:-$REGION}
GW=$NAME-websearch
ROLE=$NAME-websearch-gateway
TARGET=web-search-tool

say "1. gateway role $ROLE"
trust=$(jq -n --arg a "$ACCOUNT" '{Version: "2012-10-17", Statement: [{Effect: "Allow",
  Principal: {Service: "bedrock-agentcore.amazonaws.com"}, Action: "sts:AssumeRole",
  Condition: {StringEquals: {"aws:SourceAccount": $a}, ArnLike: {"aws:SourceArn": "arn:aws:bedrock-agentcore:*:\($a):gateway/*"}}}]}')
perms=$(jq -n --arg a "$ACCOUNT" '{Version: "2012-10-17", Statement: [
  {Sid: "InvokeGateway", Effect: "Allow", Action: "bedrock-agentcore:InvokeGateway", Resource: "arn:aws:bedrock-agentcore:*:\($a):gateway/*"},
  {Sid: "InvokeWebSearch", Effect: "Allow", Action: "bedrock-agentcore:InvokeWebSearch",
   Resource: ["arn:aws:bedrock-agentcore:us-east-1:aws:tool/web-search.v1", "arn:aws:bedrock-agentcore:us-west-2:aws:tool/web-search.v1"]}]}')
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$trust" \
    --description "AgentCore Gateway role of the LiteLLM aws-example web search" >/dev/null
  ok "created"; sleep 10
else
  aws iam update-assume-role-policy --role-name "$ROLE" --policy-document "$trust"; ok "exists"
fi
aws iam put-role-policy --role-name "$ROLE" --policy-name "$NAME" --policy-document "$perms"
role_arn=$(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text)

say "2. AgentCore Gateway $GW ($WS_REGION)"
gid=$(aws bedrock-agentcore-control list-gateways --region "$WS_REGION" --query "items[?name=='$GW'].gatewayId | [0]" --output text)
if [[ $gid == None || -z $gid ]]; then
  for attempt in 1 2 3 4 5 6; do
    if gid=$(aws bedrock-agentcore-control create-gateway --region "$WS_REGION" --name "$GW" --role-arn "$role_arn" \
      --protocol-type MCP --authorizer-type AWS_IAM --description "LiteLLM aws-example: Web Search on Amazon Bedrock" \
      --query gatewayId --output text 2>/tmp/aws-example.err); then break; fi
    grep -qi "assume\|role" /tmp/aws-example.err || { cat /tmp/aws-example.err >&2; exit 1; }
    warn "role not assumable yet (attempt $attempt)"; sleep 15
  done
  ok "created $gid"
else
  ok "exists $gid"
fi
timeout 300 bash -c "until [[ \$(aws bedrock-agentcore-control get-gateway --region $WS_REGION --gateway-identifier $gid --query status --output text) == READY ]]; do sleep 5; done"
url=$(aws bedrock-agentcore-control get-gateway --region "$WS_REGION" --gateway-identifier "$gid" --query gatewayUrl --output text)
tid=$(aws bedrock-agentcore-control list-gateway-targets --region "$WS_REGION" --gateway-identifier "$gid" \
  --query "items[?name=='$TARGET'].targetId | [0]" --output text)
if [[ $tid == None || -z $tid ]]; then
  tid=$(aws bedrock-agentcore-control create-gateway-target --region "$WS_REGION" --gateway-identifier "$gid" --name "$TARGET" \
    --description "Web Search on Amazon Bedrock (managed connector)" \
    --target-configuration '{"mcp":{"connector":{"source":{"connectorId":"web-search","version":"1.1.0"},"configurations":[{"name":"WebSearch","parameterValues":{}}]}}}' \
    --credential-provider-configurations '[{"credentialProviderType":"GATEWAY_IAM_ROLE"}]' \
    --query targetId --output text)
  ok "target $TARGET created ($tid)"
else
  ok "target $TARGET exists ($tid)"
fi
timeout 300 bash -c "until s=\$(aws bedrock-agentcore-control get-gateway-target --region $WS_REGION --gateway-identifier $gid --target-id $tid --query status --output text); [[ \$s == READY || \$s == FAILED ]]; do sleep 5; done"
st=$(aws bedrock-agentcore-control get-gateway-target --region "$WS_REGION" --gateway-identifier "$gid" --target-id "$tid" --query status --output text)
[[ $st == READY ]] || die "target $tid is $st"
ok "MCP endpoint $url (tool ${TARGET}___WebSearch)"

say "3. LiteLLM search tool $NAME"
spec=$(jq -n --arg n "$NAME" --arg u "$url" --arg r "$WS_REGION" '{search_tool: {
  search_tool_name: $n,
  litellm_params: {search_provider: "agentcore", api_base: $u, aws_region_name: $r, timeout: 60, max_retries: 1},
  search_tool_info: {description: "Web Search on Amazon Bedrock (AgentCore Gateway aws-example-websearch)"}}}')
existing=$(litellm GET /search_tools/list | jq -r --arg n "$NAME" '.search_tools[]? | select(.search_tool_name==$n) | .search_tool_id' | head -1)
if [[ -n $existing ]]; then
  litellm PUT "/search_tools/$existing" "$spec" >/dev/null; ok "updated $existing"
else
  existing=$(litellm POST /search_tools "$spec" | jq -r '.search_tool_id // .search_tool.search_tool_id // "?"'); ok "created $existing"
fi
echo "Use it: POST $GA/v1/search/$NAME {\"query\": \"...\", \"max_results\": 5}"
