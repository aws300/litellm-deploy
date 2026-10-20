# LiteLLM × AWS Bedrock 团队费用归因完整文档

> **适用版本：** LiteLLM `v1.83.14-stable.patch.3`
> **实测环境：** EKS us-west-2，EKS Pod Identity（`nxdev-PodRole`），Namespace `litellm`
> **配置完成日期：** 2026-05-09 | **账号 ID：** 867344450900

---

## 一、功能目标

AWS Bedrock 于 2026 年 4 月发布 **IAM Principal-based Cost Attribution**，允许通过 STS Session Tags
在 AWS Cost Explorer / CUR 2.0 中按自定义维度拆解 Bedrock 推理费用。

本文档实现以下两个计费目标（机制完全相同，零额外工作量差异）：

| 目标 | 实现方式 | AWS 查询维度 |
|------|---------|------------|
| **按 LiteLLM Team Name 查看 Bedrock 账单** | Team `team_alias` 写入 STS Session Tag | Cost Explorer → Tag `iamPrincipal/team` |
| **按 API Key 的 Team Name 查看 Bedrock 账单** | API Key 关联 Team，`team_alias` 自动继承 | 同上（每个 Key 天然属于一个 Team） |

---

## 二、整体架构

```
API Key 请求（sk-xxx，属于 Team "data-science"）
      ↓
LiteLLM async_pre_call_hook（bedrock_team_tag_hook.py）
      ↓ 读取 user_api_key_dict.team_alias = "data-science"
      ↓ 查 TTL Cache（55 分钟）→ miss
      ↓
      sts.assume_role(
          RoleArn  = nxdev-litellm-bedrock-exec
          Session  = "litellm-data-science"
          Tags     = [{Key:"team", Value:"data-science"}]
      )
      ↓ 注入临时凭证到 request data
      ↓
Bedrock InvokeModel（以 nxdev-litellm-bedrock-exec/litellm-data-science 身份）
      ↓
AWS Billing Pipeline（处理延迟 1-24 小时）
      ↓
CUR 2.0 新增列：
  line_item_iam_principal = assumed-role/nxdev-litellm-bedrock-exec/litellm-data-science
  iamPrincipal/team       = "data-science"
      ↓
AWS Cost Explorer → Group By: Tag → iamPrincipal/team
  data-science:  $xxx.xx
  platform-eng:  $xxx.xx
  infra-ops:     $xxx.xx
```

**LiteLLM 内部 Spend Tracking vs AWS Cost Explorer 定位：**

| 维度 | LiteLLM Spend Tracking | AWS Cost Explorer |
|------|----------------------|------------------|
| 数据来源 | LiteLLM 本地数据库 | AWS 官方账单 CUR 2.0 |
| 延迟 | **实时** | **24-48 小时** |
| 精度 | 依赖本地 cost map | **AWS 官方精确账单** |
| 用途 | 实时预算控制、限速告警 | 财务核对、FinOps、跨团队分摊 |

两者互补，不可替代。

---

## 三、已完成的 AWS 配置

### 3.1 IAM 角色结构

```
nxdev-PodRole（EKS Pod Identity，预先存在）
  ├── 原有策略 CNFPodReadOnly（含 bedrock:InvokeModel 等）
  └── 新增内联策略 StsAssumeBedrockExec
        Action: sts:AssumeRole + sts:TagSession
        Resource: arn:aws:iam::867344450900:role/nxdev-litellm-bedrock-exec

nxdev-litellm-bedrock-exec（2026-05-09 新建）
  ├── 信任策略：允许 nxdev-PodRole AssumeRole + TagSession
  └── 内联策略 BedrockInvokePolicy
        Action: bedrock:InvokeModel/InvokeModelWithResponseStream/List*
        Resource: *
```

**创建命令（已执行，仅供记录）：**

```bash
# 创建 Bedrock 执行角色
aws iam create-role \
  --role-name nxdev-litellm-bedrock-exec \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Sid": "AllowLiteLLMPodRoleAssume",
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::867344450900:role/nxdev-PodRole"},
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }]
  }' \
  --tags Key=Project,Value=litellm Key=ManagedBy,Value=litellm-bedrock-team-tag

# 附加 Bedrock 权限
aws iam put-role-policy \
  --role-name nxdev-litellm-bedrock-exec \
  --policy-name BedrockInvokePolicy \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:ListFoundationModels",
        "bedrock:GetFoundationModel",
        "bedrock:ListInferenceProfiles",
        "bedrock:GetInferenceProfile"
      ],
      "Resource": "*"
    }]
  }'

# 允许 nxdev-PodRole 调用 STS AssumeRole
aws iam put-role-policy \
  --role-name nxdev-PodRole \
  --policy-name StsAssumeBedrockExec \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["sts:AssumeRole", "sts:TagSession"],
      "Resource": "arn:aws:iam::867344450900:role/nxdev-litellm-bedrock-exec"
    }]
  }'
```

