# LiteLLM Auto Model — 服务端配置与部署文档

> **适用场景：** 在已有 LiteLLM proxy（EKS/K8s 部署）上新增 `model="auto"` 的语义路由入口，按请求语义自动分流到四档 AWS Bedrock 模型。
>
> **前提：** LiteLLM 容器镜像 **≥ v1.82.0**（修复了 auto_router 多模态 content 崩溃问题），Pod 通过 IRSA / EKS Pod Identity 调用 Bedrock。
>
> **实测验证环境：** `ghcr.io/berriai/litellm-database:v1.83.3-stable.opus-4.7`，AWS us-west-2，EKS Pod Identity，Namespace `litellm`。

---

## 1. 路由目标模型（us-west-2 Bedrock，全部实测通过）

| 档位 | 触发语义 | 目标模型 (us-west-2 inference profile) | 价格 ($/MTok in/out) | SWE-bench Verified |
|------|----------|---------------------------------------|----------------------|--------------------|
| Trivial | 打招呼、定义、语法、文档、改名 | `global.anthropic.claude-haiku-4-5-20251001-v1:0` | 1.00 / 5.00 | 73.3% |
| Boilerplate | 代码生成、CRUD、测试、重构 | `qwen.qwen3-coder-480b-a35b-v1:0` | 0.22 / 1.80 | 69.6% |
| Review/Debug | 代码评审、查 bug、性能分析 | `global.anthropic.claude-sonnet-4-6` | 3.00 / 15.00 | 79.6% |
| Architecture | 系统设计、多步推理、根因分析 | `global.anthropic.claude-opus-4-7` | 5.00 / 25.00 | 87.6% |

**Embedding 模型：** `bedrock/global.cohere.embed-v4:0`（1536 维，多模态，128K 上下文）。

---

## 2. 架构图

```
            ┌──────────────────────────────┐
Client ───► │ model="auto" / messages=[…] │
            └──────────────┬───────────────┘
                           │
                           ▼
          ┌────────────────────────────────┐
          │  LiteLLM proxy                  │
          │                                 │
          │  async_pre_call_hook           │
          │   1. drop context_management    │
          │   2. drop thinking (non-Claude) │
          │   3. flatten content array,     │
          │      skip <system-reminder>     │
          └────────────────┬────────────────┘
                           │
                           ▼
          ┌────────────────────────────────┐
          │  auto_router/coding_auto_v1     │
          │  async_pre_routing_hook         │
          │   semantic_router.SemanticRouter│
          │   (loads semantic_router.json)  │
          │                                 │
          │   embedding: Bedrock Cohere v4  │
          │   threshold: per-route cosine   │
          └────────────────┬────────────────┘
                           │ model name rewritten to one of:
            ┌──────────────┼──────────────┬──────────────┐
            ▼              ▼              ▼              ▼
        Haiku 4.5     Qwen3-Coder      Sonnet 4.6      Opus 4.7
```

---

## 3. 需要部署的 3 个文件

```
<repo>/litellm/auto-model/
├─ litellm-config.yaml       # LiteLLM proxy 主配置，含 auto 入口
├─ semantic_router.json      # 四档语义路由规则（embedding utterances + 阈值）
└─ custom_callbacks.py       # 请求预处理（drop/flatten/denoise）
```

### 3.1 `semantic_router.json`（语义路由规则）

```json
{
  "encoder_type": "litellm",
  "encoder_name": "bedrock/global.cohere.embed-v4:0",
  "routes": [
    {
      "name": "claude-haiku-4-5-20251001",
      "description": "Trivial Q&A, greetings, definitions - cheap/fast tier",
      "score_threshold": 0.42,
      "utterances": [
        "hi", "hello", "hey", "who are you", "what can you do",
        "你好", "你是谁", "谢谢", "你能做什么", "介绍一下你自己",
        "1+1等于几", "什么是 python", "解释一下这段代码", "帮我翻译成英文",
        "给这个函数加注释", "define recursion", "what is a for loop",
        "format this json", "rename this variable", "add a docstring"
      ]
    },
    {
      "name": "qwen3-coder-480b",
      "description": "Code generation, boilerplate, tests, refactors",
      "score_threshold": 0.45,
      "utterances": [
        "write a python function to sort a list",
        "generate a fastapi endpoint",
        "implement binary search",
        "write a Dockerfile for this service",
        "create a kubernetes yaml manifest",
        "帮我写一个 python 函数来排序",
        "帮我写一个 fastapi 接口",
        "帮我生成一段 sql",
        "实现一个二分查找"
      ]
    },
    {
      "name": "claude-sonnet-4-6",
      "description": "Code review, bug hunting, debugging",
      "score_threshold": 0.50,
      "utterances": [
        "review this pull request",
        "find the bug in this code",
        "diagnose this stacktrace",
        "find the memory leak",
        "review 一下这个 pull request",
        "找一下这段代码的 bug",
        "为什么我的测试失败了",
        "这个 pod 为什么一直 crashloop"
      ]
    },
    {
      "name": "claude-opus-4-7",
      "description": "Deep reasoning, architecture, multi-step analysis",
      "score_threshold": 0.48,
      "utterances": [
        "design the architecture for a distributed system",
        "plan a migration from monolith to microservices",
        "root cause this production incident end to end",
        "设计一个分布式多区域支付系统的架构",
        "规划一次从单体到微服务的迁移",
        "根因分析这次跨服务的生产事故"
      ]
    }
  ]
}
```

