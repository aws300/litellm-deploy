# LiteLLM API 文档（CloudNativeFormationLitellm 栈）

> 适用于 `CloudNativeFormationLitellm.yaml` 部署出的 LiteLLM **v1.106.6**（chart `litellm-helm 1.106.6`）。
> 文中实测数据来自 `us-west-1` 栈 `litellm-usw1`（2026-10-29）。

## 1. 入口：API 只走 Global Accelerator

| 入口 | Stack Output | 用途 | 模型调用 |
|---|---|---|---|
| **Global Accelerator** | `LiteLLMApiServer`，`https://<id>.dualstack.awsglobalaccelerator.com/` | **API 客户端（唯一入口）** | ✅ 需虚拟 key |
| CloudFront | `LiteLLMAdminUI`，`https://<id>.cloudfront.net/ui/` | 管理 UI、Cognito SSO 登录 | ❌ 一律 `403` |

两条链路都**没有公网负载均衡器**：

```
客户端 ──TLS──> Global Accelerator(任播 IP) ──TCP 443──> 内部 NLB ──> Envoy Gateway ──HTTPRoute litellm-ga──> LiteLLM
浏览器 ──TLS──> CloudFront ──VPC Origin(PrivateLink)──> 内部 ALB ──> Envoy Gateway ──HTTPRoute litellm-cf──> LiteLLM
```

- GA 的证书是 Envoy 上 Let's Encrypt 签发的 GA 域名证书（`ga-cert`），GA 只做 TCP 透传。
- Envoy 给每个请求打上 `X-LiteLLM-Edge`（`set`，客户端无法伪造）：GA 路由为 `global-accelerator`，CloudFront 路由为 `cloudfront`。
  LiteLLM 里的 `edge_policy.py` 拒绝所有带 `cloudfront` 标记（或带 CloudFront 源站头 `X-CloudFront-Secret`）的模型调用。
  判定用的是 LiteLLM 自己的 `RouteChecks.is_llm_api_route`，覆盖 OpenAI / Anthropic / Google 兼容路由、`/bedrock/*` 等透传路由、MCP、A2A、搜索，
  因此 `/chat/completions`、`/engines/{model}/chat/completions` 这类别名同样被拦截。
- 通过 CloudFront 仍可用：UI 页面、SSO、`GET /v1/models`、key / 用户 / 团队 / 花费等管理接口（UI 依赖它们）。UI 里的 Playground（调用 `/chat/completions`）在 CloudFront 上会报 403，这是预期行为；需要试模型请用 GA 端点。

### 1.1 CloudFront 缓存

只缓存 UI 静态内容，所有缓存键都包含 `Host`（每个域名一份缓存，不会把一个主机名的页面发给另一个主机名）：

| 路径（按顺序匹配） | 缓存策略 | TTL |
|---|---|---|
| `/ui/_next/static/*` | `<P><E>-ui-static`（键：Host + 压缩方式） | 最少 1 天，默认 30 天（文件名带内容哈希） |
| `/ui`、`/ui/*` | `<P><E>-ui-html`（键：Host + 压缩方式） | 默认 5 分钟，最多 1 小时，遵从源站 `Cache-Control` |
| `/v1/*` `/v2/*` `/chat/*` `/sso/*` `/key/*` `/user/*` `/team/*` `/model/*` `/spend/*` `/global/*` `/health*` `/.well-known/*` `/litellm/*` 及其他所有路径（默认行为） | 托管策略 `CachingDisabled` | 不缓存，转发全部请求头 / Cookie / 查询串（`AllViewer`） |

GA 没有缓存层（TCP 透传）。

## 2. 认证：只能用虚拟 key

| 凭据 | 能做什么 |
|---|---|
| **虚拟 key**（`sk-...`，在 UI 里创建） | 调用模型；受该 key 的模型范围、预算、速率限制约束，花费按 key / 团队统计 |
| **Master key**（Output `LiteLLMMasterKey`） | **只读**：`GET` 统计与信息类接口（`/model/info`、`/key/info`、`/spend/*`、`/global/*` 等）。调用模型、`/key/generate` 等写操作一律 `403`；也不能当 UI 密码登录（`disable_env_credential_login`） |
| 无凭据 | 只有 `GET /v1/models`、`GET /models`、健康检查 |

master key 只读由 `access_policy.py`（与 `base/scripts/litellm/access_policy.py` 逐字相同）实现：它包装了 LiteLLM 所有 HTTP / WebSocket / MCP 入口共用的认证函数，并在模型调用路径上再加一道 `async_pre_call_hook`。

### 2.1 创建虚拟 key

1. 浏览器打开 `LiteLLMAdminUI`，用 Cognito 账号登录（首个管理员：Output `CognitoAdminUsername` / `CognitoAdminPassword`；Cognito 组 `admin` 的成员是 `proxy_admin`）。
2. 左侧 **Virtual Keys** → **+ Create New Key**：
   - **Models**：留空 = 全部 11 个模型，或勾选子集；
   - **Max Budget (USD)** 与 **Reset Budget** 必填（`key_generation_settings` 要求每个团队 / 个人 key 带预算）。