### 3.2 CloudTrail 验证（已确认正常，2026-05-09）

以下 CloudTrail 记录**证明 Session Tag 注入机制完全正确**：

```
AssumeRole 调用（2026-05-09 01:31~01:32）：
  RoleArn: arn:aws:iam::867344450900:role/nxdev-litellm-bedrock-exec
  RoleSessionName: litellm-infra-ops   → Tags: [{team: infra-ops}]
  RoleSessionName: litellm-data-science → Tags: [{team: data-science}]
  RoleSessionName: litellm-platform-eng → Tags: [{team: platform-eng}]

Bedrock InvokeModel 调用（同时段）：
  Principal: assumed-role/nxdev-litellm-bedrock-exec/litellm-infra-ops    ✅
  Principal: assumed-role/nxdev-litellm-bedrock-exec/litellm-data-science ✅
  Principal: assumed-role/nxdev-litellm-bedrock-exec/litellm-platform-eng ✅
```

CloudTrail 验证命令：

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole \
  --start-time "$(date -u -d '2 hours ago' '+%Y-%m-%dT%H:%M:%SZ')" \
  --query 'Events[*].CloudTrailEvent' \
  --output json | python3 -c "
import json, sys
for raw in json.load(sys.stdin):
    e = json.loads(raw)
    req = e.get('requestParameters', {})
    if 'litellm-bedrock-exec' in req.get('roleArn', ''):
        print('Time:   ', e['eventTime'])
        print('Session:', req.get('roleSessionName'))
        print('Tags:   ', req.get('tags', []))
        print('---')
"
```

---

## 四、为什么 Billing Console 里没有 `iamPrincipal/team`

### 现象

在 AWS Billing Console → Cost Allocation Tags → 筛选 "IAM Principal" 时，能看到以下 6 个 Tag 但**看不到 `iamPrincipal/team`**：

```
✅ Active — iamPrincipal/eks-cluster-arn
✅ Active — iamPrincipal/eks-cluster-name
✅ Active — iamPrincipal/kubernetes-namespace
✅ Active — iamPrincipal/kubernetes-pod-name
✅ Active — iamPrincipal/kubernetes-pod-uid
✅ Active — iamPrincipal/kubernetes-service-account
⏳ 尚未出现 — iamPrincipal/team
```

### 根本原因：AWS Billing Pipeline 处理延迟（非配置错误）

```
Bedrock 调用携带 Session Tag team=xxx
      ↓
      CloudTrail 实时记录 ✅（已确认，见 §3.2）
      ↓
      AWS Billing Pipeline 异步处理（1-24 小时）
      ← 当前卡在这里
      ↓
      iamPrincipal/team 出现在 list-cost-allocation-tags
      ↓
      激活（脚本自动或手动）
      ↓
      再等 24-48 小时
      ↓
      Cost Explorer 显示 iamPrincipal/team 维度数据 🎯
```

### 为什么那 6 个 EKS Tags 已经出现？

这 6 个 EKS Tags 是 EKS Pod Identity **从 2026-05-01 起就一直在写入**的，billing pipeline 早已处理过，所以能看到。

`iamPrincipal/team` 是**今天（2026-05-09）第一次写入**，AWS billing pipeline 尚未处理完成。这是 AWS 的正常行为，不是配置问题。

### 两类 Bedrock 调用在 CUR 中的区别

| 调用类型 | Principal ARN 示例 | CUR 中可用 Tag |
|---------|-------------------|--------------|
| **有 Team 的请求**（Hook 注入临时凭证） | `assumed-role/nxdev-litellm-bedrock-exec/litellm-data-science` | `iamPrincipal/team` = "data-science" |
| **无 Team 的请求**（master key 或无 Team 的 Key） | `assumed-role/nxdev-PodRole/eks-nxdev-litellm-xxx` | `iamPrincipal/eks-cluster-name` 等 EKS 维度 |

---

## 五、激活 `iamPrincipal/team` Tag（等 billing pipeline 处理完后执行）

### 方法一：使用脚本（推荐）

```bash
cd docs/litellm/litellm_cost

# 一次性检查并激活所有 iamPrincipal/* Tags
./scripts/activate-cost-tags.sh

