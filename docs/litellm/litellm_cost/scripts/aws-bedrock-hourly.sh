#!/usr/bin/env bash
# aws-bedrock-hourly.sh — 纯 AWS 的小时级 Bedrock 费用（不依赖 LiteLLM）
#
# 数据源: CloudWatch AWS/Bedrock token 指标（InputTokenCount / OutputTokenCount /
#          CacheReadInputTokenCount / CacheWriteInputTokenCount），按 ModelId 维度，
#          小时粒度，近实时（约 5-15 分钟），无需 Cost Explorer HOURLY opt-in。
# 成本: 用下方 PRICE 表（USD / 1M token）将 token 换算为美元。AWS Cost Explorer
#       的 HOURLY 是付费 opt-in 功能；本脚本绕过它，直接用 CloudWatch 用量估算。
# 仅依赖: aws cli + python3。
#
# 用法:
#   ./aws-bedrock-hourly.sh                       # 最近 6 小时，按小时×模型
#   ./aws-bedrock-hourly.sh --hours 24            # 最近 24 小时
#   ./aws-bedrock-hourly.sh --period 300          # 5 分钟粒度
#   ./aws-bedrock-hourly.sh --region us-west-2
set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"; HOURS=6; PERIOD=3600
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hours)  HOURS="$2";  shift 2;;
    --period) PERIOD="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    *) shift;;
  esac
done

START=$(python3 -c "from datetime import *;print((datetime.now(timezone.utc)-timedelta(hours=$HOURS)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
END=$(python3 -c "from datetime import *;print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")

# 发现有数据的 ModelId（去重）
MODELS=$(aws cloudwatch list-metrics --region "$REGION" --namespace AWS/Bedrock \
  --metric-name InputTokenCount --output json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); s=set()
for m in d.get('Metrics',[]):
    dims={x['Name']:x['Value'] for x in m.get('Dimensions',[])}
    if 'ModelId' in dims and 'ContextWindow' not in dims: s.add(dims['ModelId'])
print('\n'.join(sorted(s)))
")

echo "Account : $(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
echo "Region  : ${REGION}   Period: ${PERIOD}s   Window: ${START} -> ${END}"
echo "Source  : CloudWatch AWS/Bedrock token metrics × per-model price"
echo ""

stat() {  # $1 metric, $2 modelId  -> echo "ts<TAB>sum" per datapoint
  aws cloudwatch get-metric-statistics --region "$REGION" \
    --namespace AWS/Bedrock --metric-name "$1" \
    --dimensions Name=ModelId,Value="$2" \
    --start-time "$START" --end-time "$END" --period "$PERIOD" \
    --statistics Sum --output json 2>/dev/null | python3 -c "
import json,sys
for p in json.load(sys.stdin).get('Datapoints',[]):
    print('%s\t%d'%(p['Timestamp'],int(p['Sum'])))
"
}

# 收集所有 (model, metric, hour) -> tokens，交给 python 汇总与定价
{
for M in $MODELS; do
  for MET in InputTokenCount OutputTokenCount CacheReadInputTokenCount CacheWriteInputTokenCount; do
    stat "$MET" "$M" | while IFS=$'\t' read -r TS SUM; do
      echo -e "${M}\t${MET}\t${TS}\t${SUM}"
    done
  done
done
} | python3 -c "
import sys,collections
# 价格表 USD / 1M token: (input, output, cache_read, cache_write)
PRICE={
 'claude-haiku-4-5':   (1.00, 5.00, 0.10, 1.25),
 'claude-sonnet-4-6':  (3.00,15.00, 0.30, 3.75),
 'claude-sonnet-4-5':  (3.00,15.00, 0.30, 3.75),
 'claude-opus-4-6':    (5.00,25.00, 0.50, 6.25),
 'claude-opus-4-7':    (5.00,25.00, 0.50, 6.25),
 'claude-opus-4-8':    (5.00,25.00, 0.50, 6.25),
 'cohere.embed-v4':    (0.12, 0.00, 0.00, 0.00),
}
def price(model):
    for k,v in PRICE.items():
        if k in model: return v
    return (3.00,15.00,0.30,3.75)  # 默认按 sonnet 估
MET_IDX={'InputTokenCount':0,'OutputTokenCount':1,'CacheReadInputTokenCount':2,'CacheWriteInputTokenCount':3}
cell=collections.defaultdict(lambda: collections.defaultdict(float))  # (hour,model)->{tokens by met, cost}
tok =collections.defaultdict(lambda: collections.defaultdict(int))
for line in sys.stdin:
    parts=line.rstrip('\n').split('\t')
    if len(parts)!=4: continue
    model,met,ts,sm=parts
    hour=ts[:13].replace('T',' ')+':00'
    n=int(sm); idx=MET_IDX[met]; pr=price(model)[idx]
    cell[(hour,model)]['cost']+=n*pr/1_000_000
    tok[(hour,model)][met]+=n
if not cell:
    print('  最近窗口内无 Bedrock token 数据'); sys.exit()
print('  %-19s %-46s %10s %10s %12s'%('hour(UTC)','model','in_tok','out_tok','est_USD'))
print('  '+'-'*100)
gtot=0.0; hour_tot=collections.defaultdict(float)
for (hour,model) in sorted(cell):
    c=cell[(hour,model)]['cost']; gtot+=c; hour_tot[hour]+=c
    it=tok[(hour,model)]['InputTokenCount']; ot=tok[(hour,model)]['OutputTokenCount']
    print('  %-19s %-46s %10d %10d %12.6f'%(hour,model[:46],it,ot,c))
print('  '+'-'*100)
for h in sorted(hour_tot): print('  %-19s %-46s %10s %10s %12.6f'%(h,'(hour subtotal)','','',hour_tot[h]))
print('  '+'-'*100)
print('  %-66s %12.6f'%('TOTAL est. USD',gtot))
"
echo ""
echo "注: 成本=CloudWatch token×单价(估算)，非 AWS 官方账单；用于近实时小时级观测。"
echo "    官方账单对账请用 aws-bedrock-cost.sh（CE，延迟24-48h）。"
