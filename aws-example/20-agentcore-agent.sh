#!/usr/bin/env bash
# 20-agentcore-agent.sh — a Bedrock AgentCore agent in LiteLLM (agent `aws-example`).
#
# Why: LiteLLM's Agents page (New Agent -> Bedrock AgentCore) fronts agents
# hosted on Amazon Bedrock AgentCore Runtime: clients call them through LiteLLM
# (A2A JSON-RPC at /a2a/aws-example) with a virtual key, and LiteLLM signs the
# InvokeAgentRuntime call with its own Pod role (00-iam.sh). This script:
#   1. packages agent/ (a Strands agent, Claude Haiku 5.5 on Bedrock, two tools)
#      for AgentCore's direct code deployment: linux/arm64 wheels for Python
#      3.13 + main.py, zipped, uploaded to S3 bucket aws-example-<account>-<region>;
#   2. creates the runtime's execution role aws-example-agentcore-runtime
#      (Bedrock model calls, CloudWatch Logs / X-Ray / metrics, the code in S3);
#   3. creates or updates the AgentCore runtime aws_example (runtime names allow
#      no hyphen) and waits for READY;
#   4. registers it in LiteLLM (POST /v1/agents, DB-stored, every pod):
#      custom_llm_provider bedrock + model bedrock/agentcore/<runtime ARN>, the
#      shape the UI's "Bedrock AgentCore" form writes;
#   5. binds a virtual key to the agent (aws-example-agent), which turns its
#      status on the Agents page from "Needs Setup" to "Active".
# Re-running it redeploys the code (new runtime version) and updates the agent.
#
# Needs: pip (packages with --platform, no Docker), zip.
# Usage: LITELLM_ADMIN_KEY=sk-... ./20-agentcore-agent.sh
source "$(dirname "$0")/lib.sh"
need pip zip

RUNTIME=${NAME//-/_}
ROLE=$NAME-agentcore-runtime
BUCKET=$NAME-$ACCOUNT-$REGION
KEY=$NAME/agent-$(date -u +%Y%m%dT%H%M%S).zip

say "1. package agent/ -> s3://$BUCKET/$KEY"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
# --no-compile + no __pycache__: AgentCore rejects .pyc built by another Python
# ("Python cache files that are incompatible with the target runtime").
pip install -q --no-compile --target "$work/pkg" --platform manylinux2014_aarch64 --python-version 3.13 \
  --implementation cp --only-binary=:all: -r "$HERE/agent/requirements.txt" 2> >(grep -v "dependency resolver\|requires\|incompatible" >&2)
cp "$HERE/agent/main.py" "$work/pkg/"
(cd "$work/pkg" && find . -name __pycache__ -type d -prune -exec rm -rf {} + && zip -qr "$work/agent.zip" . -x '*.pyc')
if ! aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  if [[ $REGION == us-east-1 ]]; then aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
  else aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" --create-bucket-configuration LocationConstraint="$REGION" >/dev/null; fi
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
fi
aws s3 cp "$work/agent.zip" "s3://$BUCKET/$KEY" --region "$REGION" --only-show-errors
ok "$(du -h "$work/agent.zip" | cut -f1) uploaded"

say "2. execution role $ROLE"
trust=$(jq -n --arg a "$ACCOUNT" '{Version: "2012-10-17", Statement: [{Effect: "Allow",
  Principal: {Service: "bedrock-agentcore.amazonaws.com"}, Action: "sts:AssumeRole",
  Condition: {StringEquals: {"aws:SourceAccount": $a}, ArnLike: {"aws:SourceArn": "arn:aws:bedrock-agentcore:*:\($a):*"}}}]}')
perms=$(jq -n --arg a "$ACCOUNT" --arg b "$BUCKET" '{Version: "2012-10-17", Statement: [
  {Sid: "Bedrock", Effect: "Allow", Action: ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"], Resource: "*"},
  {Sid: "Code", Effect: "Allow", Action: ["s3:GetObject", "s3:GetObjectVersion"], Resource: "arn:aws:s3:::\($b)/*"},
  {Sid: "Logs", Effect: "Allow", Action: ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents",
     "logs:DescribeLogStreams", "logs:DescribeLogGroups"], Resource: "arn:aws:logs:*:\($a):log-group:/aws/bedrock-agentcore/runtimes/*"},
  {Sid: "Observability", Effect: "Allow", Action: ["xray:PutTraceSegments", "xray:PutTelemetryRecords",
     "xray:GetSamplingRules", "xray:GetSamplingTargets", "cloudwatch:PutMetricData"], Resource: "*"},
  {Sid: "WorkloadIdentity", Effect: "Allow", Action: ["bedrock-agentcore:GetWorkloadAccessToken",
     "bedrock-agentcore:GetWorkloadAccessTokenForJWT", "bedrock-agentcore:GetWorkloadAccessTokenForUserId"],
   Resource: "arn:aws:bedrock-agentcore:*:\($a):workload-identity-directory/default*"}]}')
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$trust" \
    --description "AgentCore Runtime execution role of the LiteLLM aws-example agent" >/dev/null
  ok "created"; sleep 10   # IAM propagation before AgentCore assumes it
else
  aws iam update-assume-role-policy --role-name "$ROLE" --policy-document "$trust"; ok "exists"
fi
aws iam put-role-policy --role-name "$ROLE" --policy-name "$NAME" --policy-document "$perms"
role_arn=$(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text)

