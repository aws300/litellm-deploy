#!/usr/bin/env bash
# verify-cost-attribution.sh — 端到端验证 Bedrock 按 team / key 计费
#
#   1. CloudTrail（实时）：确认带 team+key Session Tag 的 AssumeRole 已发生
#   2. 激活 iamPrincipal/team 和 iamPrincipal/key Cost Allocation Tag（key 首次出现需 1-24h）
#   3. Cost Explorer（延迟 24-48h）：按 iamPrincipal/team 和 iamPrincipal/key 分组查 Bedrock 费用
#
# 用法:
#   ./verify-cost-attribution.sh                 # 全部步骤
#   ./verify-cost-attribution.sh --hours 6       # CloudTrail 回看窗口（默认 2h）
#   ./verify-cost-attribution.sh --days 14       # Cost Explorer 回看天数（默认 14）
set -euo pipefail

CT_HOURS=2; CE_DAYS=14
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hours) CT_HOURS="$2"; shift 2;;
    --days)  CE_DAYS="$2";  shift 2;;
    *) shift;;
  esac
done

EXEC_ROLE="nxdev-litellm-bedrock-exec"
START_CT=$(date -u -d "${CT_HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
           || python3 -c "from datetime import *;print((datetime.utcnow()-timedelta(hours=${CT_HOURS})).strftime('%Y-%m-%dT%H:%M:%SZ'))")
END_CT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START_CE=$(python3 -c "from datetime import *;print((date.today()-timedelta(days=${CE_DAYS})))")
END_CE=$(python3 -c "from datetime import *;print(date.today())")

echo "════════════════════════════════════════════════════════════"
echo " STEP 1 — CloudTrail 实时证据 (AssumeRole into ${EXEC_ROLE})"
echo " 窗口: ${START_CT} -> ${END_CT}"
echo "════════════════════════════════════════════════════════════"
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole \
  --start-time "$START_CT" --end-time "$END_CT" --region us-west-2 \
  --query 'Events[].CloudTrailEvent' --output json 2>/dev/null | python3 -c "
import json,sys
arr=json.loads(sys.stdin.read() or '[]')
rows=[]
for s in arr:
    e=json.loads(s); rp=e.get('requestParameters',{}) or {}
    if '${EXEC_ROLE}' in rp.get('roleArn',''):
        tags={t['key']:t['value'] for t in (rp.get('tags') or [])}
        rows.append((e['eventTime'],tags.get('team','-'),tags.get('key','-')))
rows.sort()
if not rows: print('  (窗口内无 team/key 标签的 AssumeRole)'); sys.exit()
print('  %-22s %-22s %s'%('time','team','key'))
for t,team,key in rows: print('  %-22s %-22s %s'%(t,team,key))
print('  合计 %d 次带标签 AssumeRole'%len(rows))
"

echo ""
echo "════════════════════════════════════════════════════════════"
echo " STEP 2 — 激活 Cost Allocation Tags"
echo "════════════════════════════════════════════════════════════"
for TAG in iamPrincipal/team iamPrincipal/key; do
  STATUS=$(aws ce list-cost-allocation-tags --region us-east-1 \
    --query "CostAllocationTags[?TagKey=='${TAG}'].Status" --output text 2>/dev/null || echo "")
  if [[ "$STATUS" == "Active" ]]; then
    echo "  [OK] ${TAG} 已 Active"
  elif [[ -n "$STATUS" ]]; then
    aws ce update-cost-allocation-tags-status --region us-east-1 \
      --cost-allocation-tags-status "[{\"TagKey\":\"${TAG}\",\"Status\":\"Active\"}]" >/dev/null 2>&1 \
      && echo "  [OK] ${TAG} 已激活 (was ${STATUS})" \
      || echo "  [WARN] ${TAG} 激活失败"
  else
    echo "  [PENDING] ${TAG} 尚未出现在 billing 系统（新标签键需 1-24h 传播），稍后重跑本脚本"
  fi
done

echo ""
echo "════════════════════════════════════════════════════════════"
echo " STEP 3 — Cost Explorer: Bedrock 费用 (延迟 24-48h)"
echo " 期间: ${START_CE} -> ${END_CE}"
echo "════════════════════════════════════════════════════════════"
for DIM in team key; do
  echo "  --- group by iamPrincipal/${DIM} ---"
  aws ce get-cost-and-usage --region us-east-1 \
    --time-period "Start=${START_CE},End=${END_CE}" --granularity MONTHLY \
    --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Bedrock"]}}' \
    --group-by "[{\"Type\":\"TAG\",\"Key\":\"iamPrincipal/${DIM}\"}]" \
    --metrics UnblendedCost --output json 2>/dev/null | python3 -c "
import json,sys
d=json.loads(sys.stdin.read() or '{}')
agg={}
for day in d.get('ResultsByTime',[]):
    for g in day.get('Groups',[]):
        k=(g.get('Keys',[''])[0] or '').split('\$',1)[-1] or '(untagged)'
        agg[k]=agg.get(k,0)+float(g['Metrics']['UnblendedCost']['Amount'])
if not agg: print('    (无数据 — Tag 未激活或账单尚未生成)'); sys.exit()
for k,v in sorted(agg.items(),key=lambda x:-x[1]):
    print('    %-40s \$%.4f'%(k,v))
" || echo "    (查询失败 — 检查 Tag 是否已激活)"
done
echo ""
echo "说明: CloudTrail(STEP1)是实时确定性证据; Cost Explorer(STEP3)受 AWS 账单管线 24-48h 延迟影响。"
