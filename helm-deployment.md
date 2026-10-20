# LiteLLM Helm 部署手册

> **环境**：EKS（us-west-2），Namespace `litellm`，Helm Chart `litellm-helm-1.82.3`，当前运行版本 `v1.82.3`。
>
> **最后核对**：2026-05-09，与集群实际状态（`kubectl` + `helm get values/manifest`）完全一致。

---

## 一、架构概览

```
                    CloudFront
                       │ HTTPS
                       ▼
          ┌────────────────────────────┐
          │  Service: litellm (ClusterIP :4000, IPv6)  │
          └──────────────┬─────────────┘
                         │
          ┌──────────────▼─────────────┐
          │    Deployment: litellm      │
          │    image: ghcr.io/berriai/  │
          │    litellm-database:main-   │
          │    v1.82.3                  │
          │    nodeSelector: arm64      │
          │    HPA: 2–20 (CPU 70%)      │
          └──────────────┬─────────────┘
                         │
         ┌───────────────┼───────────────┐
         ▼               ▼               ▼
   RDS PostgreSQL   ElastiCache       AWS Bedrock
   (litellm DB)    Valkey (SSL)      (IRSA via litellm-sa)
```

**Volumes 挂载（3 个 ConfigMap，分 3 个 volume entry）：**

| Volume name          | ConfigMap key        | 挂载路径                           |
|----------------------|----------------------|------------------------------------|
| `litellm-config`     | `config.yaml`        | `/etc/litellm/config.yaml`         |
| `litellm-router-config` | `semantic_router.json` | `/etc/litellm/semantic_router.json` |
| `custom-callbacks`   | `custom_callbacks.py`| `/etc/litellm/custom_callbacks.py` |

---

## 二、前置条件

```bash
# 1. 确认 namespace 存在
kubectl get namespace litellm

# 2. 确认 ServiceAccount（IRSA/Pod Identity 需提前创建）
kubectl get serviceaccount litellm-sa -n litellm

# 3. 确认 postgres-creds secret 存在
kubectl get secret postgres-creds -n litellm

# 4. 添加 Helm repo
helm repo add litellm https://berriai.github.io/litellm-helm
helm repo update

# 5. 查看可用版本
helm search repo litellm/litellm-helm --versions | head -5
```

---

## 三、Helm values.yaml

> 这份 values.yaml 与集群当前 `helm get values litellm -n litellm` 完全一致（`proxy_config` 已更新为集群实际 ConfigMap 内容）。

