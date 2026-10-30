#!/usr/bin/env bash
# get-admin-key.sh — mint (or delete) LiteLLM admin virtual keys with kubectl (break-glass).
#
# Why: the aws-example scripts need a virtual key OWNED by a proxy_admin user,
# and the cluster holds none: the only key in a Secret is the master key, which
# is read-only on this stack (403 on /key/generate). Instead of signing in to
# the UI, this runs LiteLLM's own key generator inside a LiteLLM pod, directly
# against its database (DATABASE_URL of the pod), for the first proxy_admin
# user — the same row the UI's "Create New Key, Owned by: You" writes.
#
# --delete removes keys by alias prefix through LiteLLM's /key/delete on the
# pod's localhost, NOT by deleting rows: the API also drops the key from the
# auth caches (in-memory, Valkey), so a deleted key stops working at once. It
# authenticates with a throw-away admin key minted the same way and deleted in
# the same call. Use it when the key to delete is lost, or to sweep old ones.
#
# Needs: kubectl pointing at the stack's cluster, and one prior UI sign-in of
# a Cognito `admin` user (that creates the proxy_admin user row).
#
# Usage:
#   export LITELLM_ADMIN_KEY=$(./get-admin-key.sh [alias] [budget_usd])   # mint; prints only sk-...
#   ./get-admin-key.sh --delete [alias-prefix]          # default prefix: aws-example-admin
#   ./get-admin-key.sh --list   [alias-prefix]
set -euo pipefail

MODE=mint
case ${1:-} in --delete) MODE=delete; shift ;; --list) MODE=list; shift ;; esac
if [[ $MODE == mint ]]; then
  ALIAS=${1:-aws-example-admin-$(date +%Y%m%d%H%M%S)}; BUDGET=${2:-20}
else
  ALIAS=${1:-aws-example-admin}; BUDGET=1
fi
NS=${NS:-litellm}

pod=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=litellm \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
[[ -n $pod ]] || { echo "no running LiteLLM pod in namespace $NS" >&2; exit 1; }

# stdout carries only the key: Prisma prints its own "query-engine <hash>" line there.
kubectl -n "$NS" exec -i "$pod" -c litellm -- env MODE="$MODE" ALIAS="$ALIAS" BUDGET="$BUDGET" python3 - <<'EOF' \
  | { grep -E '^sk-' || true; }
import asyncio, json, os, sys, time, urllib.request
import litellm.proxy.proxy_server as ps
from litellm.caching.caching import DualCache
from litellm.proxy.utils import PrismaClient, ProxyLogging

MODE, ALIAS = os.environ["MODE"], os.environ["ALIAS"]

def api(path, key, body):
    req = urllib.request.Request(f"http://localhost:4000{path}", data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=60).read())

async def main():
    ps.prisma_client = PrismaClient(database_url=os.environ["DATABASE_URL"],
                                    proxy_logging_obj=ProxyLogging(user_api_key_cache=DualCache()))
    await ps.prisma_client.connect()
    db = ps.prisma_client.db
    try:
        if MODE == "list" or MODE == "delete":
            rows = await db.litellm_verificationtoken.find_many(where={"key_alias": {"startswith": ALIAS}})
            for r in rows:
                print(f"{r.key_alias}\towner={r.user_id}\tspend={r.spend:.4f}\tbudget={r.max_budget}\tcreated={r.created_at:%F %T}",
                      file=sys.stderr)
            if MODE == "list" or not rows:
                print(f"{len(rows)} key(s) with alias prefix {ALIAS!r}", file=sys.stderr)
                return
        admins = await db.litellm_usertable.find_many(where={"user_role": "proxy_admin"})
        if not admins:
            sys.exit("no proxy_admin user yet: sign in to the admin UI once with a Cognito `admin` user")
        from litellm.proxy.management_endpoints.key_management_endpoints import generate_key_helper_fn
        # key_max_budget / key_budget_duration: the key's budget (max_budget would be the user's).
        alias = ALIAS if MODE == "mint" else f"tmp-key-delete-{int(time.time())}"
        key = (await generate_key_helper_fn(request_type="key", user_id=admins[0].user_id, key_alias=alias,
                                            key_max_budget=float(os.environ["BUDGET"]), key_budget_duration="30d"))["token"]
        if MODE == "mint":
            print(f"key {alias} for {admins[0].user_id}", file=sys.stderr)
            print(key)
            return
        aliases = sorted({r.key_alias for r in rows})
        out = api("/key/delete", key, {"key_aliases": aliases})
        print(f"deleted {len(out.get('deleted_keys') or [])} key(s): {', '.join(aliases)}", file=sys.stderr)
        api("/key/delete", key, {"keys": [key]})   # the throw-away key deletes itself last
    finally:
        await ps.prisma_client.disconnect()

asyncio.run(main())
EOF
