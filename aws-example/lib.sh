# lib.sh — shared helpers of the aws-example scripts (sourced, not run).
#
# Every value comes from the CloudNativeFormationLitellm stack's Outputs, so
# pointing the scripts at another deployment means changing STACK / REGION
# only. Override with env: STACK=litellm-use1 REGION=us-east-1 ./10-guardrail.sh
#
# LITELLM_ADMIN_KEY: a virtual key OWNED by a proxy_admin user. Create it in the
# admin UI (Virtual Keys -> + Create New Key, "Owned by: You") after signing in
# with a Cognito user of group `admin`. A key without an owner (created for
# "service account" / no user) cannot manage guardrails or search tools (401).
# The master key cannot either: it is read-only on this stack.

set -euo pipefail

STACK=${STACK:-litellm-use1}
REGION=${REGION:-us-east-1}
NAME=aws-example
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

say() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
ok() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$*" >&2; }
die() { printf '  \033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

need() { for c in "$@"; do command -v "$c" >/dev/null || die "missing command: $c"; done; }
need aws jq curl

out() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
GA=$(out A1ApiUrlGlobalAccelerator); GA=${GA%/}
POD_ROLE_ARN=$(out PodRoleArn)
POD_ROLE=${POD_ROLE_ARN##*/}
[[ -n $GA && $GA != None ]] || die "stack $STACK in $REGION has no output A1ApiUrlGlobalAccelerator"

# litellm METHOD PATH [JSON] -> body on stdout; dies on a non-2xx status.
litellm() {
  local method=$1 path=$2 body=${3:-} code
  [[ -n ${LITELLM_ADMIN_KEY:-} ]] || die "set LITELLM_ADMIN_KEY (see lib.sh header)"
  local args=(-sS -m 300 -o /tmp/aws-example.body -w '%{http_code}' -X "$method" "$GA$path"
    -H "Authorization: Bearer $LITELLM_ADMIN_KEY")
  [[ -n $body ]] && args+=(-H 'Content-Type: application/json' -d "$body")
  code=$(curl "${args[@]}") || die "$method $path: curl failed"
  if [[ $code != 2* ]]; then die "$method $path -> $code: $(head -c 500 /tmp/aws-example.body)"; fi
  cat /tmp/aws-example.body
}

# litellm_status METHOD PATH [JSON] -> "<code>" on stdout, body in /tmp/aws-example.body (no exit on error).
litellm_status() {
  local method=$1 path=$2 body=${3:-}
  local args=(-sS -m 300 -o /tmp/aws-example.body -w '%{http_code}' -X "$method" "$GA$path"
    -H "Authorization: Bearer ${LITELLM_KEY:-${LITELLM_ADMIN_KEY:-}}")
  [[ -n $body ]] && args+=(-H 'Content-Type: application/json' -d "$body")
  curl "${args[@]}" || echo 000
}
