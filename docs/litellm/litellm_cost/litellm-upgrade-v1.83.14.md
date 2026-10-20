# LiteLLM 升级手册：v1.82.3 → v1.83.14-stable.patch.3

> **升级完成时间：** 2026-05-09
> **操作人：** ti
> **升级前版本：** `litellm-helm-1.82.3`，镜像 `ghcr.io/berriai/litellm-database:v1.83.3-stable.opus-4.7`
> **升级后版本：** `litellm-helm-1.83.14-stable.patch.3`，镜像 `ghcr.io/berriai/litellm-database:main-v1.83.14-stable.patch.3`
> **Chart 源：** `oci://ghcr.io/berriai/litellm-helm`

---

## 一、升级摘要

| 项目 | 升级前 | 升级后 |
|------|--------|--------|
| Helm Chart | `litellm-helm-1.82.3` | `litellm-helm-1.83.14-stable.patch.3` |
| 镜像 | `v1.83.3-stable.opus-4.7` | `main-v1.83.14-stable.patch.3` |
| Volumes 管理 | 手动 `kubectl patch` | Helm 原生 `volumes`/`volumeMounts` |
| Extra ConfigMaps | `litellm-custom-callbacks`（手动 Helm label） | 独立 CM，不被 Helm 管理 |
| 新增功能 | — | **Bedrock Team Cost Attribution（Session Tags）** |
| Helm Revision | 1 | 4 |
| Migration Job | 新建 | 运行（118 个迁移，无新迁移，幂等） |

---

## 二、变更清单

### 2.1 新增资源

| 资源 | 类型 | 说明 |
|------|------|------|
| `litellm-bedrock-team-tag-hook` | ConfigMap | `bedrock_team_tag_hook.py`，不被 Helm 管理 |
| `litellm-router-config` | ConfigMap | `semantic_router.json`，独立 CM，不被 Helm 管理 |
| `nxdev-litellm-bedrock-exec` | IAM Role | Bedrock 执行角色，信任 nxdev-PodRole |
| `StsAssumeBedrockExec` | IAM Inline Policy | nxdev-PodRole 新增，允许 AssumeRole → exec 角色 |

### 2.2 修改的资源

| 资源 | 变更内容 |
|------|---------|
| `values.yaml` | 新增 `volumes`/`volumeMounts`（原生替代 kubectl patch）；新增 `autoscaling`；补全 `topologySpreadConstraints`；新增 `BEDROCK_API_KEY=placeholder` |
| `proxy_config.litellm_settings.callbacks` | 新增 `bedrock_team_tag_hook.proxy_handler_instance` |
| `proxy_config.general_settings` | 恢复 `database_connection_pool_limit: 24`、`proxy_batch_write_at: 30`、`max_parallel_requests: 100`、`global_max_parallel_requests: 500` |

### 2.3 架构变化：volumes 管理方式

**之前（手动 kubectl patch，Helm upgrade 后丢失）：**
```
volumes: [litellm-config]          # Helm 原生
  → kubectl patch 追加: [custom-callbacks, litellm-router-config]
```

**之后（Helm 原生管理，upgrade 稳定）：**
```
volumes: [litellm-config, custom-callbacks, litellm-router-config, bedrock-team-tag-hook]
         ↑ 全部通过 values.yaml volumes[] 原生声明，helm upgrade 不会丢失
```

---

## 三、完整升级步骤（适用于新环境复现）

### 前置条件

```bash
# 1. Helm 已添加 OCI 支持（helm v3.8+）
helm version --short | grep -E 'v3\.[8-9]|v3\.[1-9][0-9]'

# 2. kubectl context 已指向目标集群
kubectl get nodes --no-headers | head -3

# 3. litellm namespace 存在
kubectl get namespace litellm

# 4. 必要 Secrets 存在
kubectl get secret postgres-creds litellm-masterkey -n litellm

# 5. litellm-sa ServiceAccount 存在（已绑定 EKS Pod Identity）
kubectl get serviceaccount litellm-sa -n litellm
```

