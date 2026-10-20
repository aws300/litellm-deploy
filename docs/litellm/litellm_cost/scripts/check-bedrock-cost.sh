#!/usr/bin/env bash
# check-bedrock-cost.sh — 查看按 Team 分组的 Bedrock 费用
# 用法: ./check-bedrock-cost.sh [OPTIONS]
#
# 功能:
#   1. 从 LiteLLM 内部 Spend Tracking 查看各 Team 费用（实时）
#   2. 从 AWS Cost Explorer 查看 iamPrincipal/team 维度费用（24-48h 延迟）
#   3. 对比两者差异（用于精度核对）
#   4. 查看指定 Team 的详细消费日志
#
# 依赖: kubectl, aws cli (v2), python3, jq (可选)
# 环境: 已配置 kubectl context 指向 EKS 集群，AWS CLI 已认证
set -euo pipefail

# ── 配置 ──────────────────────────────────────────────────────────
LITELLM_NAMESPACE="${LITELLM_NAMESPACE:-litellm}"
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-sk-litellm-proxy-master-key}"
AWS_REGION="${AWS_REGION:-us-west-2}"
DAYS_BACK="${DAYS_BACK:-7}"   # 查询最近 N 天
TEAM_FILTER="${TEAM_FILTER:-}"  # 可选: 只看某个 Team
# ─────────────────────────────────────────────────────────────────