# 后台轮询：iamPrincipal/team 出现后自动激活（每 5 分钟检查一次，最多 24h）
nohup ./scripts/activate-cost-tags.sh --poll > /tmp/tag-activation.log 2>&1 &
tail -f /tmp/tag-activation.log

# 仅查看当前状态
./scripts/activate-cost-tags.sh --status
```

### 方法二：手动命令行

```bash
# Step 1: 检查 Tag 是否已出现（1-24 小时后执行）
aws ce list-cost-allocation-tags \
  --query "CostAllocationTags[?TagKey=='iamPrincipal/team']" \
  --output table

# Step 2: 出现后一条命令激活
aws ce update-cost-allocation-tags-status \
  --cost-allocation-tags-status '[{"TagKey":"iamPrincipal/team","Status":"Active"}]'

# Step 3: 确认激活成功
aws ce list-cost-allocation-tags --status Active \
  --query "CostAllocationTags[?TagKey=='iamPrincipal/team']" \
  --output table
```

### 方法三：AWS Billing Console

```
1. 打开 https://console.aws.amazon.com/billing/home#/tags
2. 筛选 Type = "IAM Principal"
3. 等 iamPrincipal/team 出现（1-24 小时后刷新页面）
4. 勾选 → Activate
```

> 注意：必须在 **Management Account**（账号 ID 867344450900）操作，成员账号无法激活。

---

## 六、创建 CUR 2.0 Export（一次性操作，Tag 激活后执行）

**已有的 Export 不会追溯更新**，必须新建一个含 IAM Principal 数据的 Export：

```
AWS Billing Console
  → Data Exports → Create export
  → Export type: Cost and usage report
  → 勾选: "Include caller identity (IAM principal) allocation data"  ← 关键
  → 配置 S3 bucket
  → Create
```

---

## 七、LiteLLM 侧配置详情

### 7.1 ConfigMaps（不被 Helm 管理）

```bash
# 部署 / 更新 bedrock_team_tag_hook.py
kubectl create configmap litellm-bedrock-team-tag-hook -n litellm \
  --from-file=bedrock_team_tag_hook.py=docs/litellm/litellm_cost/bedrock_team_tag_hook.py \
  --dry-run=client -o yaml | kubectl apply -f -

# 更新后需重启 Pod
kubectl rollout restart deployment/litellm -n litellm
kubectl rollout status deployment/litellm -n litellm --timeout=3m
```

### 7.2 values.yaml 关键配置

```yaml
proxy_config:
  litellm_settings:
    callbacks:
      - custom_callbacks.proxy_handler_instance         # 参数清洗
      - bedrock_team_tag_hook.proxy_handler_instance    # Team Tag 注入（新增）

volumes:
  - name: bedrock-team-tag-hook
    configMap:
      name: litellm-bedrock-team-tag-hook
      defaultMode: 420

volumeMounts:
  - name: bedrock-team-tag-hook
    mountPath: /etc/litellm/bedrock_team_tag_hook.py
    subPath: bedrock_team_tag_hook.py
    readOnly: true

envVars:
  BEDROCK_API_KEY: placeholder  # LiteLLMEncoder 初始化需要，实际认证走 Pod Identity
```

### 7.3 Hook 核心逻辑说明

Hook（`bedrock_team_tag_hook.py`）在每次 `bedrock/` 调用前执行：

1. **读取 Team**：从 `user_api_key_dict.team_alias` 获取 Team Name（即 LiteLLM Team 的显示名）
2. **TTL Cache**：同一 Team 的凭证缓存 55 分钟，避免频繁调用 STS（STS 默认限制 500 次/秒）
3. **STS AssumeRole**：携带 `team=<team_alias>` Session Tag 获取临时凭证
4. **注入凭证**：直接设置 `data["aws_access_key_id/secret/session_token"]`（绕过 Issue #25884）
5. **无 Team 透传**：没有关联 Team 的请求直接透传，不影响正常功能

**依赖**：仅使用镜像内置的 `boto3` 和 Python 标准库，无需安装额外包。

### 7.4 在 LiteLLM 中创建 Team 和 API Key

```bash
# 创建 Team（team_alias = AWS Cost Explorer 中显示的 tag 值）
curl -X POST "http://localhost:4000/team/new" \
  -H "Authorization: Bearer sk-litellm-proxy-master-key" \
  -H "Content-Type: application/json" \
  -d '{"team_alias": "data-science", "max_budget": 100.0, "budget_duration": "monthly"}'