### Step 1：备份

```bash
mkdir -p /tmp/litellm-upgrade-backup

helm get values litellm -n litellm > /tmp/litellm-upgrade-backup/helm-values-before.yaml
kubectl get configmap litellm-config -n litellm -o yaml > /tmp/litellm-upgrade-backup/cm-litellm-config.yaml
kubectl get configmap litellm-custom-callbacks -n litellm -o yaml > /tmp/litellm-upgrade-backup/cm-custom-callbacks.yaml
kubectl get deployment litellm -n litellm -o yaml > /tmp/litellm-upgrade-backup/deployment-before.yaml
kubectl get hpa -n litellm -o yaml > /tmp/litellm-upgrade-backup/hpa-before.yaml

# 提取文件内容到本地
kubectl get configmap litellm-config -n litellm -o jsonpath='{.data.config\.yaml}' > /tmp/litellm-upgrade-backup/config.yaml
kubectl get configmap litellm-config -n litellm -o jsonpath='{.data.semantic_router\.json}' > /tmp/litellm-upgrade-backup/semantic_router.json
kubectl get configmap litellm-custom-callbacks -n litellm -o jsonpath='{.data.custom_callbacks\.py}' > /tmp/litellm-upgrade-backup/custom_callbacks.py
```

### Step 2：创建 AWS IAM 资源

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
      "Sid": "BedrockInvoke",
      "Effect": "Allow",
      "Action": ["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream",
                 "bedrock:ListFoundationModels","bedrock:GetFoundationModel",
                 "bedrock:ListInferenceProfiles","bedrock:GetInferenceProfile"],
      "Resource": "*"
    }]
  }'

# 允许 nxdev-PodRole AssumeRole → Bedrock Exec 角色
aws iam put-role-policy \
  --role-name nxdev-PodRole \
  --policy-name StsAssumeBedrockExec \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Sid": "AssumeBedrockExecRole",
      "Effect": "Allow",
      "Action": ["sts:AssumeRole", "sts:TagSession"],
      "Resource": "arn:aws:iam::867344450900:role/nxdev-litellm-bedrock-exec"
    }]
  }'
```

### Step 3：创建独立 ConfigMaps（不被 Helm 管理）

```bash
# semantic_router.json（独立 ConfigMap，不被 helm upgrade 覆盖）
kubectl create configmap litellm-router-config -n litellm \
  --from-file=semantic_router.json=docs/litellm/auto-model/semantic_router.json \
  --dry-run=client -o yaml | kubectl apply -f -

# bedrock_team_tag_hook.py（新增：Team 成本归因）
kubectl create configmap litellm-bedrock-team-tag-hook -n litellm \
  --from-file=bedrock_team_tag_hook.py=docs/litellm/bedrock_team_tag_hook.py \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Step 4：dry-run 验证

```bash
helm upgrade litellm oci://ghcr.io/berriai/litellm-helm \
  --version 1.83.14-stable.patch.3 \
  --namespace litellm \
  --values values.yaml \
  --dry-run 2>&1 | grep -E "image:|callbacks:|volumes|volumeMount|Error" | head -30
```

### Step 5：执行升级

```bash
helm upgrade litellm oci://ghcr.io/berriai/litellm-helm \
  --version 1.83.14-stable.patch.3 \
  --namespace litellm \
  --values values.yaml
```

> ⚠️ **不使用 `--wait`**：Migration Job 和 Startup Probe（初始延迟 30s）导致 `--wait` 10min 超时。
> Deployment 本身会成功，通过下一步手动 rollout status 确认。

### Step 6：验证

