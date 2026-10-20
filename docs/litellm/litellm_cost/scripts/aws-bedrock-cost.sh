#!/usr/bin/env bash
# aws-bedrock-cost.sh — 纯 AWS Cost Explorer 查询 Bedrock 费用（不依赖 LiteLLM）
#
# 维度: iamPrincipal/team（按 LiteLLM Team）、iamPrincipal/key（按 API Key）、或总计。
# 仅用 aws cli + python3。CE 数据延迟 24-48h。
#
# 用法:
#   ./aws-bedrock-cost.sh                      # 最近 14 天，按 team + 按 key + 总计
#   ./aws-bedrock-cost.sh --days 30            # 改回看天数
#   ./aws-bedrock-cost.sh --by team            # 只看按 team
#   ./aws-bedrock-cost.sh --by key             # 只看按 key
#   ./aws-bedrock-cost.sh --daily              # 按天明细（默认整段汇总 MONTHLY）
#   ./aws-bedrock-cost.sh --service "Amazon Bedrock"   # 改服务名
set -euo pipefail

DAYS=14; BY="all"; GRAN="MONTHLY"; SERVICE="Amazon Bedrock"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)    DAYS="$2"; shift 2;;
    --by)      BY="$2";   shift 2;;
    --daily)   GRAN="DAILY"; shift;;
    --service) SERVICE="$2"; shift 2;;
    *) shift;;
  esac
done

START=$(python3 -c "from datetime import *;print(date.today()-timedelta(days=$DAYS))")
END=$(python3 -c "from datetime import *;print(date.today())")

echo "Account : $(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
echo "Service : ${SERVICE}"
echo "Period  : ${START} -> ${END}  (granularity=${GRAN})"
echo ""

# ── 诊断: IAM Principal 计费链路是否就绪 ───────────────────────────
echo "=== 诊断: tag 计费链路前置条件 ==="
# 1) CUR / Data Export 是否存在（IAM Principal allocation data 的唯一来源）
CUR2=$(aws bcm-data-exports list-exports --region us-east-1 \
  --query 'length(Exports)' --output text 2>/dev/null || echo "?")
CUR1=$(aws cur describe-report-definitions --region us-east-1 \
  --query 'length(ReportDefinitions)' --output text 2>/dev/null || echo "?")
if [[ "$CUR2" == "0" && "$CUR1" == "0" ]]; then
  echo "  [致命] 无任何 CUR/Data Export → AWS 不会生成 IAM Principal 归属数据，"
  echo "         所有 iamPrincipal/* 永远为空值。这是费用看不到 tag 的根因。"
  echo "         修复: Billing Console → Data Exports → Create (CUR 2.0)，"
  echo "               勾选 'Include caller identity (IAM principal) allocation data'。"
else
  echo "  [OK] 存在 Export (CUR2.0=$CUR2, legacy=$CUR1)。请确认其勾选了 IAM principal 数据。"
fi
# 2) tag 激活状态
echo "  -- iamPrincipal/* Cost Allocation Tag 状态 --"
aws ce list-cost-allocation-tags --region us-east-1 \
  --query "CostAllocationTags[?contains(TagKey,'iamPrincipal/team') || contains(TagKey,'iamPrincipal/key')].[TagKey,Status]" \
  --output text 2>/dev/null | sed 's/^/    /' || echo "    (查询失败)"
# 3) CE 里实际能看到哪些 team / key tag 值（GetTags）
echo "  -- CE 中已出现的 tag 值 (近 ${DAYS} 天) --"
for TK in iamPrincipal/team iamPrincipal/key; do
  VALS=$(aws ce get-tags --region us-east-1 \
    --time-period "Start=${START},End=${END}" --tag-key "$TK" \
    --query 'Tags' --output text 2>/dev/null || echo "")
  if [[ -z "$VALS" ]]; then echo "    ${TK}: (无值 — 尚无带该 tag 的已入账费用)"
  else echo "    ${TK}: ${VALS}"; fi
done
echo ""

query() {  # $1 = group-by JSON or empty for total
  local groupby="$1"
  local args=(--region us-east-1
    --time-period "Start=${START},End=${END}"
    --granularity "${GRAN}"
    --filter "{\"Dimensions\":{\"Key\":\"SERVICE\",\"Values\":[\"${SERVICE}\"]}}"
    --metrics UnblendedCost --output json)
  [[ -n "$groupby" ]] && args+=(--group-by "$groupby")
  aws ce get-cost-and-usage "${args[@]}" 2>&1
}

render() {  # stdin = CE json; $1 = label; $2 = "grouped" or "total"
  python3 -c "
import json,sys
mode='$2'
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception:
    print('  查询失败:',raw[:200]); sys.exit()
if 'Tag keys not found' in raw or 'ValidationException' in raw:
    print('  [PENDING] 该 Tag 尚未在 billing 系统注册（新标签键需 1-24h）'); sys.exit()
rows=d.get('ResultsByTime',[])
agg={}
daily=[]
for day in rows:
    start=day['TimePeriod']['Start']
    if mode=='grouped':
        for g in (day.get('Groups') or []):
            k=(g.get('Keys',[''])[0] or '')
            k=k.split('\$',1)[-1] if '\$' in k else k
            k=k or '(untagged)'
            v=float(g['Metrics']['UnblendedCost']['Amount'])
            agg[k]=agg.get(k,0)+v
            daily.append((start,k,v))
    else:
        v=float(day.get('Total',{}).get('UnblendedCost',{}).get('Amount',0))
        agg['TOTAL']=agg.get('TOTAL',0)+v
        daily.append((start,'TOTAL',v))
if not agg:
    print('  (无数据 — Tag 未激活 / 无使用 / 账单未生成)'); sys.exit()
if '$GRAN'=='DAILY':
    print('  %-12s %-40s %12s'%('date','dim','USD'))
    for s,k,v in daily:
        if v: print('  %-12s %-40s %12.6f'%(s,k,v))
else:
    print('  %-40s %12s'%('dim','USD'))
    tot=0
    for k,v in sorted(agg.items(),key=lambda x:-x[1]):
        print('  %-40s %12.6f'%(k,v)); tot+=v
    print('  %-40s %12.6f'%('—— TOTAL',tot))
"
}

if [[ "$BY" == "all" || "$BY" == "team" ]]; then
  echo "=== group by iamPrincipal/team ==="
  query '[{"Type":"TAG","Key":"iamPrincipal/team"}]' | render "team" grouped; echo ""
fi
if [[ "$BY" == "all" || "$BY" == "key" ]]; then
  echo "=== group by iamPrincipal/key ==="
  query '[{"Type":"TAG","Key":"iamPrincipal/key"}]' | render "key" grouped; echo ""
fi
if [[ "$BY" == "all" || "$BY" == "total" ]]; then
  echo "=== total (no grouping) ==="
  query "" | render "total" total; echo ""
fi

echo "注: AWS Cost Explorer 数据延迟 24-48h；小时粒度需 payer 账号在 CE Settings 中 opt-in。"
