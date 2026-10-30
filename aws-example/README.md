# aws-example：在 LiteLLM 中接入 AWS 生态

把四项 AWS 能力接入 `CloudNativeFormationLitellm.yaml` 部署出的 LiteLLM（v1.106.6），所有对象统一命名 `aws-example`。

| # | LiteLLM 功能 | AWS 服务 | 脚本 | 调用方式（经 GA 或 CloudFront 域名，虚拟 key） |
|---|---|---|---|---|
| 1 | Guardrails | Amazon Bedrock Guardrails | `10-guardrail.sh` | 请求里加 `"guardrails": ["aws-example"]`，或在 UI 绑定到 key / 团队 |
| 2 | Agents → New Agent（Bedrock AgentCore） | Amazon Bedrock AgentCore Runtime | `20-agentcore-agent.sh` | `POST /a2a/aws-example`（A2A JSON-RPC） |
| 3 | Search Tools | Web Search on Amazon Bedrock（AgentCore Gateway 托管连接器） | `30-web-search.sh` | `POST /v1/search/aws-example` |
| 4 | Vector Stores | Amazon S3 Vectors | `40-s3-vectors.sh` | `POST /v1/vector_stores/<id>/search`，或聊天请求带 `file_search` |

`00-iam.sh` 给 LiteLLM 的 Pod 角色加权限，`test.sh` 端到端验证四项能力，`cleanup.sh` 全部删除。

已在 `us-east-1` 的栈 `litellm-use1` 上实测通过（2026-10-30，`test.sh` 9/9）。

---

## 0. 前置条件

1. **已部署好的栈**：`CloudNativeFormationLitellm.yaml` 部署完成，且模板里 `general_settings` 带有
   `store_model_in_db: true` + `supported_db_objects`（2026-10-30 起的模板已包含）。
   没有这一项时，通过 API / UI 创建的护栏、Agent、向量库**只会出现在处理该请求的那一个 Pod 上**，其余副本悄悄跳过（见 §6 坑 1）。
