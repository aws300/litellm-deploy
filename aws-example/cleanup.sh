#!/usr/bin/env bash
# cleanup.sh — remove everything the aws-example scripts created, LiteLLM side first.
#
# Why this order: the LiteLLM objects reference the AWS resources, so they go
# first (a request in flight then fails with "not found" in LiteLLM rather than
# a signed call to a deleted resource); IAM goes last, after nothing uses it.
#   LiteLLM : guardrail, agent, search tool, vector store `aws-example`
#   AWS     : Bedrock guardrail, AgentCore runtime aws_example, gateway
#             aws-example-websearch (+ target), S3 Vectors index + bucket, the
#             agent code bucket, roles aws-example-agentcore-runtime /
#             aws-example-websearch-gateway, inline policy aws-example on the Pod role.
# Leaves the CloudFormation stack untouched. Each step tolerates "already gone".
#
# Usage: LITELLM_ADMIN_KEY=sk-... ./cleanup.sh [--dry-run]
source "$(dirname "$0")/lib.sh"

DRY=false; [[ ${1:-} == --dry-run ]] && DRY=true
run() { if $DRY; then echo "  would: $*"; else "$@" >/dev/null 2>&1 && ok "$*" || warn "skipped (gone?): $*"; fi; }
api_delete() { # api_delete <list-path> <jq selecting ids> <delete-path-prefix>
  local ids; ids=$(litellm GET "$1" | jq -r "$2" || true)
  for id in $ids; do
    if $DRY; then echo "  would: DELETE $3$id"; else litellm_status DELETE "$3$id" >/dev/null && ok "DELETE $3$id"; fi
  done
}
RUNTIME=${NAME//-/_}
CODE_BUCKET=$NAME-$ACCOUNT-$REGION
VEC_BUCKET=litellm-$NAME-$ACCOUNT-$REGION
WS_REGION=${WEB_SEARCH_REGION:-$REGION}

say "LiteLLM objects"
api_delete /v2/guardrails/list ".guardrails[] | select(.guardrail_name==\"$NAME\") | .guardrail_id" /guardrails/
api_delete /v1/agents ".[] | select(.agent_name==\"$NAME\") | .agent_id" /v1/agents/
api_delete /search_tools/list ".search_tools[]? | select(.search_tool_name==\"$NAME\") | .search_tool_id" /search_tools/
for id in $(litellm GET /vector_store/list | jq -r ".data[] | select(.vector_store_name==\"$NAME\") | .vector_store_id"); do
  if $DRY; then echo "  would: POST /vector_store/delete $id"
  else litellm POST /vector_store/delete "$(jq -n --arg id "$id" '{vector_store_id: $id}')" >/dev/null && ok "vector store $id"; fi
done

say "AWS resources ($REGION)"
gid=$(aws bedrock list-guardrails --region "$REGION" --query "guardrails[?name=='$NAME'].id | [0]" --output text)
[[ $gid != None && -n $gid ]] && run aws bedrock delete-guardrail --region "$REGION" --guardrail-identifier "$gid"
rid=$(aws bedrock-agentcore-control list-agent-runtimes --region "$REGION" --query "agentRuntimes[?agentRuntimeName=='$RUNTIME'].agentRuntimeId | [0]" --output text)
[[ $rid != None && -n $rid ]] && run aws bedrock-agentcore-control delete-agent-runtime --region "$REGION" --agent-runtime-id "$rid"
gw=$(aws bedrock-agentcore-control list-gateways --region "$WS_REGION" --query "items[?name=='$NAME-websearch'].gatewayId | [0]" --output text)
if [[ $gw != None && -n $gw ]]; then
  for t in $(aws bedrock-agentcore-control list-gateway-targets --region "$WS_REGION" --gateway-identifier "$gw" --query 'items[].targetId' --output text); do
    run aws bedrock-agentcore-control delete-gateway-target --region "$WS_REGION" --gateway-identifier "$gw" --target-id "$t"
  done
  $DRY || timeout 120 bash -c "until [[ \$(aws bedrock-agentcore-control list-gateway-targets --region $WS_REGION --gateway-identifier $gw --query 'length(items)') == 0 ]]; do sleep 5; done" || true
  run aws bedrock-agentcore-control delete-gateway --region "$WS_REGION" --gateway-identifier "$gw"
fi
if aws s3vectors get-vector-bucket --region "$REGION" --vector-bucket-name "$VEC_BUCKET" >/dev/null 2>&1; then
  for i in $(aws s3vectors list-indexes --region "$REGION" --vector-bucket-name "$VEC_BUCKET" --query 'indexes[].indexName' --output text); do
    run aws s3vectors delete-index --region "$REGION" --vector-bucket-name "$VEC_BUCKET" --index-name "$i"
  done
  run aws s3vectors delete-vector-bucket --region "$REGION" --vector-bucket-name "$VEC_BUCKET"
fi
if aws s3api head-bucket --bucket "$CODE_BUCKET" >/dev/null 2>&1; then
  run aws s3 rm "s3://$CODE_BUCKET" --recursive --region "$REGION"
  run aws s3api delete-bucket --bucket "$CODE_BUCKET" --region "$REGION"
fi

say "IAM"
for role in "$NAME-agentcore-runtime" "$NAME-websearch-gateway"; do
  if aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    run aws iam delete-role-policy --role-name "$role" --policy-name "$NAME"
    run aws iam delete-role --role-name "$role"
  fi
done
run aws iam delete-role-policy --role-name "$POD_ROLE" --policy-name "$NAME"
$DRY && echo "(dry run: nothing changed)"
