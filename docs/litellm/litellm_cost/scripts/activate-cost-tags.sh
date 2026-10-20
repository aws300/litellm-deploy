#!/usr/bin/env bash
# activate-cost-tags.sh — 激活 AWS Cost Allocation Tags 用于 Bedrock 费用归因
#
# 用法:
#   ./activate-cost-tags.sh           # 一键激活所有 iamPrincipal/* Tags
#   ./activate-cost-tags.sh --poll    # 轮询等待 iamPrincipal/team 出现后激活
#   ./activate-cost-tags.sh --status  # 只查看当前状态
#
# 说明:
#   AWS billing 传播有延迟，iamPrincipal/team 首次出现可能需要 1-24 小时。
#   其他 6 个 EKS 自动 Tag（eks-cluster-name、kubernetes-namespace 等）可以立即激活。

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-west-2}"
POLL_INTERVAL="${POLL_INTERVAL:-300}"   # 轮询间隔（秒）
POLL_MAX="${POLL_MAX:-288}"             # 最多轮询次数（288 × 300s = 24h）

MODE="${1:-}"

# ── 颜色 ───────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✅  $*${NC}"; }
warn() { echo -e "  ${YELLOW}⚠️   $*${NC}"; }
info() { echo -e "  $*"; }

# ── 激活指定 Tags ───────────────────────────────────────────────
activate_tags() {
    local tags_json="$1"
    local result
    result=$(aws ce update-cost-allocation-tags-status \
        --cost-allocation-tags-status "$tags_json" \
        --output json 2>&1)
    local errors
    errors=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('Errors',[]))" 2>/dev/null)
    if [[ "$errors" == "[]" ]]; then
        return 0
    else
        echo "$errors"
        return 1
    fi
}

# ── 查看当前状态 ────────────────────────────────────────────────
show_status() {
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo "  当前 iamPrincipal/* Cost Allocation Tag 状态"
    echo "══════════════════════════════════════════════════════════"
    aws ce list-cost-allocation-tags \
        --query 'CostAllocationTags[?contains(TagKey,`iamPrincipal`)].[Status,TagKey,LastUsedDate]' \
        --output table 2>/dev/null || echo "  查询失败，检查 AWS 权限"
    echo ""
}

# ── 激活已存在的 6 个 EKS 自动 Tags ────────────────────────────
activate_eks_tags() {
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo "  Step 1: 激活 EKS 自动注入的 iamPrincipal/* Tags"
    echo "  （这 6 个 Tag 已存在，可立即激活）"
    echo "══════════════════════════════════════════════════════════"

    # 获取所有未激活的 iamPrincipal/* Tags
    local inactive_tags
    inactive_tags=$(aws ce list-cost-allocation-tags \
        --status Inactive \
        --query 'CostAllocationTags[?contains(TagKey,`iamPrincipal`)].TagKey' \
        --output json 2>/dev/null || echo "[]")

    local count
    count=$(echo "$inactive_tags" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)

    if [[ "$count" -eq 0 ]]; then
        ok "所有 iamPrincipal/* Tags 已处于 Active 状态"
        return
    fi

    info "发现 $count 个未激活 Tags，激活中..."

    # 构建激活 payload
    local payload
    payload=$(echo "$inactive_tags" | python3 -c "
import json, sys
keys = json.load(sys.stdin)
items = [{'TagKey': k, 'Status': 'Active'} for k in keys]
print(json.dumps(items))
")

    if activate_tags "$payload"; then
        ok "成功激活 $count 个 Tags"
        # 逐一列出
        echo "$inactive_tags" | python3 -c "
import json, sys
for k in json.load(sys.stdin):
    print(f'    + {k}')
"
    else
        warn "部分 Tag 激活失败，详情：$(activate_tags "$payload" 2>&1 || true)"
    fi
}

# ── 等待并激活 iamPrincipal/team ────────────────────────────────
wait_and_activate_team_tag() {
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo "  Step 2: 等待 iamPrincipal/team 出现并激活"
    echo "  （需要 AWS billing 传播，通常 1-24 小时）"
    echo "══════════════════════════════════════════════════════════"

    for ((i=1; i<=POLL_MAX; i++)); do
        local tag_status
        tag_status=$(aws ce list-cost-allocation-tags \
            --query "CostAllocationTags[?TagKey=='iamPrincipal/team'].[Status,LastUsedDate]" \
            --output json 2>/dev/null || echo "[]")

        if [[ "$tag_status" != "[]" ]] && [[ -n "$tag_status" ]]; then
            local status
            status=$(echo "$tag_status" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0][0] if d else '')" 2>/dev/null)
            local last_used
            last_used=$(echo "$tag_status" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0][1] if d else '')" 2>/dev/null)

            if [[ "$status" == "Active" ]]; then
                ok "iamPrincipal/team 已处于 Active 状态（LastUsed: $last_used）"
                return 0
            elif [[ "$status" == "Inactive" ]]; then
                info "发现 iamPrincipal/team（Inactive，LastUsed: $last_used），激活中..."
                if activate_tags '[{"TagKey":"iamPrincipal/team","Status":"Active"}]'; then
                    ok "iamPrincipal/team 激活成功！Cost Explorer 将在 24-48 小时内显示 team 维度数据。"
                    return 0
                fi
            fi
        fi

        local elapsed=$(( i * POLL_INTERVAL ))
        local hours=$(( elapsed / 3600 ))
        local mins=$(( (elapsed % 3600) / 60 ))
        if [[ $((i % 6)) -eq 0 ]]; then
            info "  [${hours}h${mins}m] 还未出现，继续等待...（下次检查: ${POLL_INTERVAL}s 后）"
        fi
        sleep "$POLL_INTERVAL"
    done

    warn "超过 24 小时未出现，请手动检查 AWS Billing Console"
    return 1
}

