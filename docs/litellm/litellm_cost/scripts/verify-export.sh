#!/usr/bin/env bash
# verify-export.sh — 用 CLI 验证 CUR / Data Export 是否存在且含 IAM Principal 归属数据
#
# 没有这样一个 Export，AWS 就不会生成 iamPrincipal/* 归属数据，
# Cost Explorer 中所有 iamPrincipal/team|key 永远为空值（即"看不到 tag 费用"的根因）。
#
# 仅依赖: aws cli + python3。
# 用法: ./verify-export.sh
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"

echo "Account: $(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
echo "════════════════════════════════════════════════════════════"
echo " 验证 CUR / Data Export（IAM Principal 归属数据来源）"
echo "════════════════════════════════════════════════════════════"

# 1) CUR 2.0 / BCM Data Exports
EXPORTS_JSON=$(aws bcm-data-exports list-exports --region "$REGION" --output json 2>/dev/null || echo '{"Exports":[]}')
N2=$(echo "$EXPORTS_JSON" | python3 -c "import json,sys;print(len(json.load(sys.stdin).get('Exports',[])))")
echo "CUR 2.0 (bcm-data-exports): ${N2} 个"
if [[ "$N2" -gt 0 ]]; then
  echo "$EXPORTS_JSON" | python3 -c "import json,sys;[print('  -',e['ExportArn']) for e in json.load(sys.stdin)['Exports']]"
  # 逐个检查列里是否含 IAM principal 字段
  for ARN in $(echo "$EXPORTS_JSON" | python3 -c "import json,sys;[print(e['ExportArn']) for e in json.load(sys.stdin)['Exports']]"); do
    echo "  检查列: $ARN"
    aws bcm-data-exports get-export --region "$REGION" --export-arn "$ARN" --output json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
q=d.get('Export',{}).get('DataQuery',{}).get('QueryStatement','')
sel=d.get('Export',{}).get('DataQuery',{}).get('TableConfigurations',{})
has=any(k in q.lower() for k in ['iam','principal','identity','resource_tags'])
print('    QueryStatement 片段:', q[:160])
print('    含 IAM/principal/identity 字段:', '是 [OK]' if has else '否 [需重建并勾选 IAM principal]')
"
  done
fi

# 2) Legacy CUR
LEGACY_JSON=$(aws cur describe-report-definitions --region "$REGION" --output json 2>/dev/null || echo '{"ReportDefinitions":[]}')
N1=$(echo "$LEGACY_JSON" | python3 -c "import json,sys;print(len(json.load(sys.stdin).get('ReportDefinitions',[])))")
echo "Legacy CUR (cur):           ${N1} 个"
if [[ "$N1" -gt 0 ]]; then
  echo "$LEGACY_JSON" | python3 -c "
import json,sys
for r in json.load(sys.stdin)['ReportDefinitions']:
    extra=r.get('AdditionalArtifacts',[]) + r.get('AdditionalSchemaElements',[])
    has=any('RESOURCE' in str(x).upper() or 'SPLIT' in str(x).upper() for x in extra)
    print('  -',r['ReportName'],'| schema:',r.get('AdditionalSchemaElements'),'| IAM/resource:', '是' if has else '否')
"
fi

echo "════════════════════════════════════════════════════════════"
if [[ "$N2" -eq 0 && "$N1" -eq 0 ]]; then
  echo " 结论: [致命] 无任何 Export → iamPrincipal/* 永远为空，tag 费用不可见。"
  echo " 修复: 创建 CUR 2.0 Export 并勾选 IAM principal 数据（见 README §修复）。"
  exit 2
else
  echo " 结论: 已存在 Export。若上面任一显示『含 IAM principal 字段: 否』，"
  echo "        需重建并勾选 'Include caller identity (IAM principal) allocation data'。"
fi