3. 复制弹出的 `sk-...`（只显示一次）。

也可以用 UI 会话 key 或已有的管理员虚拟 key 调接口创建（必须发到 **GA**）：

```bash
curl -s https://$GA/key/generate -H "Authorization: Bearer $ADMIN_VIRTUAL_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"key_alias":"my-app","max_budget":50,"budget_duration":"30d","models":["claude-sonnet-5-5"]}'
```

以下示例统一使用：

```bash
export GA=<LiteLLMApiServer 的主机名，例如 a1b2c3.awsglobalaccelerator.com>
export LITELLM_KEY=sk-...        # 虚拟 key
```

## 3. 模型

与 `litellm-model-discovery`（`docker/litellm-model-discovery/configs/config.yaml`）为 base LiteLLM 选出的 Bedrock 模型完全相同：同名、同后端、同价格与能力（取自 base `/model/info`，2026-10-29）。模型列表固定在配置里（`store_model_in_db: false`），没有 `bedrock/*` 通配。

| 模型名 | 后端 | 原生 API | 上下文 输入 / 输出 | 价格 $/1M token 输入 / 输出 |
|---|---|---|---|---|
| `claude-opus-5-5` | `bedrock/invoke/global.anthropic.claude-opus-5-5` | Anthropic Messages（InvokeModel） | 1M / 128K | 4.00 / 20.00 |
| `claude-sonnet-5-5` | `bedrock/invoke/global.anthropic.claude-sonnet-5-5` | 同上 | 1M / 128K | 2.00 / 10.00 |
| `claude-haiku-5-5` | `bedrock/invoke/global.anthropic.claude-haiku-5-5` | 同上 | 1M / 128K | 0.10 / 0.50 |
| `gpt-6-astra` | `bedrock_mantle/openai.gpt-6-astra`（us-east-1） | OpenAI Responses | 922K / 128K | 11.00 / 55.00 |
| `gpt-6-sol` | `bedrock_mantle/openai.gpt-6-sol`（us-east-1） | 同上 | 922K / 128K | 2.20 / 11.00 |
| `gpt-6-luna` | `bedrock_mantle/openai.gpt-6-luna`（us-east-1） | 同上 | 922K / 128K | 0.11 / 0.55 |
| `gpt-6.1-sol` | `bedrock_mantle/openai.gpt-6.1-sol`（us-east-1） | 同上 | 1M / 131K | 2.20 / 11.00 |
| `gpt-6.1-terra` | `bedrock_mantle/openai.gpt-6.1-terra`（us-east-1） | 同上 | 922K / 128K | 1.10 / 5.50 |
| `glm-5.3` | `bedrock/converse/global.zai.glm-5.3` | Converse | 1M / 128K | 1.68 / 5.28 |
| `kimi-k3` | `bedrock/converse/global.moonshotai.kimi-k3` | Converse | 1M / 131K | 3.00 / 15.00 |
| `cohere.embed-v4` | `bedrock/global.cohere.embed-v4:0` | Embeddings | 128K | 0.12 / — |

- GPT-6 系列超过 272K 输入 token 后单价翻倍（输出 ×1.5），已写进各模型的 `*_above_272k_tokens` 价格。
- Claude 与 GLM 自动注入提示缓存断点（system 消息 + 最后一条消息，`cache_control_injection_points`），客户端无需改动；GPT-6 由 Responses API 原生缓存；Kimi K3 在 Bedrock 上不支持提示缓存。
- Bedrock 运行时 Region = 参数 `BedrockRegion`（默认 Stack 所在 Region，走 `global.*` 跨区推理配置文件）；GPT-6 = 参数 `BedrockMantleRegion`（默认 `us-east-1`）。
- 所有 OpenAI / Anthropic 兼容接口对所有模型可用，LiteLLM 负责格式转换（例如用 `/v1/chat/completions` 调 GPT-6，或用 `/v1/messages` 调 GLM）。

## 4. 接口

所有请求：`Authorization: Bearer $LITELLM_KEY`（Anthropic 风格的 `x-api-key: $LITELLM_KEY` 也可）。超时 600 秒（Envoy `requestTimeout` 与 LiteLLM `request_timeout`），支持 SSE 流式。

### 4.1 列出模型（无需 key）

```bash
curl -s https://$GA/v1/models | jq -r '.data[].id'
```

### 4.2 Chat Completions（OpenAI）

```bash
curl -s https://$GA/v1/chat/completions -H "Authorization: Bearer $LITELLM_KEY" \
  -H 'Content-Type: application/json' -d '{
    "model": "claude-sonnet-5-5",
    "messages": [{"role": "user", "content": "用一句话介绍 Amazon Bedrock"}],
    "max_tokens": 256,
    "stream": false
  }'
```

OpenAI SDK：

```python
from openai import OpenAI
client = OpenAI(base_url=f"https://{GA}/v1", api_key=LITELLM_KEY)
r = client.chat.completions.create(model="gpt-6-sol", messages=[{"role": "user", "content": "hi"}])
print(r.choices[0].message.content)
```