> **两个关键约束：**
>
> 1. **总 utterances ≤ 96**。Cohere Embed v4 on Bedrock 的 batch 上限是 96；semantic-router 冷启动时会一次性 embed 所有 utterances。我们总共 85 条，留有 buffer。
> 2. **`routes[].name` 必须与 `litellm-config.yaml` 中某个 `model_name` 完全一致**。LiteLLM AutoRouter 用 route name 做 dispatch 的主键。
> 3. **`encoder_type: litellm`** —— 使用 LiteLLMEncoder 复用 Pod Identity 凭据，避免 `openai` 类型所需的 OpenAI API key，也避免 `bedrock` 类型所需的静态 AWS credentials。

完整文件见 [`auto-model/semantic_router.json`](./auto-model/semantic_router.json)。

### 3.2 `litellm-config.yaml`（proxy 主配置）

核心片段：

```yaml
general_settings:
  master_key: os.environ/PROXY_MASTER_KEY

litellm_settings:
  drop_params: true
  request_timeout: 600
  callbacks:
    - custom_callbacks.proxy_handler_instance   # 见 3.3

model_list:
  # ───────── Claude 全部别名（直接调用时使用） ─────────
  - model_name: claude-opus-4-7
    litellm_params:
      model: bedrock/global.anthropic.claude-opus-4-7
  - model_name: claude-sonnet-4-6
    litellm_params:
      model: bedrock/global.anthropic.claude-sonnet-4-6
  - model_name: claude-haiku-4-5-20251001
    litellm_params:
      model: bedrock/global.anthropic.claude-haiku-4-5-20251001-v1:0

  # ───────── 开源模型 picker 别名 ─────────
  - model_name: qwen3-coder-480b
    litellm_params:
      model: bedrock/qwen.qwen3-coder-480b-a35b-v1:0
      aws_region_name: us-west-2
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

  # ───────── Embedding（给 auto router 用）─────────
  - model_name: bedrock-embed-v4
    litellm_params:
      model: bedrock/global.cohere.embed-v4:0

  # ───────── Auto Router 入口 ─────────
  - model_name: auto
    litellm_params:
      model: auto_router/coding_auto_v1
      auto_router_config_path: /etc/litellm/semantic_router.json
      auto_router_default_model: claude-haiku-4-5-20251001   # 匹配不到时的默认
      auto_router_embedding_model: bedrock-embed-v4

  # ───────── 通配符兜底（允许 bedrock/xxx 直接透传）─────────
  - model_name: bedrock/*
    litellm_params:
      model: bedrock/*
      aws_region_name: us-west-2
```

完整文件见 [`auto-model/litellm-config.yaml`](./auto-model/litellm-config.yaml)。

### 3.3 `custom_callbacks.py`（请求预处理）

解决 4 个生产踩坑，全部在 LiteLLM 的 `async_pre_call_hook` 里完成（客户端无感知）：

1. **剥离 `context_management`** — Anthropic-proxy 独有字段，Bedrock Converse 拒收。对所有目标生效。
2. **只在非 Claude 目标上剥离 `thinking` / `adaptive_thinking`** — 避免 Claude 直调时 extended thinking 被破坏。`auto` 入口视作非 Claude（因可能派发到 Qwen/Kimi）。
3. **非 Claude 目标的历史消息清理** — Claude 在带 thinking 时返回 `[{type:"thinking", ...}, {type:"text", text:""}]`，DeepSeek R1 等推理型模型也会返回空 text。下一轮 Claude Code 回放历史到非 Claude 模型（或 auto 路由到非 Claude）时，Bedrock Converse 会 400：*"The text field in the ContentBlock object at messages.N.content.K is blank"*。callback 会从 assistant 历史里剥离 `type:"thinking"` 块和 `text` 为空白的块；若整个 `content` 被清空则补一个 `(continued)` 占位块。
4. **Auto 路由入口专用 content flatten** — Cohere Embed v4 on Bedrock 不接受 `[{type:"text", text:"..."}]` 列表，会返回 *Malformed request*。同时剥离 Claude Code 发来的 `<system-reminder>` 文本块，避免系统提示淹没真实 user prompt，导致全部落到 Haiku 档。