# 创建属于该 Team 的 API Key
curl -X POST "http://localhost:4000/key/generate" \
  -H "Authorization: Bearer sk-litellm-proxy-master-key" \
  -H "Content-Type: application/json" \
  -d '{"team_id": "<team_id>", "key_alias": "ds-key-1", "max_budget": 20.0}'
```

> **命名规范**：`team_alias` 建议只用 `[a-z0-9-]`，如 `data-science`、`platform-eng`。特殊字符被 Hook 自动替换为 `_`。

---

## 八、查看费用

### 8.1 AWS Cost Explorer（激活 48 小时后）

```
AWS Console → Cost Explorer
  → Service: Amazon Bedrock
  → Group by: Tag → iamPrincipal/team
  → Date range: 自选
```

### 8.2 已激活的 EKS 维度（现在就可用）

```
Cost Explorer → Group by: Tag → iamPrincipal/eks-cluster-name
Cost Explorer → Group by: Tag → iamPrincipal/kubernetes-namespace
```

这两个维度现在已经可以查看，可以确认 Bedrock 调用来自哪个集群/Namespace。

### 8.3 脚本查询

```bash
cd docs/litellm/litellm_cost

# LiteLLM 实时费用 + AWS Cost Explorer 对比报告
python3 scripts/litellm-team-spend.py

# 指定 Team 详细日志
python3 scripts/litellm-team-spend.py --team data-science

# 只查 AWS（最近 30 天）
python3 scripts/litellm-team-spend.py --aws-only --days 30

# Shell 脚本（含每日明细表格）
DAYS_BACK=7 ./scripts/check-bedrock-cost.sh
TEAM_FILTER=data-science ./scripts/check-bedrock-cost.sh
```

---

## 九、完整时间线

```
2026-05-09 T+0h
  ✅ IAM 角色 nxdev-litellm-bedrock-exec 创建完成
  ✅ nxdev-PodRole 新增 StsAssumeBedrockExec 策略
  ✅ LiteLLM 升级至 v1.83.14-stable.patch.3
  ✅ BedrockTeamTagHook 部署并验证（CloudTrail 已确认 Session Tag 写入）
  ✅ 6 个 EKS iamPrincipal/* Tags 激活
  ✅ 后台轮询脚本启动（等待 iamPrincipal/team 出现）

T+1~24h（预期）
  ⏳ iamPrincipal/team 出现在 list-cost-allocation-tags
  ⏳ activate-cost-tags.sh --poll 自动激活

T+24~72h（预期）
  🎯 Cost Explorer 显示 iamPrincipal/team 维度数据
  🎯 按 Team Name 查看 Bedrock 账单功能完全可用
```

---

## 十、限制与注意事项

| 限制 | 说明 | 应对 |
|------|------|------|
| **不可追溯** | 只对 Tag 激活后的费用有效 | 尽早激活，接受历史数据缺失 |
| **24-48h 延迟** | Cost Explorer 非实时 | 实时监控用 LiteLLM `/spend/teams` |
| **STS 速率限制** | 默认 500 AssumeRole/秒/账号 | TTL Cache 55min 按 Team 缓存凭证 |
| **无 Team 请求** | master key/无 Team Key 不注入 tag | 归入 EKS 维度，费用仍可追踪 |
| **Issue #25884** | `aws_role_name` YAML 配置被静默丢弃 | Hook 直接注入临时凭证绕过 |
| **bedrock_mantle/ 不支持** | 只适用于 `bedrock/` 前缀 API | 当前 LiteLLM 主要使用 bedrock/ |

---

## 十一、文件索引

```
docs/litellm/litellm_cost/
├── bedrock-cost-attribution.md     ← 本文档
├── bedrock_team_tag_hook.py        ← Hook 源码（同步部署在 Kubernetes ConfigMap）
├── litellm-upgrade-v1.83.14.md     ← v1.82.3 → v1.83.14 升级手册
└── scripts/
    ├── activate-cost-tags.sh       ← 激活 AWS Cost Allocation Tags（含自动轮询）
    ├── check-bedrock-cost.sh       ← Shell 版费用查询（LiteLLM + AWS Cost Explorer）
    └── litellm-team-spend.py       ← Python 版费用对比报告

相关文件（其他目录）：
values.yaml                         ← Helm values（含所有 volumes 挂载）
litellm-deployment.md               ← 完整部署手册（一键 helm 安装 + post-install 步骤）
docs/litellm/auto-model/
  ├── custom_callbacks.py           ← 参数清洗 Hook（已部署）
  └── semantic_router.json          ← 语义路由规则（已部署）
docs/litellm/sync/
  └── litellm-model-sync.md         ← Bedrock 模型自动同步 CronJob
```