```yaml
# values.yaml — litellm-helm-1.82.3

args:
  - --config
  - /etc/litellm/config.yaml
  - --host
  - '::'

# ── 数据库 ──────────────────────────────────────────────────────
db:
  database: litellm
  deployStandalone: false
  endpoint: nxdev-pg.cluster-cfgoawqmcki9.us-west-2.rds.amazonaws.com
  secret:
    name: postgres-creds
    passwordKey: password
    usernameKey: username
  url: postgresql://$(DATABASE_USERNAME):$(DATABASE_PASSWORD)@$(DATABASE_HOST):5432/$(DATABASE_NAME)
  useExisting: true

# ── 环境变量 ────────────────────────────────────────────────────
envVars:
  # SSO (AWS Cognito)
  AUTO_REDIRECT_UI_LOGIN_TO_SSO: true
  GENERIC_AUTHORIZATION_ENDPOINT: https://cnf-dev-867344450900.auth.us-west-2.amazoncognito.com/oauth2/authorize
  GENERIC_CLIENT_ID: 3okkkpoeplqvc65fd2nmrng88t
  GENERIC_CLIENT_SECRET: 1o3naif8jv94emj2r3htmvp3e9qvscroj6uaqacnfk9035v6vav2
  GENERIC_CLIENT_STATE: litellm-sso
  GENERIC_ROLE_MAPPINGS_GROUP_CLAIM: groups
  GENERIC_ROLE_MAPPINGS_ROLES: "{'proxy_admin': ['admin']}"
  GENERIC_TOKEN_ENDPOINT: https://cnf-dev-867344450900.auth.us-west-2.amazoncognito.com/oauth2/token
  GENERIC_USERINFO_ENDPOINT: https://cnf-dev-867344450900.auth.us-west-2.amazoncognito.com/oauth2/userInfo
  # 日志
  LITELLM_LOG: ERROR
  LITELLM_MODE: PRODUCTION
  # 端点
  PROXY_BASE_URL: https://d3sdxccbfn7y3d.cloudfront.net
  PROXY_LOGOUT_URL: "https://cnf-dev-867344450900.auth.us-west-2.amazoncognito.com/logout?client_id=3okkkpoeplqvc65fd2nmrng88t&logout_uri=https://d3sdxccbfn7y3d.cloudfront.net/ui/"
  # Redis / Valkey
  REDIS_HOST: nxdev-valkey-5mrhn9.serverless.usw2.cache.amazonaws.com
  REDIS_PASSWORD: nxdevValkey2026!
  REDIS_PORT: 6379
  REDIS_SSL: true
  SERVER_ROOT_PATH: ""
  # semantic-router LiteLLMEncoder 初始化依赖此变量（实际认证走 Pod Identity）
  BEDROCK_API_KEY: placeholder

# ── Ingress ─────────────────────────────────────────────────────
ingress:
  enabled: false

# ── 健康探针 ────────────────────────────────────────────────────
livenessProbe:
  path: /health/liveliness
readinessProbe:
  path: /health/readiness
startupProbe:
  failureThreshold: 60
  initialDelaySeconds: 30
  path: /health/readiness
  periodSeconds: 10

# ── 主密钥 ──────────────────────────────────────────────────────
masterkey: sk-litellm-proxy-master-key

# ── 迁移 Job（ArgoCD PreSync hook）──────────────────────────────
migrationJob:
  enabled: true

# ── 节点选择 ────────────────────────────────────────────────────
nodeSelector:
  kubernetes.io/arch: arm64

# ── LiteLLM proxy 主配置（config.yaml）─────────────────────────
proxy_config:
  general_settings:
    allow_requests_on_db_unavailable: true
    database_connection_pool_limit: 24
    disable_error_logs: true
    forward_client_headers_to_llm_api: false
    master_key: os.environ/PROXY_MASTER_KEY
    maximum_spend_logs_retention_period: 7d
    proxy_batch_write_at: 30
    store_prompts_in_spend_logs: true
    max_parallel_requests: 100
    global_max_parallel_requests: 500

  litellm_settings:
    cache: true
    cache_params:
      host: nxdev-valkey-5mrhn9.serverless.usw2.cache.amazonaws.com
      password: nxdevValkey2026!
      port: 6379
      ssl: true
      ttl: 600
      type: redis
    drop_params: true
    json_logs: true
    request_timeout: 600
    set_verbose: false
    callbacks:
      - custom_callbacks.proxy_handler_instance

  model_list:
    # ───── Frontier Anthropic（复杂推理 / 架构 tier）─────
    - model_name: claude-opus-4-7
      litellm_params:
        model: bedrock/global.anthropic.claude-opus-4-7
    - model_name: claude-opus-4-6
      litellm_params:
        model: bedrock/global.anthropic.claude-opus-4-6-v1
    - model_name: claude-sonnet-4-6
      litellm_params:
        model: bedrock/global.anthropic.claude-sonnet-4-6
    - model_name: claude-sonnet-4-5-20250929
      litellm_params:
        model: bedrock/global.anthropic.claude-sonnet-4-5-20250929-v1:0
    - model_name: claude-opus-4-5-20251101
      litellm_params:
        model: bedrock/global.anthropic.claude-opus-4-5-20251101-v1:0
    - model_name: claude-haiku-4-5-20251001
      litellm_params:
        model: bedrock/global.anthropic.claude-haiku-4-5-20251001-v1:0

    # ───── 低价代码生成 tier（开源，us-west-2 ON_DEMAND）─────
    - model_name: qwen3-coder-480b
      litellm_params:
        model: bedrock/qwen.qwen3-coder-480b-a35b-v1:0
        aws_region_name: us-west-2

    # ───── 开源替代模型 picker 别名 ─────
    - model_name: kimi-k2.5
      litellm_params:
        model: bedrock/moonshotai.kimi-k2.5
        aws_region_name: us-west-2
    - model_name: zai.glm-5
      litellm_params:
        model: bedrock/zai.glm-5
        aws_region_name: us-west-2
    - model_name: deepseek-v3.2
      litellm_params:
        model: bedrock/deepseek.v3.2
        aws_region_name: us-west-2

    # ───── Embedding（给 auto router 用）─────
    - model_name: bedrock-embed-v4
      litellm_params:
        model: bedrock/global.cohere.embed-v4:0

    # ───── Auto Router 语义路由入口 ─────
    - model_name: auto
      litellm_params:
        model: auto_router/coding_auto_v1
        auto_router_config_path: /etc/litellm/semantic_router.json
        auto_router_default_model: claude-haiku-4-5-20251001
        auto_router_embedding_model: bedrock-embed-v4

    # ───── 通配符兜底（透传 bedrock/ 直调）─────
    - model_name: bedrock/*
      litellm_params:
        model: bedrock/*
        aws_region_name: us-west-2

  router_settings:
    redis_host: nxdev-valkey-5mrhn9.serverless.usw2.cache.amazonaws.com
    redis_password: nxdevValkey2026!
    redis_port: 6379
    routing_strategy: simple-shuffle

# ── Redis（使用外部 Valkey，不部署内置 Redis）──────────────────
redis:
  enabled: false

# ── 资源限制 ────────────────────────────────────────────────────
# CPU request 从 500m 提到 1000m（1 vCPU），给 HPA 一个有意义的 70% 基线。
# Memory: LiteLLM 每 worker 稳态 ~3.7Gi，num_workers=4 时接近 4Gi；
# limit 到 5Gi 给突发留 headroom，避免 OOMKill。
resources:
  limits:
    cpu: 2000m
    memory: 5Gi
  requests:
    cpu: 1000m
    memory: 4Gi

# ── HPA 弹性扩缩 ────────────────────────────────────────────────
# 生产配置：min 2（HA，节点/AZ 故障或滚动重启期间不掉零容量），
# max 20（~100 Gi + 20 vCPU 上限，防止 Karpenter 失控扩容）。
# 仅按 CPU 扩缩：LiteLLM 是 I/O-bound gateway，内存是每 worker 固定基线，
# 用内存做扩缩信号会"永远 hot"，无法收敛。
# NOTE: chart 的 autoscaling 只暴露基础 4 项；scaleUp/scaleDown behavior
# 需要 post-install kubectl patch（见 §5.5）。
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 20
  targetCPUUtilizationPercentage: 70

# ── scaffolding OIDC（内部 scaffolding 认证配置）──────────────
scaffolding:
  config:
    auth: oidc://3okkkpoeplqvc65fd2nmrng88t:1o3naif8jv94emj2r3htmvp3e9qvscroj6uaqacnfk9035v6vav2@cognito-idp.us-west-2.amazonaws.com/us-west-2_xSNj224mA?scope=openid%20profile%20email&oidc_logout=false

# ── 服务 ────────────────────────────────────────────────────────
service:
  port: 4000
  type: ClusterIP

# ── ServiceAccount（pre-existing，需提前创建并绑定 IRSA）───────
serviceAccount:
  create: false
  name: litellm-sa
```