```python
from litellm.integrations.custom_logger import CustomLogger

ALWAYS_DROP_KEYS = ["context_management"]
CLAUDE_ONLY_KEYS = ["adaptive_thinking", "thinking"]
AUTO_ROUTER_PREFIXES = ("auto", "smart-router", "semantic-router")

def _is_claude_model(m):
    return isinstance(m, str) and ("claude" in m.lower() or "anthropic" in m.lower())

def _is_auto_router(m):
    if not isinstance(m, str): return False
    n = m.lower()
    return any(n == p or n.startswith(p + "-") or n.startswith(p + "/") for p in AUTO_ROUTER_PREFIXES)

def _scrub(obj, drop_keys):
    if isinstance(obj, dict):
        for k in list(obj.keys()):
            if k in drop_keys: obj.pop(k, None)
            else: _scrub(obj[k], drop_keys)
    elif isinstance(obj, list):
        for item in obj: _scrub(item, drop_keys)

def _is_system_reminder(text):
    return isinstance(text, str) and text.lstrip().startswith("<system-reminder>")

def _flatten_routing_text(content):
    if isinstance(content, str): return content
    if isinstance(content, list):
        texts = []
        for blk in content:
            if isinstance(blk, dict) and isinstance(blk.get("text"), str):
                texts.append(blk["text"])
            elif isinstance(blk, str):
                texts.append(blk)
        real = [t for t in texts if not _is_system_reminder(t)]
        return "\n".join(real if real else texts)
    return str(content)

def _sanitize_history_for_non_claude(messages):
    """Drop `thinking` blocks and empty-text blocks from assistant history.
    Required for multi-turn on DeepSeek R1 / Qwen / Kimi / GLM / Mistral."""
    if not isinstance(messages, list):
        return
    for msg in messages:
        if not isinstance(msg, dict):
            continue
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        cleaned = []
        for blk in content:
            if not isinstance(blk, dict):
                cleaned.append(blk); continue
            btype = blk.get("type")
            if btype == "thinking":
                continue
            if btype == "text" and not (blk.get("text") or "").strip():
                continue
            cleaned.append(blk)
        if not cleaned:
            cleaned = [{"type": "text", "text": "(continued)"}]
        msg["content"] = cleaned

class ProxyPreCallFixups(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        try:
            model = data.get("model") or ""
            # (1) Always drop Anthropic-proxy-only extras
            _scrub(data, ALWAYS_DROP_KEYS)
            # (2) Strip Claude-only thinking params on non-Claude targets
            if not _is_claude_model(model) or _is_auto_router(model):
                _scrub(data, CLAUDE_ONLY_KEYS)
            # (3) Sanitize assistant history for non-Claude / auto targets
            if not _is_claude_model(model) or _is_auto_router(model):
                _sanitize_history_for_non_claude(data.get("messages"))
            # (4) Flatten + denoise user content for auto-router entrypoints
            if _is_auto_router(model):
                msgs = data.get("messages")
                if isinstance(msgs, list):
                    for m in msgs:
                        if isinstance(m, dict) and "content" in m:
                            m["content"] = _flatten_routing_text(m["content"])
        except Exception:
            pass
        return data

proxy_handler_instance = ProxyPreCallFixups()
```

完整文件见 [`auto-model/custom_callbacks.py`](./auto-model/custom_callbacks.py)。

> **测试用例（多轮会话）：**
>
> ```bash
> # 多轮 DeepSeek R1，曾经在第 2 轮 400，现在 OK
> MK=<your LiteLLM key>
> BASE=<your LiteLLM base url>
> RESP1=$(curl -sS "$BASE/v1/messages" \
>   -H "x-api-key: $MK" -H "anthropic-version: 2023-06-01" -H "Content-Type: application/json" \
>   -d '{"model":"bedrock/us.deepseek.r1-v1:0","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}')
> ASSIST=$(echo "$RESP1" | python3 -c "import json,sys;print(json.dumps(json.loads(sys.stdin.read()).get('content',[])))")
> curl -sS "$BASE/v1/messages" \
>   -H "x-api-key: $MK" -H "anthropic-version: 2023-06-01" -H "Content-Type: application/json" \
>   -d "$(python3 -c "import json; msgs=[{'role':'user','content':[{'type':'text','text':'hi'}]},{'role':'assistant','content':$ASSIST},{'role':'user','content':[{'type':'text','text':'what is your name'}]}]; print(json.dumps({'model':'bedrock/us.deepseek.r1-v1:0','max_tokens':30,'messages':msgs}))")"
> ```

