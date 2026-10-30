#!/usr/bin/env bash
# 00-iam.sh — let LiteLLM's pods use the four aws-example integrations.
#
# Why: LiteLLM calls every AWS service with the stack's Pod role (EKS Pod
# Identity on ServiceAccount litellm/litellm-sa), whose CloudFormation policy
# covers Bedrock model calls only. This adds ONE inline policy, `aws-example`,
# next to it — kept out of the template so the integrations stay optional and
# the same script works on any LiteLLM deployment that has a Pod role:
#   - bedrock:ApplyGuardrail                 Bedrock Guardrails (10-guardrail.sh)
#   - bedrock-agentcore:InvokeAgentRuntime   the AgentCore agent (20-agentcore-agent.sh)
#   - bedrock-agentcore:InvokeGateway        Web Search on Amazon Bedrock (30-web-search.sh)
#   - s3vectors:*Vector* / *Index*           the S3 Vectors store (40-s3-vectors.sh)
# Each statement is scoped to the aws-example resources of this account.
# IAM changes apply to the running pods within seconds (no restart): the role
# is evaluated on every call.
#
# Does not touch the stack's own policies (a stack update leaves it in place).
# Idempotent (put-role-policy overwrites). Undo: cleanup.sh.
#
# Usage: ./00-iam.sh
source "$(dirname "$0")/lib.sh"

say "inline policy $NAME on $POD_ROLE"
policy=$(jq -n --arg a "$ACCOUNT" --arg n "$NAME" '{
  Version: "2012-10-17",
  Statement: [
    {Sid: "BedrockGuardrail", Effect: "Allow", Action: ["bedrock:ApplyGuardrail", "bedrock:GetGuardrail"],
     Resource: "arn:aws:bedrock:*:\($a):guardrail/*"},
    {Sid: "AgentCoreRuntime", Effect: "Allow",
     Action: ["bedrock-agentcore:InvokeAgentRuntime", "bedrock-agentcore:InvokeAgentRuntimeForUser"],
     Resource: "arn:aws:bedrock-agentcore:*:\($a):runtime/\($n | gsub("-"; "_"))*"},
    {Sid: "AgentCoreGateway", Effect: "Allow", Action: "bedrock-agentcore:InvokeGateway",
     Resource: "arn:aws:bedrock-agentcore:*:\($a):gateway/\($n)*"},
    {Sid: "S3Vectors", Effect: "Allow",
     Action: ["s3vectors:QueryVectors", "s3vectors:GetVectors", "s3vectors:PutVectors", "s3vectors:ListVectors",
              "s3vectors:GetIndex", "s3vectors:ListIndexes", "s3vectors:CreateIndex",
              "s3vectors:GetVectorBucket", "s3vectors:CreateVectorBucket"],
     Resource: "arn:aws:s3vectors:*:\($a):bucket/litellm-\($n)-*"}
  ]}')
aws iam put-role-policy --role-name "$POD_ROLE" --policy-name "$NAME" --policy-document "$policy"
ok "attached ($(jq -r '[.Statement[].Sid] | join(", ")' <<<"$policy"))"
