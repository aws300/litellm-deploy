# LiteLLM × Bedrock 费用归因 — 脚本与排错

按 **team / API key** 拆分 AWS Bedrock 费用的完整工具集。机制详见 [`bedrock-cost-attribution.md`](../bedrock-cost-attribution.md)。

---

## 计费链路（一句话）

```
LiteLLM Key(关联 Team) → async_pre_call_hook (bedrock_team_tag_hook.py)
  → STS AssumeRole(nxdev-litellm-bedrock-exec, Tags=[team,key])
  → Bedrock 以打标签的 IAM Principal 身份调用
  → CUR 2.0 Export(含 IAM principal 数据) → Cost Explorer iamPrincipal/team|key
```

链路任一环缺失，Cost Explorer 里 `iamPrincipal/*` 就会全是空值。下面脚本覆盖「实时观测」「官方账单」「链路自检」三类。

---

## 脚本一览

| 脚本 | 数据源 | 粒度 | 延迟 | 维度 | 依赖 |
|------|--------|------|------|------|------|
| `hourly-spend.sh` | LiteLLM `/spend/logs` | 小时 | 实时 | team / key | kubectl |
| `aws-bedrock-hourly.sh` | CloudWatch token 指标 | 小时/分钟 | 近实时(~10min) | **model** | aws cli |
| `aws-bedrock-cost.sh` | Cost Explorer | 天/月 | 24–48h | team / key（官方账单） | aws cli |
| `verify-export.sh` | bcm-data-exports / cur | — | — | 链路自检 | aws cli |
| `verify-cost-attribution.sh` | CloudTrail + CE | — | 混合 | 端到端验证 | aws cli |
| `activate-cost-tags.sh` | Cost Explorer | — | — | 激活 tag | aws cli |
| `litellm-team-spend.py` / `check-bedrock-cost.sh` | LiteLLM + CE | 天 | 混合 | team | kubectl, aws cli |

---

## 用法

### 实时按小时（按 team/key）— LiteLLM 数据
```bash
./hourly-spend.sh                 # 最近 24h，按小时
./hourly-spend.sh --hours 6 --by team
./hourly-spend.sh --hours 6 --by key
```

### 纯 AWS 按小时（按 model）— CloudWatch
绕过 Cost Explorer HOURLY 的付费 opt-in，用 CloudWatch token 用量 × 单价估算。
```bash
./aws-bedrock-hourly.sh           # 最近 6h，按小时×模型
./aws-bedrock-hourly.sh --hours 24
./aws-bedrock-hourly.sh --period 300   # 5 分钟粒度
```
> 仅能按 model 拆（CloudWatch 维度无 IAM principal）；金额为估算，非官方账单。

### 官方账单按 team/key — Cost Explorer
开头会自检 CUR Export / tag 激活 / 已出现的 tag 值，再按 team、key、总计分组。
```bash
./aws-bedrock-cost.sh             # 最近 14 天
./aws-bedrock-cost.sh --days 32
./aws-bedrock-cost.sh --by team
./aws-bedrock-cost.sh --daily
```

### 链路自检
```bash
./verify-export.sh                # 验证是否存在含 IAM principal 的 Export（根因排查）
./verify-cost-attribution.sh      # CloudTrail 实时证据 + 激活 tag + CE 查询
./activate-cost-tags.sh           # 激活 iamPrincipal/* cost allocation tag
```

---

## 排错：为什么 Cost Explorer 里看不到任何 tag 费用

实测根因（2026-06-02，账号 867344450900）：**从未创建含 IAM Principal 数据的 CUR Export**。
即使 `iamPrincipal/team` 标签早已 Active，连已 Active 一个月的 EKS 维度（`iamPrincipal/kubernetes-namespace` 等）也带不住成本——所有 Bedrock 费用都落在空值。

判定：
```bash
./verify-export.sh        # 输出 "0 个 / [致命] 无任何 Export" 即为此根因
```

**IAM Principal 归属数据只有在存在勾选了 IAM principal 选项的 CUR 2.0 Export 时才会被 AWS 生成。** 仅在 Cost Explorer Settings 激活 tag 不足以产出数据。

### 修复：创建 CUR 2.0 Export（含 IAM principal 数据）

控制台（最稳）：
```
Billing Console → Data Exports → Create export → 类型 Cost and Usage Report 2.0
  → 勾选 "Include caller identity (IAM principal) allocation data"
  → 选 S3 bucket → Create
```

或 CLI（需先有目标 S3 bucket 及其 bucket policy 允许 billingreports 写入）：
```bash
aws bcm-data-exports create-export --region us-east-1 --export '{
  "Name": "cnf-cur2-iam-principal",
  "DataQuery": {
    "QueryStatement": "SELECT bill_billing_period_start_date, line_item_usage_account_id, line_item_usage_start_date, line_item_product_code, line_item_unblended_cost, resource_tags FROM COST_AND_USAGE_REPORT",
    "TableConfigurations": {
      "COST_AND_USAGE_REPORT": {
        "TIME_GRANULARITY": "HOURLY",
        "INCLUDE_RESOURCES": "TRUE",
        "INCLUDE_SPLIT_COST_ALLOCATION_DATA": "TRUE"
      }
    }
  },
  "DestinationConfigurations": {"S3Destination": {
    "S3Bucket": "<YOUR_BUCKET>", "S3Prefix": "cur2", "S3Region": "us-east-1",
    "S3OutputConfigurations": {"OutputType":"CUSTOM","Format":"PARQUET","Compression":"PARQUET","Overwrite":"OVERWRITE_REPORT"}
  }},
  "RefreshCadence": {"Frequency": "SYNCHRONOUS"}
}'
```
> 注意：
> - Export **不追溯**历史，只对创建之后产生的带标签流量生效。
> - 心跳 CronJob (`../litellm-cost-heartbeat.yaml`) 每分钟产生带 team/key tag 的流量；创建 Export 后约 24–48h 即可在 `aws-bedrock-cost.sh` 看到各 team/key 的费用。
> - 创建后用 `./verify-export.sh` 复查，应显示 `含 IAM principal 字段: 是`。

---

## 持续产生测试费用（心跳）

```bash
kubectl apply -f ../litellm-cost-heartbeat.yaml          # 每分钟一次微调用
kubectl patch cronjob litellm-cost-heartbeat -n litellm -p '{"spec":{"suspend":true}}'   # 暂停
kubectl delete cronjob litellm-cost-heartbeat -n litellm # 删除
```