---

## 四、Helm 一键部署

```bash
# 首次安装
helm upgrade --install litellm litellm/litellm-helm \
  --namespace litellm \
  --create-namespace \
  --version 1.82.3 \
  --values values.yaml \
  --wait \
  --timeout 10m
```

> Helm 完成后，**还需要执行第五节的 post-install 步骤**，因为 Helm chart 不支持以下功能的原生配置：
> - `litellm-custom-callbacks` ConfigMap（custom_callbacks.py）
> - `litellm-config` ConfigMap 中的 `semantic_router.json` key
> - Deployment 的额外 volume / volumeMount（callbacks + semantic_router）
> - HPA 的 `behavior` 块（scaleUp / scaleDown 稳定窗口和策略）

---

## 五、Post-Install 优化步骤

### 5.1 创建 custom-callbacks ConfigMap

```bash
# 从 docs/litellm/auto-model/custom_callbacks.py 创建 ConfigMap
kubectl create configmap litellm-custom-callbacks -n litellm \
  --from-file=custom_callbacks.py=docs/litellm/auto-model/custom_callbacks.py \
  --dry-run=client -o yaml | kubectl apply -f -

# 保留 Helm 元数据（避免后续 helm upgrade 冲突）
kubectl label  configmap litellm-custom-callbacks -n litellm \
  app.kubernetes.io/managed-by=Helm --overwrite
kubectl annotate configmap litellm-custom-callbacks -n litellm \
  meta.helm.sh/release-name=litellm \
  meta.helm.sh/release-namespace=litellm --overwrite
```

### 5.2 追加 semantic_router.json 到 litellm-config ConfigMap

