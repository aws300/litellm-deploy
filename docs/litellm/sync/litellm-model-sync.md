# LiteLLM Bedrock 模型自动同步

每小时自动检测 AWS Bedrock 新发布的模型（global inference profiles），与 LiteLLM ConfigMap 对比，发现新模型后自动追加并触发滚动重启。

---

## 前提条件

1. `litellm` namespace 已存在
2. 节点 IAM Role 需包含以下权限（CloudNativeFormation 默认已包含）：
   - `bedrock:ListInferenceProfiles`
   - `bedrock:ListFoundationModels`
3. 如需独立 IRSA，参考文末说明

---

## 部署前：确认现有配置不受影响

**部署前必须先执行以下检查**，确保现有 LiteLLM 配置完整，防止 RBAC 冲突或脚本覆盖非预期内容。

```bash
# 1. 确认 litellm namespace 和 ConfigMap 存在
kubectl get namespace litellm
kubectl get configmap litellm-config -n litellm

# 2. 查看当前 model_list（备份，便于回滚对比）
kubectl get configmap litellm-config -n litellm \
  -o jsonpath='{.data.config\.yaml}' | grep -A 3 "model_list:"

# 3. 检查是否已存在同名 RBAC 资源（避免冲突）
kubectl get serviceaccount litellm-model-sync -n litellm 2>/dev/null && \
  echo "⚠️  ServiceAccount 已存在，apply 会更新" || echo "✅ 不存在，将新建"
kubectl get role litellm-model-sync -n litellm 2>/dev/null && \
  echo "⚠️  Role 已存在，apply 会更新" || echo "✅ 不存在，将新建"
kubectl get cronjob litellm-model-sync -n litellm 2>/dev/null && \
  echo "⚠️  CronJob 已存在，apply 会更新" || echo "✅ 不存在，将新建"

# 4. 备份当前完整 ConfigMap（可选但推荐）
kubectl get configmap litellm-config -n litellm -o yaml \
  > litellm-config-backup-$(date +%Y%m%d-%H%M%S).yaml
echo "备份完成"
```

**脚本安全性说明：**
- 脚本只会**追加**新模型到 `model_list`，不会删除或修改已有条目
- 若无新模型，ConfigMap 和 Deployment **不会有任何变动**（不触发重启）
- 新模型插入在 `bedrock/*` 通配符之前，不影响通配符兜底逻辑
- Role 权限最小化：只能操作 `litellm-config` 这一个 ConfigMap 和 `litellm` 这一个 Deployment

---

## 一键部署

将以下所有 YAML 复制到一个文件后执行，或直接 `kubectl apply`：

```bash
kubectl apply -f litellm-model-sync.md   # 如果你的 kubectl 支持 --filename 从 stdin
# 或者复制下方 YAML 块到 /tmp/sync.yaml 后执行：
kubectl apply -f /tmp/sync.yaml
```

---

## 完整 YAML

