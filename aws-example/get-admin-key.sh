#!/usr/bin/env bash
# get-admin-key.sh — mint a LiteLLM admin virtual key with kubectl (break-glass).
#
# Why: the aws-example scripts need a virtual key OWNED by a proxy_admin user,
# and the cluster holds none: the only key in a Secret is the master key, which
# is read-only on this stack (403 on /key/generate). Instead of signing in to
# the UI, this runs LiteLLM's own key generator inside a LiteLLM pod, directly
# against its database (DATABASE_URL of the pod), for the first proxy_admin
# user — the same row the UI's "Create New Key, Owned by: You" writes.
#
# Prints only the key (sk-...) on stdout. The key has a budget and expires its
# budget window like any other; delete it in the UI (Virtual Keys) when done.
# Needs: kubectl pointing at the stack's cluster, and one prior UI sign-in of
# a Cognito `admin` user (that creates the proxy_admin user row).
#
# Usage: export LITELLM_ADMIN_KEY=$(./get-admin-key.sh [alias] [budget_usd])
set -euo pipefail

ALIAS=${1:-aws-example-admin-$(date +%Y%m%d%H%M%S)}
BUDGET=${2:-20}
NS=${NS:-litellm}

pod=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=litellm \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
[[ -n $pod ]] || { echo "no running LiteLLM pod in namespace $NS" >&2; exit 1; }

kubectl -n "$NS" exec -i "$pod" -c litellm -- env ALIAS="$ALIAS" BUDGET="$BUDGET" python3 - <<'EOF'
import asyncio, os, sys
import litellm.proxy.proxy_server as ps
from litellm.caching.caching import DualCache
from litellm.proxy.utils import PrismaClient, ProxyLogging

async def main():
    ps.prisma_client = PrismaClient(database_url=os.environ["DATABASE_URL"],
                                    proxy_logging_obj=ProxyLogging(user_api_key_cache=DualCache()))
    await ps.prisma_client.connect()
    try:
        admins = await ps.prisma_client.db.litellm_usertable.find_many(where={"user_role": "proxy_admin"})
        if not admins:
            sys.exit("no proxy_admin user yet: sign in to the admin UI once with a Cognito `admin` user")
        from litellm.proxy.management_endpoints.key_management_endpoints import generate_key_helper_fn
        key = await generate_key_helper_fn(request_type="key", user_id=admins[0].user_id,
                                           key_alias=os.environ["ALIAS"], max_budget=float(os.environ["BUDGET"]),
                                           budget_duration="30d")
        print(f"key {os.environ['ALIAS']} for {admins[0].user_id}", file=sys.stderr)
        print(key["token"])
    finally:
        await ps.prisma_client.disconnect()

asyncio.run(main())
EOF