```bash
# 等待 Deployment 就绪
kubectl rollout status deployment/litellm -n litellm --timeout=3m

# 查看 Pod 版本
kubectl get pod -n litellm -o jsonpath='{.items[0].spec.containers[0].image}'

# 健康检查
kubectl exec -n litellm deploy/litellm -- \
  python3 -c "import urllib.request; r=urllib.request.urlopen('http://localhost:4000/health/liveliness'); print(r.status, r.read().decode()[:50])"

# 验证挂载文件
kubectl exec -n litellm deploy/litellm -- ls -la /etc/litellm/

# 验证 /v1/models
kubectl exec -n litellm deploy/litellm -- python3 -c "
import urllib.request, json
req = urllib.request.Request('http://[::1]:4000/v1/models',
    headers={'Authorization': 'Bearer sk-litellm-proxy-master-key'})
d = json.loads(urllib.request.urlopen(req).read())
need = ['auto','claude-opus-4-7','claude-sonnet-4-6','claude-haiku-4-5-20251001','qwen3-coder-480b']
names = [m['id'] for m in d['data']]
[print(n, 'OK' if n in names else 'MISSING') for n in need]
"

# 验证 STS AssumeRole
kubectl exec -n litellm deploy/litellm -- python3 -c "
import boto3
sts = boto3.client('sts', region_name='us-west-2')
resp = sts.assume_role(
    RoleArn='arn:aws:iam::867344450900:role/nxdev-litellm-bedrock-exec',
    RoleSessionName='litellm-verify',
    DurationSeconds=900,
    Tags=[{'Key': 'team', 'Value': 'verify-test'}]
)
print('STS OK, KeyId:', resp['Credentials']['AccessKeyId'][:8], '...')
"
```

### Step 7：AWS Cost Allocation Tag 激活（一次性）

```bash
# 在 AWS Billing Console 手动操作（没有 CLI 命令）:
# 1. 进入 https://console.aws.amazon.com/billing/home#/tags
# 2. 筛选 Type = "IAM Principal"
# 3. 找到 Key = "team" → 勾选 → Activate
# 4. 激活后 24-48 小时 Cost Explorer 才显示数据

# 5. 新建 CUR 2.0 Data Export（勾选 IAM Principal）:
# → Billing Console → Data Exports → Create
# → 勾选: "Include caller identity (IAM principal) allocation data"
```

---

## 四、回滚方案

### 快速回滚（Helm 版本）

```bash
# 查看 Helm 历史
helm history litellm -n litellm

# 回滚到上一版本
helm rollback litellm -n litellm

# 等待回滚完成
kubectl rollout status deployment/litellm -n litellm --timeout=3m
```

### 完整回滚（含配置还原）

```bash
# 1. 还原 ConfigMap
kubectl apply -f /tmp/litellm-upgrade-backup/cm-litellm-config.yaml
kubectl apply -f /tmp/litellm-upgrade-backup/cm-custom-callbacks.yaml

# 2. 还原 Deployment（可选，通常 helm rollback 足够）
kubectl apply -f /tmp/litellm-upgrade-backup/deployment-before.yaml

# 3. Helm 回滚
helm rollback litellm -n litellm

# 4. 验证
kubectl rollout status deployment/litellm -n litellm --timeout=3m
```

---

## 五、升级后注意事项

### 5.1 新版本 v1.83.10 重大变更

客户端通过 Header 或 Request Body 传入的标签**默认被剥离**。如需保留客户端标签：

```yaml
# values.yaml proxy_config.general_settings 中添加
proxy_config:
  general_settings:
    allow_client_tags: true  # 默认 false（v1.83.10 新增）
```

### 5.2 双 HPA 问题

升级后存在两个 HPA（旧的 `litellm-hpa` 和新 Chart 创建的 `litellm`）：

```bash
kubectl get hpa -n litellm
# NAME          REFERENCE            TARGETS              MINPODS   MAXPODS
# litellm       Deployment/litellm   cpu: <unknown>/70%   1         500     ← 新（Chart 管理）
# litellm-hpa   Deployment/litellm   cpu: <unknown>/70%   1         500     ← 旧（遗留）
```