```yaml
---
# 1. ServiceAccount
apiVersion: v1
kind: ServiceAccount
metadata:
  name: litellm-model-sync
  namespace: litellm
---
# 2. Role — 最小权限：只能操作指定的 ConfigMap 和 Deployment
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: litellm-model-sync
  namespace: litellm
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    resourceNames: ["litellm-config"]
    verbs: ["get", "patch"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    resourceNames: ["litellm"]
    verbs: ["get", "patch"]
---
# 3. RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: litellm-model-sync
  namespace: litellm
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: litellm-model-sync
subjects:
  - kind: ServiceAccount
    name: litellm-model-sync
    namespace: litellm
---
# 4. 同步脚本（存储为 ConfigMap，挂载到 CronJob Pod）
apiVersion: v1
kind: ConfigMap
metadata:
  name: litellm-model-sync-script
  namespace: litellm
data:
  sync.py: |
    #!/usr/bin/env python3
    """
    自动检测 AWS Bedrock 新发布的模型并同步到 LiteLLM ConfigMap。
    仅追加新模型，不删除已有配置，不影响 bedrock/* 通配符和其他模型。
    """
    import boto3, json, os, re, subprocess, sys, yaml

    REGION     = os.environ.get("AWS_REGION", "us-west-2")
    NAMESPACE  = os.environ.get("LITELLM_NAMESPACE", "litellm")
    CONFIGMAP  = os.environ.get("LITELLM_CONFIGMAP", "litellm-config")
    DEPLOYMENT = os.environ.get("LITELLM_DEPLOYMENT", "litellm")
    DRY_RUN    = os.environ.get("DRY_RUN", "false").lower() == "true"

    # 仅同步以下前缀的 global inference profile，可按需扩展
    SYNC_PREFIXES = [
        "global.anthropic.claude",
        "global.moonshotai",
    ]

    # model ID → 友好名称推断规则（正则替换）
    NAME_RULES = [
        (r"global\.anthropic\.(claude-[\w\.\-]+)", r"\1"),   # claude-opus-4-7
        (r"global\.moonshotai\.([\w\.\-]+)",        r"\1"),  # kimi-k2.5
    ]

    def log(msg):
        print(msg, flush=True)

    def get_bedrock_active_profiles():
        client = boto3.client("bedrock", region_name=REGION)
        profiles, kwargs = [], {}
        while True:
            resp = client.list_inference_profiles(**kwargs)
            for p in resp.get("inferenceProfileSummaries", []):
                pid = p["inferenceProfileId"]
                if p.get("status") == "ACTIVE" and any(
                    pid.startswith(px) for px in SYNC_PREFIXES
                ):
                    profiles.append(pid)
            token = resp.get("nextToken")
            if not token:
                break
            kwargs["nextToken"] = token
        return sorted(profiles)

    def infer_model_name(profile_id):
        for pattern, template in NAME_RULES:
            if re.match(pattern, profile_id):
                return re.sub(pattern, template, profile_id)
        return None

    def get_current_config():
        result = subprocess.run(
            ["kubectl", "get", "configmap", CONFIGMAP,
             "-n", NAMESPACE, "-o", "jsonpath={.data.config\\.yaml}"],
            capture_output=True, text=True, check=True
        )
        return yaml.safe_load(result.stdout)

    def patch_configmap(new_yaml_str):
        patch = json.dumps({"data": {"config.yaml": new_yaml_str}})
        cmd = ["kubectl", "patch", "configmap", CONFIGMAP,
               "-n", NAMESPACE, "--type=merge", "-p", patch]
        if DRY_RUN:
            log(f"[DRY_RUN] 跳过 patch"); return
        subprocess.run(cmd, check=True)

    def rollout_restart():
        cmd = ["kubectl", "rollout", "restart",
               f"deployment/{DEPLOYMENT}", "-n", NAMESPACE]
        if DRY_RUN:
            log(f"[DRY_RUN] 跳过重启"); return
        subprocess.run(cmd, check=True)

    def main():
        log("=" * 50)
        log("LiteLLM Bedrock 模型自动同步")
        log(f"Region={REGION}  NS={NAMESPACE}  DryRun={DRY_RUN}")
        log("=" * 50)

        # 步骤 1: 读取现有 ConfigMap，打印当前模型列表（不做任何修改）
        try:
            config = get_current_config()
        except Exception as e:
            log(f"[ERROR] 读取 ConfigMap 失败: {e}"); sys.exit(1)

        model_list = config.get("model_list", [])
        log(f"当前 ConfigMap 已有模型数: {len(model_list)}")
        for entry in model_list:
            log(f"  - {entry.get('model_name')}  "
                f"({entry.get('litellm_params', {}).get('model', '')})")

        # 步骤 2: 查询 Bedrock 当前 ACTIVE global inference profiles
        try:
            bedrock_profiles = get_bedrock_active_profiles()
        except Exception as e:
            log(f"[ERROR] 查询 Bedrock 失败: {e}"); sys.exit(1)
        log(f"\nBedrock ACTIVE profiles: {len(bedrock_profiles)}")

        # （model_list 已在步骤 1 中读取，此处直接使用）
        existing_ids   = {e.get("litellm_params", {}).get("model", "")
                          .replace("bedrock/", "")
                          for e in model_list}
        existing_names = {e.get("model_name", "") for e in model_list}

        new_entries = []
        for pid in bedrock_profiles:
            if pid in existing_ids:
                log(f"  [已存在] {pid}"); continue
            name = infer_model_name(pid)
            if not name:
                log(f"  [跳过] 无法推断名称: {pid}"); continue
            if name in existing_names:
                log(f"  [别名冲突] {name} 已使用，跳过 {pid}"); continue
            log(f"  [新模型] {pid}  →  {name}")
            new_entries.append({
                "model_name": name,
                "litellm_params": {"model": f"bedrock/{pid}"},
            })

        if not new_entries:
            log("\n无新模型，退出。"); return 0

        # 在 bedrock/* 通配符之前插入，保持通配符在末尾
        idx = next((i for i, e in enumerate(model_list)
                    if e.get("model_name") == "bedrock/*"), len(model_list))
        for entry in new_entries:
            model_list.insert(idx, entry); idx += 1

        config["model_list"] = model_list
        new_yaml = yaml.dump(config, default_flow_style=False,
                             allow_unicode=True, sort_keys=False)

        log(f"\n追加 {len(new_entries)} 个新模型，更新 ConfigMap...")
        try:
            patch_configmap(new_yaml)
        except Exception as e:
            log(f"[ERROR] patch 失败: {e}"); sys.exit(1)

        log("触发 LiteLLM 滚动重启...")
        try:
            rollout_restart()
        except Exception as e:
            log(f"[ERROR] restart 失败: {e}"); sys.exit(1)

        log("\n同步完成，新增：")
        for e in new_entries:
            log(f"  + {e['model_name']}  ({e['litellm_params']['model']})")
        return 0

    if __name__ == "__main__":
        sys.exit(main())
---
# 5. CronJob — 每小时整点执行
apiVersion: batch/v1
kind: CronJob
metadata:
  name: litellm-model-sync
  namespace: litellm
  labels:
    app.kubernetes.io/name: litellm-model-sync
    app.kubernetes.io/component: automation
spec:
  schedule: "0 * * * *"           # 每小时整点
  concurrencyPolicy: Forbid        # 禁止并发，避免重复 patch
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        metadata:
          labels:
            app.kubernetes.io/name: litellm-model-sync
        spec:
          serviceAccountName: litellm-model-sync
          restartPolicy: OnFailure
          containers:
            - name: sync
              image: python:3.12-slim
              command: ["/bin/sh", "-c"]
              args:
                - |
                  set -e
                  pip install boto3 pyyaml --quiet --no-cache-dir

                  # 自动检测 CPU 架构（arm64 / amd64）
                  ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
                  KUBE_VERSION=$(curl -sSL https://dl.k8s.io/release/stable.txt)
                  curl -sSLo /usr/local/bin/kubectl \
                    "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${ARCH}/kubectl"
                  chmod +x /usr/local/bin/kubectl

                  python3 /scripts/sync.py
              env:
                - name: AWS_REGION
                  value: "us-west-2"           # 按需修改
                - name: LITELLM_NAMESPACE
                  value: "litellm"
                - name: LITELLM_CONFIGMAP
                  value: "litellm-config"
                - name: LITELLM_DEPLOYMENT
                  value: "litellm"
                - name: DRY_RUN
                  value: "false"               # 改为 "true" 仅打印不修改
              volumeMounts:
                - name: sync-script
                  mountPath: /scripts
                  readOnly: true
              resources:
                requests:
                  cpu: 100m
                  memory: 128Mi
                limits:
                  cpu: 500m
                  memory: 256Mi
          volumes:
            - name: sync-script
              configMap:
                name: litellm-model-sync-script
                defaultMode: 0755
```