say "3. AgentCore runtime $RUNTIME"
artifact=$(jq -n --arg b "$BUCKET" --arg k "$KEY" '{codeConfiguration: {code: {s3: {bucket: $b, prefix: $k}},
  runtime: "PYTHON_3_13", entryPoint: ["main.py"]}}')
rid=$(aws bedrock-agentcore-control list-agent-runtimes --region "$REGION" \
  --query "agentRuntimes[?agentRuntimeName=='$RUNTIME'].agentRuntimeId | [0]" --output text)
# A runtime that failed to create cannot be updated: delete it and start over.
if [[ $rid != None && -n $rid ]] && [[ $(aws bedrock-agentcore-control get-agent-runtime --region "$REGION" \
    --agent-runtime-id "$rid" --query status --output text) == CREATE_FAILED ]]; then
  aws bedrock-agentcore-control delete-agent-runtime --region "$REGION" --agent-runtime-id "$rid" >/dev/null
  timeout 300 bash -c "while aws bedrock-agentcore-control get-agent-runtime --region $REGION --agent-runtime-id $rid >/dev/null 2>&1; do sleep 5; done"
  warn "deleted failed runtime $rid"; rid=None
fi
common=(--region "$REGION" --agent-runtime-artifact "$artifact" --role-arn "$role_arn"
  --network-configuration networkMode=PUBLIC --environment-variables "MODEL_ID=global.anthropic.claude-haiku-5-5"
  --description "LiteLLM aws-example agent (Strands, Claude Haiku 5.5)")
if [[ $rid == None || -z $rid ]]; then
  for attempt in 1 2 3 4 5 6; do   # a freshly created role can take a minute to be assumable
    if rid=$(aws bedrock-agentcore-control create-agent-runtime --agent-runtime-name "$RUNTIME" "${common[@]}" \
      --query agentRuntimeId --output text 2>/tmp/aws-example.err); then break; fi
    grep -q "assume\|AccessDenied\|role" /tmp/aws-example.err || { cat /tmp/aws-example.err >&2; exit 1; }
    warn "role not assumable yet (attempt $attempt)"; sleep 15
  done
  ok "created $rid"
else
  aws bedrock-agentcore-control update-agent-runtime --agent-runtime-id "$rid" "${common[@]}" >/dev/null
  ok "updated $rid (new version)"
fi
timeout 600 bash -c "until s=\$(aws bedrock-agentcore-control get-agent-runtime --region $REGION --agent-runtime-id $rid --query status --output text); [[ \$s == READY || \$s == *FAILED ]]; do sleep 10; done"
status=$(aws bedrock-agentcore-control get-agent-runtime --region "$REGION" --agent-runtime-id "$rid" --query status --output text)
[[ $status == READY ]] || die "runtime $rid is $status: $(aws bedrock-agentcore-control get-agent-runtime --region "$REGION" --agent-runtime-id "$rid" --query failureReason --output text)"
arn=$(aws bedrock-agentcore-control get-agent-runtime --region "$REGION" --agent-runtime-id "$rid" --query agentRuntimeArn --output text)
ok "READY $arn"

say "4. LiteLLM agent $NAME"
spec=$(jq -n --arg n "$NAME" --arg arn "$arn" --arg r "$REGION" --arg url "$GA/a2a/$NAME" '{
  agent_name: $n,
  litellm_params: {custom_llm_provider: "bedrock", model: "bedrock/agentcore/\($arn)", aws_region_name: $r},
  agent_card_params: {protocolVersion: "0.3.0", name: $n, version: "1.0.0", url: $url,
    description: "AWS helper agent on Amazon Bedrock AgentCore Runtime (Strands, Claude Haiku 5.5)",
    defaultInputModes: ["text"], defaultOutputModes: ["text"], capabilities: {streaming: true},
    skills: [{id: "aws-help", name: "AWS help", description: "Answers AWS questions, links documentation, tells the UTC time",
              tags: ["aws"], examples: ["What is Amazon S3 Vectors? Give me its documentation link."]}]}}')
existing=$(litellm GET /v1/agents | jq -r --arg n "$NAME" '.[] | select(.agent_name==$n) | .agent_id' | head -1)
if [[ -n $existing ]]; then
  litellm PUT "/v1/agents/$existing" "$spec" >/dev/null; ok "updated LiteLLM agent $existing"
else
  existing=$(litellm POST /v1/agents "$spec" | jq -r .agent_id); ok "created LiteLLM agent $existing"
fi
say "5. agent key ($NAME-agent)"
# The Agents page shows an agent as "Needs Setup" until a virtual key is bound
# to it (key agent_id = this agent) or JWT auth is configured; then "Active".
# The key is the agent's own identity on the proxy: what it calls through
# LiteLLM is attributed to (and budgeted on) the agent. This agent calls Bedrock
# directly, so the key is only created, not handed to the runtime; give it to
# an agent that should call models / tools through LiteLLM instead.
if litellm GET /v1/agents | jq -e --arg n "$NAME" '.[] | select(.agent_name==$n) | .keys | length > 0' >/dev/null; then
  ok "already bound: $(litellm GET /v1/agents | jq -r --arg n "$NAME" '[.[] | select(.agent_name==$n) | .keys[].key_alias] | join(", ")')"
else
  litellm POST /key/generate "$(jq -n --arg a "$existing" --arg n "$NAME-agent" \
    '{key_alias: $n, agent_id: $a, max_budget: 10, budget_duration: "30d"}')" >/dev/null
  ok "created key $NAME-agent (budget \$10 / 30d; view or regenerate it in the UI: Virtual Keys)"
fi
echo "Call it: POST $GA/a2a/$NAME (A2A message/send), see README.md §2."
