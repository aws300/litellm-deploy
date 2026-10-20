#!/usr/bin/env bash
# hourly-spend.sh — 实时按小时查看 LiteLLM/Bedrock 费用（可按 team / key 拆分）
#
# 数据源: LiteLLM /spend/logs（逐请求、实时、零延迟），按 UTC 小时聚合。
# 对比: AWS Cost Explorer HOURLY 需 payer 账号 opt-in 且延迟 24-48h；本脚本即时。
#
# 用法:
#   ./hourly-spend.sh                  # 最近 24 小时，按小时
#   ./hourly-spend.sh --by team        # 按小时 × team
#   ./hourly-spend.sh --by key         # 按小时 × key(hash)
#   ./hourly-spend.sh --hours 6 --by team
set -euo pipefail

NS="${LITELLM_NAMESPACE:-litellm}"
HOURS=24; BY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hours) HOURS="$2"; shift 2;;
    --by)    BY="$2";    shift 2;;
    *) shift;;
  esac
done

MK=$(kubectl get secret litellm-masterkey -n "$NS" -o jsonpath='{.data.masterkey}' 2>/dev/null | base64 -d)
[ -z "$MK" ] && MK="sk-litellm-proxy-master-key"

kubectl exec -n "$NS" deploy/litellm -- python3 -c "
import urllib.request,json,collections
from datetime import datetime,timedelta,timezone
MK='$MK'; HOURS=$HOURS; BY='$BY'
cutoff=datetime.now(timezone.utc)-timedelta(hours=HOURS)
logs=[]
for off in range(0,5000,1000):
    req=urllib.request.Request(f'http://[::1]:4000/spend/logs?limit=1000',headers={'Authorization':'Bearer '+MK})
    try: batch=json.loads(urllib.request.urlopen(req,timeout=25).read())
    except Exception as e: print('ERR',e); break
    if not isinstance(batch,list) or not batch: break
    logs=batch; break  # this version returns full set; no offset paging
agg=collections.defaultdict(lambda:[0.0,0])  # key -> [spend, tokens]
def hour(ts): return (ts or '')[:13].replace('T',' ')+':00'
for l in logs:
    st=l.get('startTime','')
    try: dt=datetime.fromisoformat(st.replace('Z','+00:00'))
    except: continue
    if dt<cutoff: continue
    h=hour(st)
    if BY=='team':   dim=l.get('team_id') or '(no-team)'
    elif BY=='key':  dim=(l.get('api_key') or '')[:12] or '(no-key)'
    else:            dim=''
    k=(h,dim) if BY else (h,)
    agg[k][0]+=l.get('spend',0) or 0
    agg[k][1]+=l.get('total_tokens',0) or 0
if not agg:
    print(f'  最近 {HOURS}h 无 spend 记录（注意：LiteLLM spend logs 默认仅保留约 7 天）'); raise SystemExit
hdr='%-19s'%'hour(UTC)' + ('  %-16s'%BY if BY else '') + '  %12s  %10s'%('spend(USD)','tokens')
print(hdr); print('-'*len(hdr))
tot=0.0
for k in sorted(agg):
    sp,tk=agg[k]; tot+=sp
    line='%-19s'%k[0] + ('  %-16s'%k[1] if BY else '') + '  %12.6f  %10d'%(sp,tk)
    print(line)
print('-'*len(hdr)); print('TOTAL %.6f USD'%tot)
" 2>&1