```bash
# 把 semantic_router.json 追加为 litellm-config 的第二个 data key
# （litellm-config 已由 Helm 创建，这里只 patch，不替换整个 CM）
kubectl create configmap litellm-config -n litellm \
  --from-file=config.yaml=<(kubectl get cm litellm-config -n litellm \
      -o jsonpath='{.data.config\.yaml}') \
  --from-file=semantic_router.json=docs/litellm/auto-model/semantic_router.json \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 5.3 给 Deployment 添加 callbacks + router volume mount

> **注意**：同一个 ConfigMap 在同一个 volume 里不能用两个不同 subPath 挂载——必须用两个独立 volume entry 引用同一 ConfigMap。

```bash
kubectl patch deployment litellm -n litellm --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "custom-callbacks",
      "configMap": {
        "name": "litellm-custom-callbacks",
        "defaultMode": 420
      }
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/volumeMounts/-",
    "value": {
      "name": "custom-callbacks",
      "mountPath": "/etc/litellm/custom_callbacks.py",
      "subPath": "custom_callbacks.py",
      "readOnly": true
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "litellm-router-config",
      "configMap": {
        "name": "litellm-config",
        "items": [{"key": "semantic_router.json", "path": "semantic_router.json"}]
      }
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/volumeMounts/-",
    "value": {
      "name": "litellm-router-config",
      "mountPath": "/etc/litellm/semantic_router.json",
      "subPath": "semantic_router.json",
      "readOnly": true
    }
  }
]'
```

### 5.4 给 HPA 补上 scaleUp / scaleDown behavior

Chart 的 `autoscaling:` 只支持 `enabled/minReplicas/maxReplicas/targetCPUUtilizationPercentage`
四个字段，没有 `behavior` block。生产环境需要下面的行为调优：

- **scaleUp**: 60s 稳定窗口 + `Max(+100%, +4 pods)/min` — 突发流量快速扩容但不追瞬时抖动。
- **scaleDown**: 300s 稳定窗口 + `-1 pod / 2min` — 保护长连接 streaming 请求。

```bash
kubectl patch hpa litellm -n litellm --type='merge' -p '{
  "spec": {
    "behavior": {
      "scaleUp": {
        "stabilizationWindowSeconds": 60,
        "selectPolicy": "Max",
        "policies": [
          {"type": "Percent", "value": 100, "periodSeconds": 60},
          {"type": "Pods",    "value": 4,   "periodSeconds": 60}
        ]
      },
      "scaleDown": {
        "stabilizationWindowSeconds": 300,
        "policies": [
          {"type": "Pods", "value": 1, "periodSeconds": 120}
        ]
      }
    }
  }
}'
```

### 5.5 触发滚动重启并验证

```bash
kubectl rollout restart deployment/litellm -n litellm
kubectl rollout status  deployment/litellm -n litellm --timeout=180s

# HPA 就绪后 target 应显示实际百分比而不是 <unknown>
kubectl get hpa -n litellm
# NAME      REFERENCE            TARGETS   MINPODS   MAXPODS   REPLICAS
# litellm   Deployment/litellm   3%/70%    2         20        2
```

---

## 六、Bedrock 模型自动同步（CronJob）

每小时扫描 Bedrock 新增的 global inference profiles 并自动追加到 model_list。

```bash
# 部署 model-sync（YAML 在 docs/litellm/sync/litellm-model-sync.md）
kubectl apply -f docs/litellm/sync/litellm-model-sync.md

# 立即手动触发一次验证
kubectl create job litellm-model-sync-manual \
  --from=cronjob/litellm-model-sync -n litellm

# 查看日志
kubectl logs -n litellm \
  $(kubectl get pods -n litellm -l app.kubernetes.io/name=litellm-model-sync \
    --sort-by=.metadata.creationTimestamp -o name | tail -1) -f
```

---

## 七、完整验证

```bash
# 获取 master key 和 Service IP
MK=$(kubectl get secret litellm-masterkey -n litellm \
     -o jsonpath='{.data.masterkey}' | base64 -d)
SVC_IP=$(kubectl get svc litellm -n litellm -o jsonpath='{.spec.clusterIP}')

# 1. 检查 /v1/models（期望 auto、claude-*、qwen3-coder-480b、kimi-k2.5 等）
curl -sS "http://[$SVC_IP]:4000/v1/models" \
  -H "Authorization: Bearer $MK" \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
need = ['auto','claude-opus-4-7','claude-sonnet-4-6','claude-haiku-4-5-20251001',
        'qwen3-coder-480b','kimi-k2.5','zai.glm-5','deepseek-v3.2','bedrock-embed-v4']