---

## 4. 部署步骤（在现有 LiteLLM 集群上）

假设命名空间 `litellm`，Deployment 名 `litellm`，Service 名 `litellm`，现有 ConfigMap 由 Helm 管理。

### 4.1 前置检查

```bash
# 镜像版本 ≥ v1.82.0
kubectl get deployment litellm -n litellm -o jsonpath='{.spec.template.spec.containers[0].image}'

# Pod 能调 Bedrock：确认 ServiceAccount 绑定了 IRSA / Pod Identity
kubectl get sa -n litellm
kubectl get pod -n litellm -l app.kubernetes.io/name=litellm -o jsonpath='{.items[0].spec.serviceAccount}'

# 确认目标区域已启用模型访问（Bedrock 控制台 → Model access）
aws bedrock list-inference-profiles --region us-west-2 \
  --query 'inferenceProfileSummaries[?contains(inferenceProfileId,`claude-opus-4-7`)].[inferenceProfileId,status]' \
  --output table
aws bedrock list-foundation-models --region us-west-2 \
  --query 'modelSummaries[?contains(modelId,`cohere.embed-v4`) || contains(modelId,`qwen3-coder-480b`)].[modelId]' \
  --output table
```

### 4.2 步骤 1：备份原 ConfigMap

```bash
kubectl get configmap litellm-config -n litellm -o yaml \
  > /tmp/configmap-litellm-config.backup.$(date +%Y%m%d-%H%M%S).yaml
kubectl get configmap litellm-custom-callbacks -n litellm -o yaml \
  > /tmp/configmap-litellm-custom-callbacks.backup.$(date +%Y%m%d-%H%M%S).yaml
```

### 4.3 步骤 2：准备三个文件

```bash
# 假设文件位于 ./litellm/auto-model/ 下
cd litellm/auto-model
ls
# -> litellm-config.yaml  semantic_router.json  custom_callbacks.py
```

### 4.4 步骤 3：更新 ConfigMap

```bash
# litellm-config: 两个 key（配置 + 路由 JSON）
kubectl create configmap litellm-config -n litellm \
  --from-file=config.yaml=litellm-config.yaml \
  --from-file=semantic_router.json=semantic_router.json \
  --dry-run=client -o yaml | kubectl apply -f -

# custom-callbacks: 单 key
kubectl create configmap litellm-custom-callbacks -n litellm \
  --from-file=custom_callbacks.py=custom_callbacks.py \
  --dry-run=client -o yaml | kubectl apply -f -

# 保留 Helm 元数据（避免 Helm 后续 upgrade 冲突）
for cm in litellm-config litellm-custom-callbacks; do
  kubectl label  configmap "$cm" -n litellm app.kubernetes.io/managed-by=Helm --overwrite
  kubectl annotate configmap "$cm" -n litellm meta.helm.sh/release-name=litellm --overwrite
  kubectl annotate configmap "$cm" -n litellm meta.helm.sh/release-namespace=litellm --overwrite
done
```

### 4.5 步骤 4：挂载 semantic_router.json

> **陷阱：** 不能在同一个 volume 上追加第二个 subPath 挂载，会被 kubelet 解析成目录。必须另建 volume 引用同一 ConfigMap，只 expose 目标 key。

