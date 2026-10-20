# Adaptive Thinking Fix — Claude Code `/model auto` 在 LiteLLM 上 400 报错

**日期**: 2026-05-09
**影响范围**: 集群 `litellm/litellm` 部署（镜像 `ghcr.io/berriai/litellm-database:main-v1.83.14-stable.patch.3`）
**报错信息**: `API Error: 400 {"error":{"message":"{\"message\":\"adaptive thinking is not supported on this model\"}. Received Model Group=auto\nAvailable Model Group Fallbacks=None","type":"None","param":"None","code":"400"}}`
**状态**: ✅ 已修复并通过回归测试

---

## 1. 现象

用户在 Claude Code 中执行 `/model auto`，然后发任何消息都会立即收到 `400 Bad Request: adaptive thinking is not supported on this model`。

该错误来自集群内 LiteLLM 代理，并由下游 AWS Bedrock 直接返回。

## 2. 背景组件

| 组件 | 版本 / 位置 |
|---|---|
| LiteLLM Proxy | `v1.83.14-stable.patch.3` |
| Helm chart | `litellm-helm-1.82.3` |
| Namespace / Release | `litellm / litellm` |
| Auto Router 目标模型 | Haiku 4.5 / Qwen3-Coder-480B / Claude Sonnet 4-6 / Claude Opus 4-7（见 `semantic_router.json`） |
| Pre-call Hook | `litellm-custom-callbacks` ConfigMap → `custom_callbacks.py` |

`auto` 这个 model group 在 `litellm-config` 中被声明为：

```yaml
- model_name: auto
  litellm_params:
    model: auto_router/coding_auto_v1
    auto_router_config_path: /etc/litellm/semantic_router.json
    auto_router_default_model: claude-haiku-4-5-20251001
    auto_router_embedding_model: bedrock-embed-v4
```

## 3. 根因链路（三层叠加）

### 3.1 客户端：Claude Code `/model auto` 发送 `thinking.type=adaptive`

当用户在 Claude Code 里选择 `/model auto`，客户端会在每次 `POST /v1/messages` 的 body 顶层附带：

```json
{
  "model": "auto",
  "messages": [...],
  "thinking": {"type": "adaptive"}
}
```

`type=adaptive` 是 Anthropic 新引入的"自适应思考"模式 —— 让模型自主决定是否进入 extended-thinking。

### 3.2 Bedrock 侧：仅 Sonnet 4.5+ / Opus 4.5+ 支持 `adaptive`

Bedrock 的 Anthropic provider 只接受 `thinking.type` 为 `"adaptive" | "enabled" | "disabled"`。**但并非所有 Claude 模型都实际支持 `adaptive`**：

| 模型 | `enabled` | `adaptive` |
|---|---|---|
| Claude Sonnet 4.5 / 4.6 / 4.7 | ✅ | ✅ |
| Claude Opus 4.5 / 4.6 / 4.7 | ✅ | ✅ |
| **Claude Haiku 4.5** | ✅ | ❌ → `400 adaptive thinking is not supported on this model` |

### 3.3 LiteLLM 语义路由：`"hi"` 命中 Haiku

`semantic_router.json` 把寒暄/简短问题（"hi", "你好", "what is a for loop" 等）路由到 cheap/fast 层的 `claude-haiku-4-5-20251001`。因此 Claude Code 发的 `hi` + `thinking.type=adaptive` → 路由到 Haiku 4.5 → Bedrock 400。

### 3.4 为什么原 pre-call hook 没有拦住 `thinking`？

集群中已经部署了 `ProxyPreCallFixups.async_pre_call_hook`，其设计意图就是：在 auto-router 入口 `_scrub(data, ["thinking", "adaptive_thinking"])`。但它**实际完全没生效**。

通过在 hook 中加临时诊断日志，确认了 `data` 顶层存在 `thinking: {"type":"adaptive"}` 且 `_is_auto_router("auto") == True`。原代码本该 pop 掉它。真正的 bug：