names = [m['id'] for m in d['data']]
[print(f'  {n:35s} {\"OK\" if n in names else \"MISSING\"}') for n in need]
"

# 2. 检查 custom_callbacks 是否已挂载
kubectl exec -n litellm deploy/litellm -- ls /etc/litellm/

# 3. 检查 pod 日志（期望无 ERROR）
kubectl logs -n litellm -l app.kubernetes.io/name=litellm --tail=50 \
  | grep -iE 'Loading route config|callback|error' | head -20

# 4. 四档语义路由冒烟测试
for pair in \
  "haiku::你好" \
  "qwen::write a python function to reverse a linked list" \
  "sonnet::find the bug in this code: def div(a,b): return a/b" \
  "opus::design a multi-region distributed payment system"; do
  label="${pair%%::*}"; prompt="${pair#*::}"
  curl -sS "http://[$SVC_IP]:4000/v1/chat/completions" \
    -H "Authorization: Bearer $MK" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "import json; print(json.dumps({'model':'auto',
        'messages':[{'role':'user','content':'$prompt'}],'max_tokens':10}))")" \
    > /dev/null
  echo "  sent [$label]"
done

sleep 8

# 5. 查看路由结果（实际派发到哪个底层模型）
curl -sS "http://[$SVC_IP]:4000/spend/logs?limit=10" \
  -H "Authorization: Bearer $MK" \
  | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
entries = d if isinstance(d,list) else d.get('data',[])
entries = sorted(entries, key=lambda e: e.get('startTime','') or '', reverse=True)[:4]
for e in reversed(entries):
    st = e.get('startTime','')[11:19]
    m  = e.get('model','?').split('/')[-1]
    t  = e.get('total_tokens','?')
    print(f'  {st}  {m:55s}  tokens={t}')
"
```

**期望输出：**

```
  08:43:01  claude-haiku-4-5-20251001-v1:0                       tokens=~230
  08:43:05  qwen.qwen3-coder-480b-a35b-v1:0                      tokens=~212
  08:43:11  claude-sonnet-4-6                                     tokens=~260
  08:43:13  claude-opus-4-7                                       tokens=~320
```

---

## 八、升级流程

```bash
# 1. 备份当前 ConfigMap（预防 proxy_config 被覆盖）
kubectl get configmap litellm-config -n litellm -o yaml \
  > /tmp/litellm-config-backup-$(date +%Y%m%d-%H%M%S).yaml

# 2. helm upgrade（values.yaml 包含 proxy_config，会重写 config.yaml）
helm upgrade litellm litellm/litellm-helm \
  --namespace litellm \
  --version <NEW_VERSION> \
  --values values.yaml \
  --wait \
  --timeout 10m

# 3. 检查 custom-callbacks 和 semantic_router 是否还在
kubectl get configmap litellm-custom-callbacks -n litellm -o jsonpath='{.data}' | grep -c proxy_handler
kubectl get configmap litellm-config -n litellm -o jsonpath='{.data}' | grep semantic_router

# 如果 litellm-config 的 semantic_router key 被覆盖了（helm upgrade 只写 config.yaml），
# 重跑第五节 §5.2 追加回来

# 4. 检查 deployment volumes 是否还有 custom-callbacks + litellm-router-config
kubectl get deployment litellm -n litellm \
  -o jsonpath='{.spec.template.spec.volumes[*].name}' | tr ' ' '\n'
# 期望: litellm-config  custom-callbacks  litellm-router-config

# 5. 如果 volumes 被重置了（helm upgrade 覆盖了 deployment），重跑 §5.3

# 6. 检查 HPA behavior 是否还在（helm upgrade 会重建 HPA，behavior 会丢失）
kubectl get hpa litellm -n litellm -o jsonpath='{.spec.behavior}'
# 期望: 非空 JSON。如果空/null，重跑 §5.4 patch behavior
```

---

## 九、当前集群状态速查

```bash
# Helm 发布
helm list -n litellm

# Pod 状态
kubectl get all -n litellm

# HPA 状态（min 2, max 20, CPU target 70%）
kubectl get hpa litellm -n litellm

# 确认 behavior 已 patch（scaleUp / scaleDown 应有值）
kubectl get hpa litellm -n litellm -o jsonpath='{.spec.behavior}' | python3 -m json.tool

# ConfigMap 数据 key
kubectl get configmap -n litellm

# 查看实际 config.yaml
kubectl get configmap litellm-config -n litellm \
  -o jsonpath='{.data.config\.yaml}'