```bash
kubectl patch deployment litellm -n litellm --type='json' -p='[
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

> 如果此 patch 已经在 Deployment 上存在（可用 `kubectl get deployment litellm -n litellm -o jsonpath='{.spec.template.spec.containers[0].volumeMounts}' | grep semantic_router.json` 检查），跳过即可。

### 4.6 步骤 5：添加一个占位 env（semantic-router 初始化要求）

```bash
# LiteLLMEncoder 构造时要求 BEDROCK_API_KEY 环境变量非空（实际认证走 Pod Identity）
kubectl set env deployment/litellm -n litellm BEDROCK_API_KEY=placeholder
```

### 4.7 步骤 6：触发重启并等待就绪

```bash
kubectl rollout restart deployment/litellm -n litellm
kubectl rollout status  deployment/litellm -n litellm --timeout=180s
```

### 4.8 步骤 7：验证

```bash
# 1) auto 模型已注册到 /v1/models
#    （用集群内 Service DNS 或 Pod IP 直连；IPv6 cluster 用 [svc-ip]:4000）
MK=$(kubectl get secret litellm-masterkey -n litellm -o jsonpath='{.data.masterkey}' | base64 -d)
SVC_IP=$(kubectl get svc litellm -n litellm -o jsonpath='{.spec.clusterIP}')
curl -sS "http://[$SVC_IP]:4000/v1/models" -H "Authorization: Bearer $MK" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); \
      need=['auto','claude-opus-4-7','claude-sonnet-4-6','claude-haiku-4-5-20251001',\
            'qwen3-coder-480b','kimi-k2.5','zai.glm-5','deepseek-v3.2','bedrock-embed-v4']; \
      names=[m['id'] for m in d['data']]; \
      [print(f'  {n:30s} {\"OK\" if n in names else \"MISSING\"}') for n in need]"

# 2) Pod 启动日志干净
kubectl logs -n litellm -l app.kubernetes.io/name=litellm --tail=100 \
  | grep -iE 'Loading route config|Error creating deployment'
# 期望：Loading route config from /etc/litellm/semantic_router.json (× num_workers)

# 3) 四档冒烟测试（通过 service DNS 直连）
for pair in \
  "haiku::你好" \
  "qwen::write a python function to reverse a linked list" \
  "sonnet::find the bug in this code: def div(a,b): return a/b" \
  "opus::design a multi-region distributed payment system"; do
  label="${pair%%::*}"; prompt="${pair#*::}"
  curl -sS "http://[$SVC_IP]:4000/v1/chat/completions" -H "Authorization: Bearer $MK" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "import json; print(json.dumps({'model':'auto','messages':[{'role':'user','content':'$prompt'}],'max_tokens':10}))")" \
    > /dev/null
  echo "  sent [$label] $prompt"
done

sleep 8
# 4) 观察每次调用的实际目标模型
curl -sS "http://[$SVC_IP]:4000/spend/logs?limit=10" -H "Authorization: Bearer $MK" \
  | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
entries = d if isinstance(d,list) else d.get('data',[])
entries = sorted(entries, key=lambda e: e.get('startTime','') or '', reverse=True)[:4]
for e in reversed(entries):
    st = e.get('startTime','')[11:19]
    m  = e.get('model','?').split('/')[-1]
    t  = e.get('total_tokens','?')
    print(f'  {st}  {m:60s}  tokens={t}')
"
```

**期望输出（实测）：**

```
  08:43:01  claude-haiku-4-5-20251001-v1:0                                tokens=230
  08:43:05  qwen.qwen3-coder-480b-a35b-v1:0                               tokens=212
  08:43:11  claude-sonnet-4-6                                             tokens=260
  08:43:13  claude-opus-4-7                                               tokens=320
```

---

## 5. 常见问题

### 5.1 Claude Code `/model` picker 里选择 Opus/Sonnet/Haiku 后报 400

**现象：** 在 Claude Code 里输入 `/model`，选 Opus（或 Sonnet / Haiku），下次发言立刻报：

```
API Error: 400 litellm.BadRequestError: You passed in model=opus.
There are no healthy deployments for this model.
Received Model Group=opus
```

**原因：** Claude Code 的 picker 在用户选 Opus/Sonnet/Haiku 时把字面字符串 `opus` / `sonnet` / `haiku` 直接作为 `model` 发给后端。LiteLLM 只注册了 `claude-opus-4-7` / `claude-sonnet-4-6` / `claude-haiku-4-5-20251001` 这些带版本号的实名，所以收到 `model=opus` 时找不到 deployment。

**修复方式：在客户端展开 alias，不要污染 LiteLLM `model_list`。** 三个 alias 的解析完全由 Claude Code 侧的 `ANTHROPIC_DEFAULT_*_MODEL` 环境变量控制 — 设置后，client 在发请求前会把 `opus` 原地替换成完整模型 ID 再发出去，LiteLLM 收到的 `model` 就是已注册的实名。

**推荐做法**（见配套客户端文档 [`claude-code-usage.md`](./claude-code-usage.md) §4.1 settings.json 片段）：

```bash
# 方式 A：shell 环境变量
export ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-7
export ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4-6
export ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5-20251001
```

或者在 `~/.claude/settings.json` 的 `env` 块里写这三行（推荐方式，一次配置全局生效）。

**验证方式：**

```bash
export ANTHROPIC_BASE_URL="<your LiteLLM base url>"
export ANTHROPIC_API_KEY="<your LiteLLM virtual key>"
export ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-7
export ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4-6
export ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5-20251001
unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY

for m in opus sonnet haiku; do
  echo "--- --model $m ---"
  claude -p --model "$m" --permission-mode bypassPermissions \
    --max-turns 1 --output-format text "what model are you? 5 words"
done
```

每一档都应当正常返回对应型号（"Claude Opus 4.7" / "Claude Sonnet 4.6" / "Claude Haiku 4.5"），而不是 400。

**为什么不在 LiteLLM 里注册裸别名？** 之前试过在 `model_list` 里同时加 `opus`/`sonnet`/`haiku` 三条裸名 — 确实可以让无脑 picker 绕过报错，但会带来两个问题：(1) 污染 `/v1/models` 列表，其他走 LiteLLM 的客户端（Cline、Continue、aider）会看到同名资源跟 Claude Code 的 alias 抢解析；(2) 语义不稳定 — 裸名随 Anthropic 更新"opus 指代哪一版"会漂，而 LiteLLM 这一端我们希望**只暴露版本化的显式命名**。正确的解耦边界是：**Claude Code 解析 alias → LiteLLM 只认版本化的模型名**。

---

## 6. 已知告警（不影响正确性）

| 日志 | 原因 | 处理 |
|------|------|------|
| `WARNING semantic_router No index provided. Using default LocalIndex.` | 用进程内 LocalIndex（内存），无持久化 | 不用理；每 Pod 冷启动会重新 embed 所有 utterances（~1 次 Bedrock 调用） |
| `WARNING semantic_router Score threshold not set for model: bedrock-embed-v4.` | embedding 模型条目本身没有 route score_threshold | 预期行为，正常 |
| `ERROR CROSSSLOT Keys in request don't hash to the same slot` | ElastiCache Valkey Cluster Mode 在批量 GET 多 key 时的集群限制 | 与 auto-router 无关；如要消除需改 `cache_type: redis-semantic` + hash-tag 前缀 |

---

## 7. 与 `litellm-model-sync` CronJob 共存

仓库里另有一份文档 [`sync/litellm-model-sync.md`](./sync/litellm-model-sync.md)（CronJob，每小时扫描 Bedrock 新发布的 `global.anthropic.claude*` / `global.moonshotai*` inference profile，自动追加到 `model_list`）。两份文档互补，按以下要点共存即可：

### 7.1 兼容性

经代码走读，sync CronJob **不会破坏** 本文档部署的 auto 路由能力（§7.1–§7.3 对应原 §6.1–§6.3，重编号后跨引用不变）：

| 今天新增的内容 | sync CronJob 的影响 |
|----------------|--------------------|
| ConfigMap 第二个 key `semantic_router.json` | **无影响**。sync 只 `kubectl patch --type=merge {"data":{"config.yaml":...}}`，不触碰其它 key。 |
| `model_list` 里的 `auto` / `bedrock-embed-v4` / `qwen3-coder-480b` / `kimi-k2.5` / `zai.glm-5` / `deepseek-v3.2` | **无影响**。sync 用 `yaml.safe_load` 整个 `config.yaml` 后，只在 `config["model_list"]` 上**追加**新条目；其它字段（`general_settings` / `litellm_settings.callbacks` / `router_settings`）原样 `yaml.dump` 写回。 |
| 命名冲突 | sync 脚本内置 `if name in existing_names: 跳过`，已有的别名（如手动配的 `kimi-k2.5`）不会被覆盖。 |
| `semantic_router.json` 中 route 名字（必须等于某个 `model_name`） | sync 只追加新条目、不改现有条目名字，route → model 的引用稳定。 |
| `custom_callbacks.py` / Deployment 的 volume / `BEDROCK_API_KEY` env | sync 只做 `kubectl rollout restart`，不改 Deployment spec。重启后这些配置照常生效。 |
| 无新模型时 | sync 完全不动 ConfigMap 和 Deployment，**不触发重启**，auto 路由不会被无故扰动。 |

### 7.2 两个副作用（可接受）

1. **YAML 注释会被 sync 重写丢弃。** 本文档的 `litellm-config.yaml` 里有 `# ───────── xxx ─────────` 分节注释，`yaml.safe_load + yaml.dump` 往返不保留注释；只要 sync 首次追加了新模型触发一次 ConfigMap rewrite，这些注释就消失。**功能无影响**，只是 `kubectl get configmap -o yaml` 的可读性会变差。