2. **本机工具**：`aws`（v2，能访问栈所在账号与 Region）、`jq`、`curl`、`pip`、`zip`。不需要 Docker。
3. **Region**：Web Search 只在 `us-east-1` 与 `us-west-2` 提供；栈在其他 Region 时，给 `30-web-search.sh` 设 `WEB_SEARCH_REGION=us-east-1`。
   Bedrock Guardrails、AgentCore Runtime、S3 Vectors 请先在 [AWS Regional Services](https://aws.amazon.com/about-aws/global-infrastructure/regional-product-services/) 确认目标 Region 可用。
4. **管理员虚拟 key（`LITELLM_ADMIN_KEY`）**：建护栏、搜索工具需要 proxy_admin 身份。
   - 浏览器打开 Stack Output `A3AdminUI`，用 Cognito 管理员（Output `CognitoAdminUsername` / `CognitoAdminPassword`，Cognito 组 `admin`）登录；
   - **Virtual Keys → + Create New Key**，Owned by 选 **You**（必须属于你这个管理员用户），填预算 → Create，复制 `sk-...`。
   - 没有归属用户的 key（"service account"）调这些管理接口会得到 `401 Only proxy admin can be used ...`；master key 在本栈是只读的，同样不行。
   - **用 kubectl 直接生成（无需打开浏览器）**：`export LITELLM_ADMIN_KEY=$(./get-admin-key.sh)`。脚本在 LiteLLM Pod 里用 LiteLLM 自己的建 key 函数，
     直接写数据库，为第一个 proxy_admin 用户创建 key（默认预算 $20 / 30 天）。前提：kubectl 指向栈的集群，且 Cognito 管理员**至少登录过一次 UI**
     （首次登录才会建出 proxy_admin 用户）。用完可在 UI 的 Virtual Keys 里删除。
5. **测试 key（`LITELLM_KEY`）**：任意普通虚拟 key 即可（也可以直接用管理员 key）。

所有脚本从栈的 Outputs 读取地址，默认 `STACK=litellm-use1 REGION=us-east-1`，换环境只需覆盖这两个变量：

```bash
cd litellm/aws-example
export STACK=litellm-use1 REGION=us-east-1
export LITELLM_ADMIN_KEY=sk-...      # 管理员拥有的虚拟 key
```

## 快速开始

```bash
./00-iam.sh                 # Pod 角色加内联策略 aws-example（几秒内生效，无需重启）
./10-guardrail.sh           # Bedrock 护栏 → LiteLLM guardrail
./20-agentcore-agent.sh     # 打包并部署 AgentCore Runtime → LiteLLM agent（约 3 分钟）
./30-web-search.sh          # AgentCore Gateway + web-search 连接器 → LiteLLM search tool
./40-s3-vectors.sh          # S3 Vectors 桶 + 索引 → LiteLLM vector store，并导入 sample/
LITELLM_KEY=sk-... ./test.sh
```

每个脚本都可重复执行（已存在则复用 / 更新，不会重复创建）。下面逐项说明脚本做了什么、等价的 UI 操作和调用示例。

```bash
export GA=$(aws cloudformation describe-stacks --region $REGION --stack-name $STACK \
  --query "Stacks[0].Outputs[?OutputKey=='A1ApiUrlGlobalAccelerator'].OutputValue" --output text)
export LITELLM_KEY=sk-...
```

---

## 0.5 IAM：`00-iam.sh`

LiteLLM 调用所有 AWS 服务都用栈的 Pod 角色（Output `PodRoleArn`，经 EKS Pod Identity 绑定到 `litellm/litellm-sa`）。模板只给了它调用 Bedrock 模型的权限，脚本在旁边加一条内联策略 `aws-example`（不改模板，栈更新不会覆盖它）：

| Sid | 动作 | 资源 |
|---|---|---|
| `BedrockGuardrail` | `bedrock:ApplyGuardrail`、`bedrock:GetGuardrail` | 本账号的 guardrail |
| `AgentCoreRuntime` | `bedrock-agentcore:InvokeAgentRuntime`（+`ForUser`） | `runtime/aws_example*` |
| `AgentCoreGateway` | `bedrock-agentcore:InvokeGateway` | `gateway/aws-example*` |
| `S3Vectors` | `s3vectors:QueryVectors / GetVectors / PutVectors / ListVectors / GetIndex / CreateIndex ...` | `bucket/litellm-aws-example-*` |

## 1. Bedrock Guardrails：`10-guardrail.sh`

**AWS 侧**：创建护栏 `aws-example` 并发布一个编号版本（LiteLLM 不用 `DRAFT`）：

- 内容过滤：仇恨、侮辱、色情、暴力、不当行为（输入 / 输出 HIGH），提示词攻击（输入 HIGH）；
- 拒绝话题 `investment-advice`（个性化投资建议）；
- 敏感信息：邮箱、电话**匿名化**（`{EMAIL}`、`{PHONE}`），银行卡号、美国 SSN、AWS Secret Key **拦截**。

再次执行只在策略变化时发布新版本，并把 LiteLLM 里的护栏指向它。

**LiteLLM 侧**（`POST /guardrails`，存数据库，所有 Pod 30 秒内加载）：

```json
{"guardrail": {"guardrail_name": "aws-example",
  "litellm_params": {"guardrail": "bedrock", "mode": ["pre_call", "post_call"], "default_on": false,
    "guardrailIdentifier": "<id>", "guardrailVersion": "<n>", "aws_region_name": "us-east-1",
    "mask_request_content": true, "mask_response_content": true}}}
```

等价 UI：**Guardrails → + Add New Guardrail → Provider: Amazon Bedrock**，填 Guardrail ID / Version / Region，Mode 选 `pre_call` + `post_call`。

`default_on: false`：只有显式启用的请求才过护栏，不影响其他流量。启用方式二选一：

```bash
# 单个请求启用
curl -s https://$GA/v1/chat/completions -H "Authorization: Bearer $LITELLM_KEY" -H 'Content-Type: application/json' -d '{
  "model": "claude-haiku-5-5", "guardrails": ["aws-example"],
  "messages": [{"role": "user", "content": "Should I put my savings into bitcoin?"}]}'
# -> 400 {"error": {"message": "Violated guardrail policy", ... "bedrock_guardrail_response":
#         "Sorry, this request is not allowed by the aws-example guardrail.", ... "investment-advice" ...}}
```

或者在 UI 里给某个 key / 团队绑定这个护栏（**Virtual Keys / Teams → 编辑 → Guardrails**），该 key 的所有请求都会强制过护栏。

实测：普通问题 200；投资建议 400（6/6）；`my email is jane.doe@example.com` 回复为 `my email is {EMAIL}`。

## 2. Bedrock AgentCore Agent：`20-agentcore-agent.sh`

**AWS 侧**：

1. 打包 `agent/`：Strands Agent（Claude Haiku 5.5，`global.anthropic.claude-haiku-5-5`）+ 两个工具 `utc_now`、`aws_doc_url`。
   用 AgentCore **直接代码部署**（不用 Docker）：`pip install --platform manylinux2014_aarch64 --python-version 3.13 --only-binary=:all: --no-compile`，
   加上 `main.py` 打成 zip（约 29 MB），上传到 S3 桶 `aws-example-<账号>-<Region>`；
2. 执行角色 `aws-example-agentcore-runtime`：调用 Bedrock 模型、写 CloudWatch Logs / X-Ray / 指标、读 S3 里的代码；
3. AgentCore Runtime `aws_example`（运行时名字不允许 `-`），`PYTHON_3_13`、入口 `main.py`、公网网络模式，等到 `READY`。再次执行会发布新版本。
4. 在 LiteLLM 注册 agent（下方）；5. 给 agent 绑定一个虚拟 key，Agents 页面状态才会从 Needs Setup 变成 Active（见下文）。

**LiteLLM 侧**（`POST /v1/agents`，与 UI **Agents → + New Agent → Bedrock AgentCore** 表单写入的内容相同）：

```json
{"agent_name": "aws-example",
 "litellm_params": {"custom_llm_provider": "bedrock",
                    "model": "bedrock/agentcore/arn:aws:bedrock-agentcore:us-east-1:<账号>:runtime/aws_example-XXXX",
                    "aws_region_name": "us-east-1"},
 "agent_card_params": {"name": "aws-example", "description": "...", "url": "...", "capabilities": {"streaming": true}, "skills": [...]}}
```

**调用**（A2A JSON-RPC）：

```bash
curl -s https://$GA/a2a/aws-example -H "Authorization: Bearer $LITELLM_KEY" -H 'Content-Type: application/json' -d '{
  "jsonrpc": "2.0", "id": "1", "method": "message/send",
  "params": {"message": {"role": "user", "messageId": "m1",
             "parts": [{"kind": "text", "text": "What time is it in UTC? Also give me the s3vectors docs link."}]}}}'
# -> {"jsonrpc":"2.0","id":"1","result":{"kind":"message","role":"agent","parts":[{"kind":"text",
#     "text":"The current time in UTC is 2026-10-30 03:30:50 UTC. ... https://docs.aws.amazon.com/s3vectors/"}]}}
```

- 流式：`"method": "message/stream"`，返回 SSE；Agent 卡片：`GET /a2a/aws-example/.well-known/agent-card.json`。
- **agent 代码必须同时处理两种 payload**（见 `agent/main.py` 的说明）：经 `/a2a/...` 调用时 LiteLLM 把 **A2A JSON-RPC 信封原样转发**给 AgentCore，并期待 JSON-RPC 响应；
  以模型 `bedrock/agentcore/<ARN>` 走 `/v1/chat/completions` 时则发送 `{"prompt": "..."}`、读取 `{"result": "..."}`。只写了 `prompt` 分支的 agent 在 Agents 页面里会报 `424 Failed Dependency`。
- 日志：CloudWatch 日志组 `/aws/bedrock-agentcore/runtimes/aws_example-XXXX-DEFAULT`。
- **Agents 页面的状态 Needs Setup → Active**：UI 只看这个 agent 有没有绑定虚拟 key（key 的 `agent_id` = 该 agent）或配置了 JWT；没有就显示 Needs Setup，但**不影响调用**。
  脚本第 5 步会创建绑定 key `aws-example-agent`（预算 $10 / 30 天），状态随即变成 Active。手动方式：Agents → 选中 agent → 创建 key，或
  `POST /key/generate {"key_alias": "aws-example-agent", "agent_id": "<agent_id>", "max_budget": 10, "budget_duration": "30d"}`。
  这个 key 是 agent 自己在 LiteLLM 上的身份：agent 经 LiteLLM 调用模型 / 工具时，花费和预算记在 agent 名下。本例 agent 直接调 Bedrock，所以只创建、不下发给运行时。

## 3. Web Search on Amazon Bedrock：`30-web-search.sh`

**AWS 侧**：

1. 网关角色 `aws-example-websearch-gateway`（AgentCore 代入；`InvokeGateway` + `InvokeWebSearch`，资源为 AWS 托管工具 `arn:aws:bedrock-agentcore:<region>:aws:tool/web-search.v1`）；
2. AgentCore Gateway `aws-example-websearch`（MCP 协议、`AWS_IAM` 鉴权）+ 目标 `web-search-tool`（托管连接器 `web-search` 1.1.0）。
   目标名决定 MCP 工具名 `web-search-tool___WebSearch`，正好是 LiteLLM 的默认值，所以**不需要设 `AGENTCORE_SEARCH_TOOL_NAME`**；用别的目标名时要把这个环境变量设成 `<目标名>___WebSearch`。

**LiteLLM 侧**（`POST /search_tools`，等价 UI：**Search Tools → + Add Search Tool → Provider: agentcore**）：

```json
{"search_tool": {"search_tool_name": "aws-example",
  "litellm_params": {"search_provider": "agentcore", "api_base": "https://aws-example-websearch-XXXX.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp",
                     "timeout": 60, "max_retries": 1}}}
```

LiteLLM 用 Pod 角色对网关做 SigV4 签名（签名 Region 从网关 URL 推导）。

```bash
curl -s https://$GA/v1/search/aws-example -H "Authorization: Bearer $LITELLM_KEY" -H 'Content-Type: application/json' \
  -d '{"query": "Amazon S3 Vectors general availability", "max_results": 3}' | jq '.results[] | {title, url}'
```

返回 Perplexity Search API 形状（`results[].title / url / snippet`），费用由 AgentCore Gateway 计费，LiteLLM 侧记 $0。

## 4. Amazon S3 Vectors：`40-s3-vectors.sh`

**AWS 侧**：向量桶 `litellm-aws-example-<账号>-<Region>` + 索引 `aws-example`：`float32`、**1536 维**（Cohere Embed v4 的默认输出）、余弦距离，
元数据键 `source_text` 设为不可过滤（LiteLLM 把分块原文存在这里）。

**LiteLLM 侧**（`POST /vector_store/new`，等价 UI：**Vector Stores → + Add Vector Store → Provider: S3 Vectors**）：

```json
{"vector_store_id": "litellm-aws-example-<账号>-us-east-1:aws-example", "custom_llm_provider": "s3_vectors", "vector_store_name": "aws-example",
 "litellm_params": {"vector_bucket_name": "litellm-aws-example-<账号>-us-east-1", "index_name": "aws-example",
                    "aws_region_name": "us-east-1", "litellm_embedding_model": "cohere.embed-v4"}}
```

**导入文档**（LiteLLM 的 RAG 管道：分块 → `cohere.embed-v4` 向量化 → `PutVectors`）：

```bash
curl -s https://$GA/v1/rag/ingest -H "Authorization: Bearer $LITELLM_ADMIN_KEY" \
  -F 'file=@sample/aws-example-faq.md;type=text/markdown' \
  --form-string 'request={"ingest_options": {
     "vector_store": {"custom_llm_provider": "s3_vectors", "vector_store_id": "<桶>:aws-example",
                      "vector_bucket_name": "<桶>", "index_name": "aws-example", "aws_region_name": "us-east-1",
                      "dimension": 1536, "litellm_embedding_model": "cohere.embed-v4"},
     "embedding": {"model": "cohere.embed-v4"},
     "chunking_strategy": {"chunk_size": 800, "chunk_overlap": 100}}}'
```

不带参数运行脚本时只在索引为空时导入 `sample/`；`./40-s3-vectors.sh a.md b.pdf` 会追加导入指定文件（同一文件导入两次会存两份）。

**检索**：

```bash
ID=litellm-aws-example-<账号>-us-east-1:aws-example
curl -s https://$GA/v1/vector_stores/$ID/search -H "Authorization: Bearer $LITELLM_KEY" -H 'Content-Type: application/json' \
  -d '{"query": "Which tools does the AgentCore agent have?", "max_num_results": 2}' | jq '.data[] | {score, text: .content[0].text}'
```

**在聊天里做 RAG**：请求带 `tools: [{"type": "file_search", "vector_store_ids": ["<ID>"]}]`（或顶层 `vector_store_ids`），
LiteLLM 先检索再把结果拼进上下文：

```bash
curl -s https://$GA/v1/chat/completions -H "Authorization: Bearer $LITELLM_KEY" -H 'Content-Type: application/json' -d "{
  \"model\": \"kimi-k3\", \"tools\": [{\"type\": \"file_search\", \"vector_store_ids\": [\"$ID\"]}],
  \"messages\": [{\"role\": \"user\", \"content\": \"How many dimensions does the aws-example index have?\"}]}"
# -> "The aws-example S3 Vectors index has 1536 dimensions ..."
```

> ⚠️ 这一步对 `kimi-k3`、`gpt-6-*` 有效；对 `claude-*-5-5`、`glm-5.3` **无效**（见 §6 坑 6）。对这些模型请先调 `/v1/vector_stores/<id>/search`，再把结果放进消息。

## 5. 验证：`test.sh`

```bash
LITELLM_KEY=sk-... ./test.sh
```

```
==> 1. Bedrock Guardrails (aws-example)
  ok   normal prompt passes
  ok   denied topic blocked 6/6 (400, topic investment-advice)
  ok   e-mail anonymised: my email is {EMAIL}
==> 2. Bedrock AgentCore agent (aws-example)
  ok   agent card: aws-example -> https://<cf-domain>/a2a/aws-example
  ok   message/send (tool utc_now): 2026-10-30
  ok   message/stream: "text": "Hello there, friend!"
==> 3. Web Search on Amazon Bedrock (aws-example)
  ok   3 results, first: Amazon S3 Vectors now generally available with increased scale and performance
==> 4. Amazon S3 Vectors (litellm-aws-example-<账号>-us-east-1:aws-example)
  ok   search finds the agent section (score 0.418)
  ok   chat + file_search answers from the store: 1536
==> result: 9 passed, 0 failed
```

拒绝话题连发 6 次，确保所有副本（默认 3 个，HPA 可扩）都已从数据库加载护栏。

## 6. 踩过的坑（v1.106.6，2026-10-30 实测）

1. **`store_model_in_db: false` 时只有搜索工具和 MCP 会同步到所有 Pod**。护栏、Agent、向量库只在创建请求落到的那一个 Pod 生效：
   护栏表现为"有时拦截、有时不拦"（实测 1/6）。模板已改为 `store_model_in_db: true` + `supported_db_objects`（不含 `models`，模型目录仍由模板固定）。
2. **`GET /guardrails/list` 只返回 config.yaml 里的护栏**，数据库里的要用 `GET /v2/guardrails/list`，否则脚本以为不存在、每次重复创建。
3. **A2A 调用 AgentCore 时 payload 是 JSON-RPC 信封**，不是 `{"prompt"}`（§2）。
4. **AgentCore 直接代码部署拒绝本机 Python 编译的 `.pyc`**（`Your artifact contains Python cache files that are incompatible with the target runtime`）：
   `pip --no-compile` 并删除 `__pycache__`。创建失败（`CREATE_FAILED`）的 runtime 不能更新，只能删掉重建（脚本会自动处理）。
5. **S3 向量桶名不能以 `aws` 开头**（`The requested bucket name is reserved`），而且与通用 S3 桶共用命名空间，所以向量桶叫 `litellm-aws-example-...`。
6. **聊天 RAG 与提示缓存注入互斥**：LiteLLM 每次调用只运行一个 prompt 集成，带 `cache_control_injection_points` 的模型（本栈的 Claude ×3、GLM）
   优先走缓存注入，`file_search` / `vector_store_ids` 被忽略或报错（`Unsupported tool type: file_search`、`vector_store_ids: Extra inputs are not permitted`）。
7. **`/v1/rag/ingest` 的 multipart 字段叫 `request`**，内容是整个 JSON 请求体 `{"ingest_options": ...}`；用 `curl --form-string`，`-F` 会解析 JSON 里的 `;` 和引号。
8. **没有归属用户的虚拟 key 不是管理员**：管理接口要用"Owned by: You"的管理员 key（§0）。

## 7. 费用与清理

| 资源 | 计费 |
|---|---|
| Bedrock Guardrails | 按处理的文本单元计费（只对启用了护栏的请求） |
| AgentCore Runtime | 只在会话活跃时按 vCPU / 内存秒计费，空闲不收费 |
| AgentCore Gateway + Web Search | 按调用计费 |
| S3 Vectors | 按存储量 + 查询 / 写入计费，样例数据量可忽略 |
| S3 代码桶 | 约 30 MB / 版本 |

```bash
./cleanup.sh --dry-run    # 先看会删什么
./cleanup.sh              # 先删 LiteLLM 对象，再删 AWS 资源，最后删 IAM
```

只删除 `aws-example` 相关对象，不动 CloudFormation 栈。

## 文件

```
aws-example/
├── README.md               本文
├── lib.sh                  公共函数：读栈 Outputs、调用 LiteLLM 管理接口
├── get-admin-key.sh        用 kubectl 生成管理员虚拟 key
├── 00-iam.sh               Pod 角色内联策略
├── 10-guardrail.sh         Bedrock Guardrails
├── 20-agentcore-agent.sh   AgentCore Runtime agent
├── agent/main.py           agent 代码（Strands + bedrock-agentcore，同时支持 A2A 与 prompt）
├── agent/requirements.txt
├── 30-web-search.sh        Web Search on Amazon Bedrock
├── 40-s3-vectors.sh        Amazon S3 Vectors
├── sample/aws-example-faq.md   导入向量库的样例文档
├── test.sh                 端到端验证
└── cleanup.sh              清理（支持 --dry-run）
```