- LiteLLM 把完整请求体存在 `data["proxy_server_request"]["body"]`；
- 该 `body` 内又存在对 `data` / `proxy_server_request` 的**循环引用**；
- 原 `_scrub` 函数**无深度、无 visited set、无白名单保护**地递归；
- 触碰循环引用 → `RecursionError`；
- 被外层 `except Exception: pass` **静默吞掉**；
- 结果：`thinking` 从未被移除，原样透传到 Bedrock。

```python
# 有 bug 的原版
def _scrub(obj, drop_keys):
    if isinstance(obj, dict):
        for k in list(obj.keys()):
            if k in drop_keys:
                obj.pop(k, None)
            else:
                _scrub(obj[k], drop_keys)   # ← 递归进入 proxy_server_request 触发死循环
    elif isinstance(obj, list):
        for item in obj:
            _scrub(item, drop_keys)
```

## 4. 修复

### 4.1 修改文件

- `custom_callbacks.py`（集群 ConfigMap `litellm/litellm-custom-callbacks`，源文件 `auto-model/custom_callbacks.py`）

### 4.2 修改内容

**（a）为 `_scrub` 加循环保护 + 元信息键白名单**

```python
_SKIP_RECURSE_KEYS = frozenset({
    "proxy_server_request", "litellm_logging_obj", "litellm_metadata",
    "metadata", "litellm_params", "secret_fields",
    "user_api_key_auth", "user_api_key_dict",
})

def _scrub(obj, drop_keys, _seen=None):
    if _seen is None:
        _seen = set()
    oid = id(obj)
    if oid in _seen:
        return
    if isinstance(obj, (dict, list)):
        _seen.add(oid)
    if isinstance(obj, dict):
        for k in list(obj.keys()):
            if k in drop_keys:
                obj.pop(k, None)
                continue
            if k in _SKIP_RECURSE_KEYS:   # 绝不递归进入元信息容器
                continue
            _scrub(obj[k], drop_keys, _seen)
    elif isinstance(obj, list):
        for item in obj:
            _scrub(item, drop_keys, _seen)
```

**（b）浅层 pop `proxy_server_request.body` 上的相同字段**

某些 passthrough 代码路径会回读 `proxy_server_request.body`。浅层扫一次确保两处一致：

```python
def _scrub_body_aliases(data, drop_keys):
    if not isinstance(data, dict):
        return
    psr = data.get("proxy_server_request")
    if isinstance(psr, dict):
        body = psr.get("body")
        if isinstance(body, dict):
            for k in drop_keys:
                body.pop(k, None)
```

**（c）防御性降级 `thinking.type=adaptive|auto`**

即使前两步漏掉（如未来 LiteLLM 重命名字段），auto-router 入口仍主动剔除 `adaptive` 类型：

```python
def _downgrade_adaptive_thinking(data):
    def _maybe_drop(container):
        if not isinstance(container, dict):
            return
        th = container.get("thinking")
        if isinstance(th, dict) and th.get("type") in ("adaptive", "auto"):
            container.pop("thinking", None)
    _maybe_drop(data)
    if isinstance(data, dict):
        psr = data.get("proxy_server_request")
        if isinstance(psr, dict):
            _maybe_drop(psr.get("body"))
```

**（d）Hook 编排**

```python
async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
    try:
        model = data.get("model") or ""

        _scrub(data, ALWAYS_DROP_KEYS)
        _scrub_body_aliases(data, ALWAYS_DROP_KEYS)

        if not _is_claude_model(model) or _is_auto_router(model):
            _scrub(data, CLAUDE_ONLY_KEYS)
            _scrub_body_aliases(data, CLAUDE_ONLY_KEYS)

        if _is_auto_router(model):
            _downgrade_adaptive_thinking(data)

        if not _is_claude_model(model) or _is_auto_router(model):
            _sanitize_history_for_non_claude(data.get("messages"))

        if _is_auto_router(model):
            msgs = data.get("messages")
            if isinstance(msgs, list):
                for m in msgs:
                    if isinstance(m, dict) and "content" in m:
                        m["content"] = _flatten_routing_text(m["content"])
    except Exception:
        pass
    return data
```