# 查看 Helm 记录的 values（注意：proxy_config 可能与实际 ConfigMap 有差异）
helm get values litellm -n litellm
```

**关键资源清单：**

| 资源 | 名称 | 说明 |
|------|------|------|
| Deployment | `litellm` | 2 个 Pod 起（HPA 按 CPU 弹性扩缩） |
| Service | `litellm` | ClusterIP IPv6 :4000 |
| HPA | `litellm` | min 2 / max 20 / CPU 70% |
| ConfigMap | `litellm-config` | `config.yaml` + `semantic_router.json` |
| ConfigMap | `litellm-custom-callbacks` | `custom_callbacks.py` |
| Secret | `litellm-masterkey` | master key |
| Secret | `postgres-creds` | RDS 凭据（外部创建） |
| CronJob | `litellm-model-sync` | Bedrock 模型自动同步（每小时） |
| ServiceAccount | `litellm-sa` | 绑定 IRSA/Pod Identity → Bedrock |

---

## 十、语义路由四档模型

| 档位 | trigger 语义 | 目标模型 | 价格（$/MTok in/out） |
|------|--------------|----------|-----------------------|
| Trivial | 打招呼、翻译、改名、定义 | `claude-haiku-4-5-20251001` | 1.00 / 5.00 |
| Boilerplate | 代码生成、CRUD、测试、重构 | `qwen3-coder-480b` | 0.22 / 1.80 |
| Review/Debug | 代码评审、找 bug、性能分析 | `claude-sonnet-4-6` | 3.00 / 15.00 |
| Architecture | 系统设计、多步推理、根因分析 | `claude-opus-4-7` | 5.00 / 25.00 |

**Embedding 模型**：`bedrock/global.cohere.embed-v4:0`（Cohere Embed v4，1536 维，≤ 96 utterances/batch）

**score_threshold**：Haiku 0.42 / Qwen 0.45 / Sonnet 0.50 / Opus 0.48；匹配不到时默认路由到 Haiku。

---

## 十一、custom_callbacks.py 解决的 4 个生产问题

1. **剥离 `context_management`** — Anthropic proxy 独有字段，Bedrock Converse 拒收，对所有目标生效。
2. **只在非 Claude 目标剥离 `thinking`/`adaptive_thinking`** — 避免直调 Claude 时 extended thinking 被破坏；`auto` 视作非 Claude（可能路由到 Qwen/Kimi）。
3. **非 Claude 目标历史消息清理** — Bedrock Converse 的 Qwen/Kimi/DeepSeek endpoint 收到 `type:"thinking"` 块或空 `text` 块会 400；callback 清理 `assistant` 历史，`content` 全部清空时补 `(continued)` 占位。
4. **auto 路由入口 content flatten + 剥离 `<system-reminder>`** — Cohere Embed v4 不接受 list-of-dict content；Claude Code 每轮带多个 `<system-reminder>` 文本块会导致真实 prompt 被稀释，全落 Haiku；callback 在 flatten 前过滤掉所有 `<system-reminder>` 块。

---

## 十二、回滚

```bash
# 1. 恢复 ConfigMap
kubectl apply -f /tmp/litellm-config-backup-*.yaml

# 2. 恢复 custom-callbacks（如果丢失）
kubectl create configmap litellm-custom-callbacks -n litellm \
  --from-file=custom_callbacks.py=docs/litellm/auto-model/custom_callbacks.py \
  --dry-run=client -o yaml | kubectl apply -f -

# 3. 重启
kubectl rollout restart deployment/litellm -n litellm
kubectl rollout status  deployment/litellm -n litellm --timeout=180s

# 4. Helm 版本回滚（如果升级引入了问题）
helm rollback litellm -n litellm
```

---

## 十三、相关文档

| 文档 | 路径 | 内容 |
|------|------|------|
| Auto 模型部署（服务端）| `docs/litellm/litellm-auto-model-setup.md` | 语义路由完整部署文档 |
| Claude Code 客户端接入 | `docs/litellm/claude-code-usage.md` | settings.json、availableModels、常见问题 |
| 成本降低指南 | `docs/litellm/claude-code-cost-saving.md` | prompt cache、`/model auto`、claude-mem |
| Bedrock 模型自动同步 | `docs/litellm/sync/litellm-model-sync.md` | CronJob 完整 YAML |
| 模型调研数据 | `docs/litellm/bedrock-coding-models-findings.json` | Bedrock 编程模型性能/价格 findings |