# ── 主流程 ──────────────────────────────────────────────────────
echo "══════════════════════════════════════════════════════════"
echo "  LiteLLM × Bedrock 费用归因 — Cost Allocation Tag 激活"
echo "  Account: $(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
echo "══════════════════════════════════════════════════════════"

case "$MODE" in
    --status)
        show_status
        ;;
    --poll)
        activate_eks_tags
        wait_and_activate_team_tag
        show_status
        ;;
    *)
        # 默认：激活已存在 Tags，不等待 iamPrincipal/team
        activate_eks_tags

        echo ""
        echo "══════════════════════════════════════════════════════════"
        echo "  Step 2: 检查 iamPrincipal/team"
        echo "══════════════════════════════════════════════════════════"

        team_exists=$(aws ce list-cost-allocation-tags \
            --query "CostAllocationTags[?TagKey=='iamPrincipal/team'].Status" \
            --output text 2>/dev/null || echo "")

        if [[ -n "$team_exists" ]]; then
            if [[ "$team_exists" == "Active" ]]; then
                ok "iamPrincipal/team 已激活"
            else
                info "发现 iamPrincipal/team（$team_exists），激活中..."
                if activate_tags '[{"TagKey":"iamPrincipal/team","Status":"Active"}]'; then
                    ok "iamPrincipal/team 激活成功"
                fi
            fi
        else
            warn "iamPrincipal/team 尚未出现在 billing 系统"
            echo ""
            info "原因: AWS billing 传播有延迟（1-24 小时）"
            info "已执行的 Bedrock 调用（携带 team Session Tag）正在处理中"
            info ""
            info "后续操作选项:"
            info "  方案 A（推荐）: 等 1-24 小时后重新运行此脚本"
            info "    ./activate-cost-tags.sh"
            info ""
            info "  方案 B: 轮询等待（自动检测并激活，每 5 分钟检查一次）"
            info "    nohup ./activate-cost-tags.sh --poll > /tmp/tag-activation.log 2>&1 &"
            info "    tail -f /tmp/tag-activation.log"
            info ""
            info "  方案 C: 手动检查后激活"
            info "    aws ce list-cost-allocation-tags --query 'CostAllocationTags[?contains(TagKey,\`iamPrincipal/team\`)]'"
            info "    aws ce update-cost-allocation-tags-status --cost-allocation-tags-status '[{\"TagKey\":\"iamPrincipal/team\",\"Status\":\"Active\"}]'"
        fi

        show_status

        echo "══════════════════════════════════════════════════════════"
        echo "  后续: 激活后需要新建 CUR 2.0 Export（如尚未创建）"
        echo "  → AWS Billing Console → Data Exports → Create"
        echo "  → 勾选: Include caller identity (IAM principal) allocation data"
        echo "══════════════════════════════════════════════════════════"
        ;;
esac