# 获取 LiteLLM Service 的 ClusterIP
get_svc_url() {
    local ip
    ip=$(kubectl get svc litellm -n "$LITELLM_NAMESPACE" \
         -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    if [[ "$ip" == *:* ]]; then
        echo "http://[$ip]:4000"
    else
        echo "http://$ip:4000"
    fi
}

# 通过 kubectl exec 调用 LiteLLM API（避免集群外访问问题）
litellm_api() {
    local path="$1"
    kubectl exec -n "$LITELLM_NAMESPACE" deploy/litellm -- \
        python3 -c "
import urllib.request, json, sys
req = urllib.request.Request(
    'http://[::1]:4000${path}',
    headers={'Authorization': 'Bearer ${LITELLM_MASTER_KEY}'}
)
try:
    r = urllib.request.urlopen(req, timeout=15)
    print(r.read().decode())
except Exception as e:
    print(json.dumps({'error': str(e)}))
" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────
# Part 1: LiteLLM 内部 Spend Tracking（实时）
# ─────────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════"
echo "  Part 1: LiteLLM Spend Tracking（实时）"
echo "  查询最近 ${DAYS_BACK} 天，按 Team 分组"
echo "═══════════════════════════════════════════════════════════"

litellm_api "/spend/teams" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
teams = data if isinstance(data, list) else data.get('data', [])

if not teams:
    print('  无数据（可能无 Team 费用记录）')
    sys.exit(0)

# 按消费排序
teams_sorted = sorted(teams, key=lambda t: t.get('spend', 0), reverse=True)
print(f'  {'Team Alias':<30} {'Team ID':<38} {'Spend (USD)':>12}')
print(f'  {\"─\"*30} {\"─\"*38} {\"─\"*12}')
total = 0
for t in teams_sorted:
    alias = (t.get('team_alias') or t.get('team_id', 'N/A'))[:30]
    tid   = (t.get('team_id') or '')[:38]
    spend = t.get('spend', 0)
    total += spend
    print(f'  {alias:<30} {tid:<38} \${spend:>11.4f}')
print(f'  {\"─\"*80}')
print(f'  {\"TOTAL\":<68} \${total:>12.4f}')
" 2>/dev/null || echo "  无法获取 Team Spend 数据"

echo ""

# ─────────────────────────────────────────────────────────────────
# Part 2: 指定 Team 的详细消费日志
# ─────────────────────────────────────────────────────────────────
if [[ -n "$TEAM_FILTER" ]]; then
    echo "═══════════════════════════════════════════════════════════"
    echo "  Part 2: Team \"${TEAM_FILTER}\" 详细消费日志"
    echo "═══════════════════════════════════════════════════════════"

    # 先获取 team_id
    TEAM_ID=$(litellm_api "/team/list" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
teams = data if isinstance(data, list) else data.get('data', [])
for t in teams:
    if t.get('team_alias') == '${TEAM_FILTER}' or t.get('team_id') == '${TEAM_FILTER}':
        print(t.get('team_id',''))
        break
" 2>/dev/null)

    if [[ -z "$TEAM_ID" ]]; then
        echo "  找不到 Team: ${TEAM_FILTER}"
    else
        litellm_api "/spend/logs?team_id=${TEAM_ID}&limit=20" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
logs = data if isinstance(data, list) else data.get('data', [])
logs = sorted(logs, key=lambda x: x.get('startTime','') or '', reverse=True)[:20]
print(f'  {'Time':<22} {'Model':<45} {'Tokens':>8} {'Cost(USD)':>10}')
print(f'  {\"─\"*22} {\"─\"*45} {\"─\"*8} {\"─\"*10}')
for log in reversed(logs):
    ts    = (log.get('startTime') or '')[:19]
    model = (log.get('model') or '').split('/')[-1][:45]
    tok   = log.get('total_tokens', 0)
    cost  = log.get('spend', 0)
    print(f'  {ts:<22} {model:<45} {tok:>8} \${cost:>9.5f}')
" 2>/dev/null
    fi
    echo ""
fi

# ─────────────────────────────────────────────────────────────────
# Part 3: AWS Cost Explorer — iamPrincipal/team 维度
# ─────────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════"
echo "  Part 3: AWS Cost Explorer — iamPrincipal/team（24-48h 延迟）"
echo "  查询最近 ${DAYS_BACK} 天，Service=AmazonBedrock"
echo "═══════════════════════════════════════════════════════════"

START_DATE=$(date -d "${DAYS_BACK} days ago" +%Y-%m-%d 2>/dev/null || \
             date -v-${DAYS_BACK}d +%Y-%m-%d 2>/dev/null || \
             python3 -c "from datetime import date, timedelta; print(date.today()-timedelta(days=${DAYS_BACK}))")
END_DATE=$(date +%Y-%m-%d)

aws ce get-cost-and-usage \
    --region us-east-1 \
    --time-period "Start=${START_DATE},End=${END_DATE}" \
    --granularity DAILY \
    --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Bedrock"]}}' \
    --group-by '[{"Type":"TAG","Key":"iamPrincipal/team"}]' \
    --metrics "UnblendedCost" \
    --output json \
    2>/dev/null | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
results = data.get('ResultsByTime', [])

if not results:
    print('  无数据（Tag 可能尚未激活，或 Cost Explorer 延迟中）')
    sys.exit(0)

# 汇总每个 team 的总费用
team_costs = {}
for day in results:
    for group in day.get('Groups', []):
        keys = group.get('Keys', [])
        team = keys[0] if keys else 'untagged'
        team = team.replace('iamPrincipal/team\$', '').strip() or 'untagged'
        cost = float(group.get('Metrics', {}).get('UnblendedCost', {}).get('Amount', 0))
        team_costs[team] = team_costs.get(team, 0) + cost

# 排序输出
sorted_teams = sorted(team_costs.items(), key=lambda x: x[1], reverse=True)
print(f\"  {'Tag: iamPrincipal/team':<45} {'Total USD':>12}\")
print(f\"  {'─'*45} {'─'*12}\")
total = 0
for team, cost in sorted_teams:
    print(f\"  {team:<45} \${cost:>11.4f}\")
    total += cost
print(f\"  {'─'*57}\")
print(f\"  {'TOTAL Bedrock':<45} \${total:>11.4f}\")
print(f\"\n  Period: ${START_DATE} to ${END_DATE}\")
" 2>/dev/null || echo "  AWS Cost Explorer 查询失败（检查 AWS 权限或 Tag 是否已激活）"

echo ""

# ─────────────────────────────────────────────────────────────────
# Part 4: 按 Team + 天 的明细（仅 AWS Cost Explorer）
# ─────────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════"
echo "  Part 4: AWS Cost Explorer — 按天明细（最近 7 天）"
echo "═══════════════════════════════════════════════════════════"

aws ce get-cost-and-usage \
    --region us-east-1 \
    --time-period "Start=$(date -d '7 days ago' +%Y-%m-%d 2>/dev/null || python3 -c 'from datetime import date,timedelta; print(date.today()-timedelta(days=7))')",End=$(date +%Y-%m-%d)" \
    --granularity DAILY \
    --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Bedrock"]}}' \
    --group-by '[{"Type":"TAG","Key":"iamPrincipal/team"}]' \
    --metrics "UnblendedCost" \
    --output json \
    2>/dev/null | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
results = data.get('ResultsByTime', [])
if not results:
    print('  无数据')
    sys.exit(0)

# 收集所有 teams
all_teams = set()
for day in results:
    for group in day.get('Groups', []):
        keys = group.get('Keys', [])
        team = (keys[0] if keys else '').replace('iamPrincipal/team\$','').strip() or 'untagged'
        all_teams.add(team)

all_teams = sorted(all_teams)
# 表头
header = f\"  {'Date':<12}\"
for t in all_teams:
    header += f\" {t[:18]:>18}\"
print(header)
print(f\"  {'─'*12}\" + f\" {'─'*18}\" * len(all_teams))

for day in results:
    date_str = day.get('TimePeriod', {}).get('Start', '')[:10]
    costs = {(g.get('Keys',[None])[0] or '').replace('iamPrincipal/team\$','').strip() or 'untagged':
             float(g.get('Metrics',{}).get('UnblendedCost',{}).get('Amount',0))
             for g in day.get('Groups', [])}
    row = f\"  {date_str:<12}\"
    for t in all_teams:
        c = costs.get(t, 0)
        row += f\" \${c:>17.4f}\"
    print(row)
" 2>/dev/null || echo "  AWS Cost Explorer 查询失败"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  提示:"
echo "  - LiteLLM Spend (Part 1/2) 是实时数据，基于本地 cost map"
echo "  - AWS Cost Explorer (Part 3/4) 是 AWS 官方账单，延迟 24-48h"
echo "  - 两者差异 <5% 属于正常（定价时间差 + 小数精度）"
echo "  - 若差异 >10%，检查 model_info 中的定价配置"
echo "═══════════════════════════════════════════════════════════"
