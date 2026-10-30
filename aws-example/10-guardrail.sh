#!/usr/bin/env bash
# 10-guardrail.sh — Bedrock Guardrails in LiteLLM (guardrail `aws-example`).
#
# Why: Bedrock Guardrails filters prompts and answers of ANY model behind
# LiteLLM (also non-Bedrock ones) with the ApplyGuardrail API, so one policy
# covers every client. This script:
#   1. creates (or reuses) the Bedrock guardrail `aws-example` in $REGION:
#      content filters (hate, insults, sexual, violence, misconduct, prompt
#      attack), a denied topic (personalised investment advice), PII handling
#      (e-mail / phone anonymised, card number / US SSN / AWS secret key blocked);
#      then publishes a numbered version (DRAFT is never used by LiteLLM);
#   2. registers it in LiteLLM (POST /guardrails, DB-stored, every pod) as
#      `aws-example`, mode pre_call + post_call, default_on false: a request
#      opts in with "guardrails": ["aws-example"], or attach it to a key / team
#      in the UI (Guardrails) to enforce it for everything that key sends.
# Re-running it updates the guardrail in place and publishes a new version only
# when the policy changed (the LiteLLM entry is re-pointed to it).
#
# Usage: LITELLM_ADMIN_KEY=sk-... ./10-guardrail.sh
source "$(dirname "$0")/lib.sh"

say "1. Bedrock guardrail $NAME ($REGION)"
policy_args=(
  --blocked-input-messaging "Sorry, this request is not allowed by the aws-example guardrail."
  --blocked-outputs-messaging "Sorry, the answer was blocked by the aws-example guardrail."
  --content-policy-config '{"filtersConfig":[
    {"type":"HATE","inputStrength":"HIGH","outputStrength":"HIGH"},
    {"type":"INSULTS","inputStrength":"HIGH","outputStrength":"HIGH"},
    {"type":"SEXUAL","inputStrength":"HIGH","outputStrength":"HIGH"},
    {"type":"VIOLENCE","inputStrength":"HIGH","outputStrength":"HIGH"},
    {"type":"MISCONDUCT","inputStrength":"HIGH","outputStrength":"HIGH"},
    {"type":"PROMPT_ATTACK","inputStrength":"HIGH","outputStrength":"NONE"}]}'
  --topic-policy-config '{"topicsConfig":[{"name":"investment-advice","type":"DENY",
    "definition":"Personalised recommendations to buy, sell or hold specific stocks, funds, cryptocurrencies or other financial assets.",
    "examples":["Which stock should I buy this week?","Should I put my savings into bitcoin?"]}]}'
  --sensitive-information-policy-config '{"piiEntitiesConfig":[
    {"type":"EMAIL","action":"ANONYMIZE"},
    {"type":"PHONE","action":"ANONYMIZE"},
    {"type":"CREDIT_DEBIT_CARD_NUMBER","action":"BLOCK"},
    {"type":"US_SOCIAL_SECURITY_NUMBER","action":"BLOCK"},
    {"type":"AWS_SECRET_KEY","action":"BLOCK"}]}'
)
gid=$(aws bedrock list-guardrails --region "$REGION" --query "guardrails[?name=='$NAME'].id | [0]" --output text)
if [[ $gid == None || -z $gid ]]; then
  gid=$(aws bedrock create-guardrail --region "$REGION" --name "$NAME" \
    --description "LiteLLM aws-example guardrail" "${policy_args[@]}" --query guardrailId --output text)
  ok "created $gid"
else
  aws bedrock update-guardrail --region "$REGION" --guardrail-identifier "$gid" --name "$NAME" \
    --description "LiteLLM aws-example guardrail" "${policy_args[@]}" >/dev/null
  ok "updated $gid"
fi
timeout 300 bash -c "until [[ \$(aws bedrock get-guardrail --region $REGION --guardrail-identifier $gid --query status --output text) == READY ]]; do sleep 5; done"
# Publish a version only if DRAFT differs from the newest one (versions are immutable).
# Compared on the policy fields only: metadata (description, timestamps) differs per version.
policy_keys='{topicPolicy, contentPolicy, wordPolicy, sensitiveInformationPolicy, contextualGroundingPolicy, blockedInputMessaging, blockedOutputsMessaging}'
latest=$(aws bedrock list-guardrails --region "$REGION" --guardrail-identifier "$gid" \
  --query "guardrails[?version!='DRAFT'].version | sort_by(@, &to_number(@)) | [-1]" --output text)
draft_hash=$(aws bedrock get-guardrail --region "$REGION" --guardrail-identifier "$gid" --guardrail-version DRAFT --output json \
  | jq -S "$policy_keys" | sha256sum)
latest_hash=
if [[ $latest != None && -n $latest ]]; then
  latest_hash=$(aws bedrock get-guardrail --region "$REGION" --guardrail-identifier "$gid" --guardrail-version "$latest" --output json \
    | jq -S "$policy_keys" | sha256sum)
fi
if [[ $draft_hash != "$latest_hash" ]]; then
  version=$(aws bedrock create-guardrail-version --region "$REGION" --guardrail-identifier "$gid" \
    --description "aws-example $(date -u +%FT%TZ)" --query version --output text)
  ok "published version $version"
else
  version=$latest; ok "version $version is current"
fi

say "2. LiteLLM guardrail $NAME"
spec=$(jq -n --arg n "$NAME" --arg g "$gid" --arg v "$version" --arg r "$REGION" '{guardrail: {
  guardrail_name: $n,
  litellm_params: {guardrail: "bedrock", mode: ["pre_call", "post_call"], default_on: false,
                   guardrailIdentifier: $g, guardrailVersion: $v, aws_region_name: $r,
                   mask_request_content: true, mask_response_content: true},
  guardrail_info: {description: "Bedrock Guardrails: content filters, denied topic investment-advice, PII anonymise / block"}}}')
# /v2: /guardrails/list returns only config.yaml guardrails, not DB-stored ones.
existing=$(litellm GET /v2/guardrails/list | jq -r --arg n "$NAME" '.guardrails[] | select(.guardrail_name==$n) | .guardrail_id' | head -1)
if [[ -n $existing ]]; then
  litellm PUT "/guardrails/$existing" "$spec" >/dev/null; ok "updated LiteLLM guardrail $existing -> $gid v$version"
else
  id=$(litellm POST /guardrails "$spec" | jq -r .guardrail_id); ok "created LiteLLM guardrail $id -> $gid v$version"
fi
echo "Use it: add \"guardrails\": [\"$NAME\"] to a request, or attach it to a key / team in the UI."