两个 HPA 目标相同（CPU 70%，1-500），无冲突，但建议删除旧的：

```bash
kubectl delete hpa litellm-hpa -n litellm
```

### 5.3 Bedrock Cache 定价修正（v1.84.0-rc.1 预计修复）

v1.83.14 中，Claude 4.5/4.6/4.7 的 1 小时 TTL Prompt Cache 写入成本存在约 60% 欠计问题（v1.84.0-rc.1 修复）。当前 LiteLLM 内部 Spend Tracking 的 cache 相关费用**偏低**，以 AWS 官方账单为准。

---

## 六、升级过程中遇到的问题及解决方案

### 问题 1：`cachetools` ModuleNotFoundError — Pod CrashLoopBackOff

**现象：** `bedrock_team_tag_hook.py` 第一版使用了 `from cachetools import TTLCache`，新 Pod 启动即崩溃：

```
ImportError: Could not import proxy_handler_instance from bedrock_team_tag_hook
ModuleNotFoundError: No module named 'cachetools'
```

**原因：** `ghcr.io/berriai/litellm-database:main-v1.83.14-stable.patch.3`（Python 3.13）镜像没有预装 `cachetools`。

**解决方案：** 改用纯 Python 标准库（`time` + `threading`）实现线程安全 TTL Cache，无任何第三方依赖：

```python
# 标准库实现，替代 cachetools.TTLCache
_cache_lock = threading.Lock()
_cred_store: dict = {}

def _cache_get(key):
    with _cache_lock:
        entry = _cred_store.get(key)
        if entry and time.monotonic() < entry["expires_at"]:
            return entry["creds"]
        if entry:
            del _cred_store[key]
        return None
```

**经验：** 在 LiteLLM 容器中编写自定义 Hook 时，只使用以下可信包：
- Python 标准库（`re`, `time`, `threading`, `json`, `logging` 等）
- `boto3` / `botocore`（内置）
- `redis`（内置）
- `litellm` 本身的模块

### 问题 2：`helm upgrade --wait` 超时（status: failed）

**现象：** Helm 显示 `UPGRADE FAILED: context deadline exceeded`，但 Deployment 实际已正常运行。

**原因：** Migration Job（Prisma schema 检查，约 35s）+ Startup Probe `initialDelaySeconds: 30` + Probe 周期，导致总等待时间超过 Helm 的默认超时。

**解决方案：** 去掉 `--wait` 参数，upgrade 完成后手动执行：

```bash
kubectl rollout status deployment/litellm -n litellm --timeout=3m
```

Helm release status 会短暂显示 `failed`，再执行一次不带 `--wait` 的 upgrade 即变为 `deployed`。

### 问题 3：双 HPA 共存

**现象：** 升级后 namespace 中出现两个 HPA：

```
NAME          REFERENCE       MINPODS  MAXPODS
litellm       Deployment/litellm  1   500   ← 新 Chart 创建
litellm-hpa   Deployment/litellm  1   500   ← 旧版遗留
```

**原因：** v1.82.3 Chart 通过独立 YAML 创建了 `litellm-hpa`，v1.83.14 Chart 通过 `autoscaling:` values 创建了 `litellm`，两者配置相同，无冲突，但冗余。

**解决方案：** 删除旧的遗留 HPA：

```bash
kubectl delete hpa litellm-hpa -n litellm
```

---

## 七、已知限制

| 问题 | 状态 | 缓解措施 |
|------|------|---------|
| Issue #25884: `aws_role_name` YAML 静默丢弃 | 未修复 | Hook 直接注入临时凭证绕过 |
| Bedrock Cache 定价 60% 欠计 | v1.84.0-rc.1 修复 | 当前以 AWS Cost Explorer 账单为准 |
| v1.83.10 客户端标签默认剥离 | 已知变更 | 如需保留客户端标签：`allow_client_tags: true` |