2. **首次发现 Kimi/GLM/Qwen 同名新 profile 时会跳过。** 例如 sync 若发现 `global.moonshotai.kimi-k2.5` 的 ACTIVE profile，它推断出的别名也是 `kimi-k2.5`，与本文档手动配置的 `model_name: kimi-k2.5` 冲突 → sync 打印 `[别名冲突] 跳过`，保留我们的手动配置（手动配置里 `model` 指的是 `bedrock/moonshotai.kimi-k2.5` ON_DEMAND 端点，和 sync 要加的 `bedrock/global.moonshotai.kimi-k2.5` inference profile 可能是同一产品的两种接入路径，具体取账号当时可用性决定）。若想把手动别名切到 inference profile，删掉手动条目让 sync 下一轮自动填上即可。

### 7.3 推荐做法 / 如果 sync 已经先部署

如果你的集群里 `litellm-model-sync` CronJob 已经在跑，本文档的 auto 部署仍可直接叠加（经 6.1 代码走读验证不会被破坏），但建议按以下顺序安全推进：

**步骤 1：定位现有 sync 资源**

```bash
# 找 CronJob（按 sync 文档的默认 namespace 和名字）
kubectl get cronjob litellm-model-sync -n litellm
kubectl describe cronjob litellm-model-sync -n litellm | head -40

# 找相关资源（统一的 label 是 app.kubernetes.io/name=litellm-model-sync）
kubectl get cronjob,cm,sa,role,rolebinding \
  -l app.kubernetes.io/name=litellm-model-sync -n litellm

# 如果标签不一致，按名字兜底
kubectl get all,cm,sa,role,rolebinding -n litellm \
  | grep -iE 'litellm-model-sync|bedrock-sync'

# 看最近一次 Job 的执行日志，确认 sync 正常工作
LAST_POD=$(kubectl get pods -n litellm \
  -l app.kubernetes.io/name=litellm-model-sync \
  --sort-by=.metadata.creationTimestamp -o name | tail -1)
[ -n "$LAST_POD" ] && kubectl logs -n litellm "$LAST_POD" | tail -30
```

**步骤 2：在本文档部署前，先暂停 sync**

避免 auto 部署过程中 CronJob 整点触发，造成 ConfigMap 并发 patch：

```bash
# suspend CronJob（不删除，只暂停调度）
kubectl patch cronjob litellm-model-sync -n litellm \
  -p '{"spec":{"suspend":true}}'

# 确认 suspend 生效
kubectl get cronjob litellm-model-sync -n litellm \
  -o jsonpath='{.spec.suspend}{"\n"}'
# 期望输出: true

# 等待正在跑的 Job（如果有）完成
kubectl get jobs -n litellm -l app.kubernetes.io/name=litellm-model-sync
# 若有 Running 状态的 Job，等它结束或手动终止：
# kubectl delete job <job-name> -n litellm
```

**步骤 3：执行本文档 §4 的完整部署**

按 4.1 → 4.8 顺序执行。此时 sync 处于 suspended，不会有并发写入。

**步骤 4：验收通过后，恢复 sync**

```bash
# 恢复 CronJob 调度
kubectl patch cronjob litellm-model-sync -n litellm \
  -p '{"spec":{"suspend":false}}'

# 立即手动触发一次，验证 sync 与新的 auto 配置共存正常
kubectl create job litellm-model-sync-post-auto-check \
  --from=cronjob/litellm-model-sync -n litellm

# 查看这次手动 Job 的日志
sleep 30
kubectl logs -n litellm job/litellm-model-sync-post-auto-check -f

# 期望看到：
#   当前 ConfigMap 已有模型数: >= 11
#     - claude-opus-4-7 ...
#     - claude-sonnet-4-6 ...
#     - ... (略)
#     - qwen3-coder-480b
#     - kimi-k2.5
#     - zai.glm-5
#     - deepseek-v3.2
#     - bedrock-embed-v4
#     - auto
#     - bedrock/*
#   无新模型，退出。          ← 若 Bedrock 没发布新 profile 会停在这里
# 或：
#   [新模型] global.xxx → xxx
#   追加 N 个新模型，更新 ConfigMap...
#   触发 LiteLLM 滚动重启...
```

**步骤 5：验证 auto 路由在 sync 重启过 Pod 后仍然工作**

若步骤 4 显示有新模型追加并触发了 rollout，重启完成后重跑 §4.8 步骤 7 的四档冒烟测试，确认 `auto` 依旧分流正确。