---

## 常用操作

```bash
# 部署
kubectl apply -f litellm-model-sync.md   # 或拷贝 YAML 到文件后 apply

# 立即手动触发一次（不等下一个整点）
kubectl create job litellm-model-sync-manual \
  --from=cronjob/litellm-model-sync -n litellm

# 查看执行日志
kubectl logs -n litellm \
  $(kubectl get pods -n litellm -l app.kubernetes.io/name=litellm-model-sync \
    --sort-by=.metadata.creationTimestamp -o name | tail -1) -f

# 查看历史 Job
kubectl get jobs -n litellm

# 查看 CronJob 状态
kubectl get cronjob litellm-model-sync -n litellm

# 暂停自动同步
kubectl patch cronjob litellm-model-sync -n litellm \
  -p '{"spec":{"suspend":true}}'

# 恢复自动同步
kubectl patch cronjob litellm-model-sync -n litellm \
  -p '{"spec":{"suspend":false}}'

# 删除所有资源
kubectl delete cronjob,configmap,rolebinding,role,serviceaccount \
  -l app.kubernetes.io/name=litellm-model-sync -n litellm
```

---

## 自定义配置

### 修改同步的模型系列

编辑脚本中的 `SYNC_PREFIXES` 列表：

```python
SYNC_PREFIXES = [
    "global.anthropic.claude",   # Claude 全系列
    "global.moonshotai",         # Kimi 系列
    # "global.meta.llama",       # Llama 系列（按需添加）
    # "global.mistral",          # Mistral 系列
]
```

### 修改名称推断规则

编辑 `NAME_RULES`，格式为 `(正则模式, 替换模板)`：

```python
NAME_RULES = [
    (r"global\.anthropic\.(claude-[\w\.\-]+)", r"\1"),  # claude-opus-4-7
    (r"global\.moonshotai\.([\w\.\-]+)",        r"\1"),  # kimi-k2.5
]
```

### 修改执行频率

修改 CronJob 的 `schedule` 字段：

```yaml
schedule: "0 * * * *"    # 每小时整点（默认）
schedule: "*/30 * * * *" # 每 30 分钟
schedule: "0 2 * * *"    # 每天 02:00 UTC
```

### 部署到不同 namespace

```bash
# 修改所有 namespace: litellm 为目标 namespace
sed 's/namespace: litellm/namespace: your-ns/g' \
  litellm-model-sync.md | kubectl apply -f -
```

---

## 独立 IRSA 配置（可选）

节点 IAM Role 已有 Bedrock 权限时无需此步骤。若需给 CronJob 绑定独立角色：

**1. 创建 IAM Policy**

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "bedrock:ListInferenceProfiles",
      "bedrock:ListFoundationModels"
    ],
    "Resource": "*"
  }]
}
```

**2. 绑定到 ServiceAccount**

```bash
# EKS Pod Identity 方式（推荐）
aws eks create-pod-identity-association \
  --cluster-name <cluster-name> \
  --namespace litellm \
  --service-account litellm-model-sync \
  --role-arn arn:aws:iam::<ACCOUNT_ID>:role/litellm-model-sync-role

# 或传统 IRSA 方式
kubectl annotate serviceaccount litellm-model-sync -n litellm \
  eks.amazonaws.com/role-arn=arn:aws:iam::<ACCOUNT_ID>:role/litellm-model-sync-role
```