完整源码见同目录 `auto-model/custom_callbacks.py`。

### 4.3 部署步骤

```bash
# 1. 更新 ConfigMap（从仓库源文件）
kubectl create cm litellm-custom-callbacks -n litellm \
  --from-file=custom_callbacks.py=./docs/litellm/auto-model/custom_callbacks.py \
  --dry-run=client -o yaml | kubectl apply -f -

# 2. 滚动重启
kubectl rollout restart deployment/litellm -n litellm
kubectl rollout status deployment/litellm -n litellm --timeout=120s
```

## 5. 验证（回归测试矩阵）

从集群内通过 port-forward 直接发 `/v1/messages`：

| # | 请求体关键字段 | 预期 | 修复前 | 修复后 |
|---|---|---|---|---|
| 1 | `model=auto` + `thinking={type:adaptive}` | 200 正常回复 | 400 `adaptive thinking is not supported` | ✅ `"Hey, what's up!"` |
| 2 | `model=auto`（无 thinking） | 200 正常回复 | 200 正常 | ✅ 保持正常 |
| 3 | `model=claude-sonnet-4-6` + `thinking={type:enabled, budget_tokens:1024}` | 200 含 `thinking` block | 200 正常 | ✅ 返回 thinking block + 答案 |

测试命令（示例 1）：

```bash
MASTER_KEY=$(kubectl get secret litellm-masterkey -n litellm \
  -o jsonpath='{.data.masterkey}' | base64 -d)

kubectl port-forward -n litellm svc/litellm 14000:4000 &

curl -sS -X POST http://localhost:14000/v1/messages \
  -H "x-api-key: $MASTER_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "auto",
    "max_tokens": 128,
    "messages": [{"role":"user","content":"hi"}],
    "thinking": {"type": "adaptive"}
  }'
```

## 6. 相关经验（值得沉淀）

1. **永远不要对 `data` dict 做无限制递归**。LiteLLM 的 `data` 字典会挂 `proxy_server_request.body` 回指自己，所有递归工具必须带 visited set 或显式白名单。
2. **`except Exception: pass` 会掩盖真实错误**。类似 pre-call hook 的安全包裹建议至少写成 `except Exception as e: logger.exception(...)` 以便线上暴露异常；诊断阶段更要把 `data` 关键字段 dump 出来。
3. **确认 hook 的适用范围**。`CustomLogger.async_pre_call_hook` 对 `/v1/chat/completions`、`/embeddings`、`/image/generation` 和 `/v1/messages` (anthropic pass-through) 都会被调用 —— 这是通过 `common_request_processing.base_process_llm_request` 统一分发的。但：**hook 在 `data` 层面的修改，必须也同步到 `proxy_server_request.body`**，否则部分 passthrough 实现会回读原始 body。
4. **Bedrock Anthropic provider 的 thinking 支持是分模型的**。不要假定所有 `claude-4-*` 都接受 `adaptive`。未来如果把 auto router 的 cheap 层换成更新的 Haiku，可以重新测试是否还需要降级。

## 7. 相关文件

- 仓库源：`docs/litellm/auto-model/custom_callbacks.py`（已同步修复）
- 集群 ConfigMap：`kubectl get cm litellm-custom-callbacks -n litellm -o yaml`
- 路由配置：`docs/litellm/auto-model/semantic_router.json`
- LiteLLM 主配置：`docs/litellm/auto-model/litellm-config.yaml`
- 相关设计文档：`docs/litellm/litellm-auto-model-setup.md`