**步骤 6（可选）：扩展 sync 的覆盖面**

本文档为 picker 新加的 `kimi-k2.5` / `zai.glm-5` / `deepseek-v3.2` 走的是 Bedrock ON_DEMAND 端点（非 global inference profile），这些模型 ID 属于 `moonshotai.*` / `zai.*` / `deepseek.*` 前缀，不在 sync 默认的 `SYNC_PREFIXES`（`global.anthropic.claude` / `global.moonshotai`）里，**所以 sync 不会重复追加、不会冲突**。

如果你希望 sync 也自动发现这些系列的将来新增版本，可以扩展 `ConfigMap/litellm-model-sync-script` 的 `sync.py` 里两个变量：

```bash
# 导出当前脚本
kubectl get configmap litellm-model-sync-script -n litellm \
  -o jsonpath='{.data.sync\.py}' > /tmp/sync.py

# 按需扩展 SYNC_PREFIXES / NAME_RULES，例如追加：
#   "global.cohere.embed"
#   "qwen.qwen3-coder"          # ON_DEMAND，非 global
#   "zai.glm"
# 并在 NAME_RULES 里补相应的正则替换

# 回写 ConfigMap
kubectl create configmap litellm-model-sync-script -n litellm \
  --from-file=sync.py=/tmp/sync.py \
  --dry-run=client -o yaml | kubectl apply -f -
# 下一次 CronJob 触发自动生效
```

注意脚本内置 `if name in existing_names: 跳过`，本文档手动配置的别名不会被覆盖（见 6.2 说明）。

**应急：如果 sync 在这期间意外跑了并改坏了 ConfigMap**

```bash
# 快速回退到本文档步骤 4.2 的备份
kubectl apply -f /tmp/configmap-litellm-config.backup.*.yaml
kubectl rollout restart deployment/litellm -n litellm
```

---

## 8. 回滚

```bash
# 恢复原 ConfigMap
kubectl apply -f /tmp/configmap-litellm-config.backup.*.yaml
kubectl apply -f /tmp/configmap-litellm-custom-callbacks.backup.*.yaml

# 从 Deployment 摘除 semantic_router.json 挂载（如果需要）
# 查看当前 volumeMounts 索引后，用 "op":"remove" 摘除

# 摘除占位 env
kubectl set env deployment/litellm -n litellm BEDROCK_API_KEY-

# 重启
kubectl rollout restart deployment/litellm -n litellm
```

---

## 9. 限制与后续

1. **LocalIndex 内存化** — HPA 扩容时每个新 Pod 冷启动会重新 embed utterances。若需持久化，需 fork semantic-router 用 PGVector/Redis Vector。
2. **只取 `messages[-1]` 做路由** — 长对话历史不影响路由决策。
3. **总 utterances ≤ 96**（Cohere Embed v4 batch 限制），扩类目时注意。
4. **Opus 4.7 只支持 inference profile** —（cross-region 的 `us.` 或 `global.` 前缀），在 us-west-2 没有 in-region 选项。
5. **auto 默认不支持 `thinking` 参数**（callback 会剥离）—— 需要 extended thinking 时直接用 `--model claude-opus-4-7` 或 `claude-sonnet-4-6`。
6. **非 Claude 模型的多轮会话需要 callback §3.3 (3) 保护** — 若客户端（如 Claude Code）会回放历史，历史中 Anthropic-风格的 `thinking` 块和空 `text` 块在 Bedrock Converse 的 Qwen/Kimi/GLM/DeepSeek endpoint 上会 400。已有 `_sanitize_history_for_non_claude` 清理，这也意味着非 Claude 模型看不到上一轮的 reasoning 痕迹。

---

## 10. 参考资料

1. [LiteLLM Auto Routing 官方文档](https://docs.litellm.ai/docs/proxy/auto_routing)
2. [LiteLLM Issue #25370 — auto_router multimodal content fix](https://github.com/BerriAI/litellm/pull/25370)
3. [Aurelio Labs semantic-router](https://github.com/aurelio-labs/semantic-router)
4. [AWS Bedrock Cohere Embed v4 model card](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-cohere-embed-v4.html)
5. [Claude Opus 4.7 Bedrock inference profile](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-opus-4-7.html)

**附件：** [`auto-model/litellm-config.yaml`](./auto-model/litellm-config.yaml) | [`auto-model/semantic_router.json`](./auto-model/semantic_router.json) | [`auto-model/custom_callbacks.py`](./auto-model/custom_callbacks.py) | [`bedrock-coding-models-findings.json`](./bedrock-coding-models-findings.json)