### 4.3 Responses（OpenAI）

```bash
curl -s https://$GA/v1/responses -H "Authorization: Bearer $LITELLM_KEY" \
  -H 'Content-Type: application/json' -d '{"model": "gpt-6-luna", "input": "hello"}'
```

### 4.4 Messages（Anthropic，Claude Code 可直接使用）

```bash
curl -s https://$GA/v1/messages -H "x-api-key: $LITELLM_KEY" -H 'anthropic-version: 2023-06-01' \
  -H 'Content-Type: application/json' -d '{
    "model": "claude-opus-5-5", "max_tokens": 512,
    "messages": [{"role": "user", "content": "hello"}]
  }'
```

Claude Code：

```bash
export ANTHROPIC_BASE_URL=https://$GA
export ANTHROPIC_AUTH_TOKEN=$LITELLM_KEY
export ANTHROPIC_MODEL=claude-opus-5-5
export ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-5-5
claude
```

### 4.5 Embeddings

```bash
curl -s https://$GA/v1/embeddings -H "Authorization: Bearer $LITELLM_KEY" \
  -H 'Content-Type: application/json' -d '{"model": "cohere.embed-v4", "input": ["hello", "world"]}'
```

### 4.6 key 自查

```bash
curl -s https://$GA/key/info -H "Authorization: Bearer $LITELLM_KEY"   # 预算、已花费、可用模型
```

## 5. 错误码

| 状态 | 场景 | 返回的 `error.message`（节选） |
|---|---|---|
| `401` | 没带 key、key 无效 / 过期 | `Authentication Error, No api key passed in.` |
| `403` | 用 master key 调模型或写接口 | `master key is read-only: model calls need a virtual key (...)` |
| `403` | 经 CloudFront 调模型（任何 key） | `model calls are not served through CloudFront (...). Call the Global Accelerator endpoint (stack output LiteLLMApiServer).` |
| `400` | key 预算用完 | `Budget has been exceeded! ...` |
| `401` | 模型不在 key 的允许范围 | `key not allowed to access model ...` |
| `429` | 超过 key / 团队的 RPM、TPM、并发限制 | `Rate limit exceeded ...` |

## 6. 运维要点

- **配置位置**：全部在模板里：`LiteLLMDeploy.Properties.LiteLLMValues`（Helm values，含 `proxy_config.model_list`）与 `K8sAppResources` 的 ConfigMap `litellm-policy`（两个策略模块）、HTTPRoute `litellm-cf` / `litellm-ga`。改完更新 Stack 即可；只改了 `litellm-policy` 时需要 `kubectl -n litellm rollout restart deploy/litellm`（Helm 只在自己的 config.yaml 变化时滚动 Pod）。
- **新增模型**：在 `model_list` 加一项。应与 `docker/litellm-model-discovery/configs/config.yaml` 的规则保持一致，否则两套 LiteLLM 的模型清单会分叉。
- **升级 LiteLLM**：`ChartVersion`、`image.tag` 一起改，然后跑 §7。两个策略模块 patch 了 LiteLLM 内部函数，内部变化时 Pod 会启动失败（而不是悄悄失效），属预期的"响亮失败"。
- **容量与稳定性**：每个 Pod `num_workers 4`，请求 2 CPU / 10Gi、上限 4 CPU / 10Gi（内存请求=上限，节点不超卖内存，不会因邻居被 OOM / 驱逐）；HPA `litellm-hpa` 只看 CPU（请求的 60%），最少 3、最多 30 副本，扩容 30 秒窗口（每分钟翻倍或 +4），缩容 10 分钟窗口、每 3 分钟最多减 1 个；PDB 最多同时中断 1 个；preStop 20 秒 + 优雅退出 660 秒（> 600 秒请求超时），缩容不会切断长流式请求。数据库连接：每 worker 10 个，30 副本共 1200，Aurora 上限 8 ACU。压测脚本：`./scripts/hpa-load-test.sh`。
- `values.yaml` 是同一套配置的独立 Helm 版本（不经 CloudFormation，部署到已有集群）。

## 7. 验证

```bash
LITELLM_KEY=sk-... ./scripts/e2e-test.sh --stack litellm-usw1 --region us-west-1
```

检查项：①VPC 内所有负载均衡器都是 `internal`，CloudFront 源站是 VPC Origin，GA 的终端节点是内部 NLB；②GA 健康检查与公开模型列表（正好 11 个）；③无 key → 401，master key 调模型 / 建 key → 403、不能登录 UI；④每个对话模型经 GA 调一次 `/v1/chat/completions`，外加 `/v1/messages`、`/v1/responses`、`/v1/embeddings`；⑤CloudFront 上 UI 与模型列表可用，`/v1/chat/completions`、`/chat/completions`、`/v1/messages`、`/v1/responses`、`/v1/embeddings`、`/bedrock/*` 全部 403（含伪造 `X-LiteLLM-Edge` 头）。
