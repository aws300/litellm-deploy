# Claude Code 接入 LiteLLM 代理使用文档

> **目标读者：** 想让 Claude Code CLI 通过我们的 LiteLLM 代理调用多家模型（Claude、Kimi、GLM、Qwen-Coder、DeepSeek、语义 Auto 路由）的开发者。
>
> **复现门槛：** 只需把 `ANTHROPIC_BASE_URL` 和 `ANTHROPIC_API_KEY` 换成你自己的代理地址和 virtual key，其它不用动。
>
> **前提：**
> - Claude Code CLI **≥ v2.1.111**（Opus 4.7 与 `xhigh` effort 支持）。`claude --version` 查看，`claude update` 升级。
> - LiteLLM 代理已按 [`litellm-auto-model-setup.md`](./litellm-auto-model-setup.md) 部署好，且 `/v1/models` 至少含：`auto`、`claude-opus-4-7`、`claude-sonnet-4-6`、`claude-haiku-4-5-20251001`、`kimi-k2.5`、`zai.glm-5`、`qwen3-coder-480b`、`deepseek-v3.2`，以及通配符 `bedrock/*`。

---

## 1. 替换两个变量

下面的所有配置里，只需要替换这两项：

```
ANTHROPIC_BASE_URL  = <你的 LiteLLM proxy URL，如 https://litellm.example.com>
ANTHROPIC_API_KEY   = <你的 LiteLLM virtual key 或 master key，形如 sk-xxx...>
```

本文档示例使用（按需替换）：

```bash
ANTHROPIC_BASE_URL=https://litellm.example.com
ANTHROPIC_API_KEY=sk-REPLACE_WITH_YOUR_LITELLM_VIRTUAL_KEY
```

---

## 2. 三种典型接入方式

按使用场景从简到繁排列。每种方式都能在 `/model` 里看到全部 8 个模型。

| 方式 | 适用场景 | 配置点 |
|------|---------|--------|
| A. Shell 环境变量 | 临时试用、CI 脚本 | `export ANTHROPIC_BASE_URL=... ANTHROPIC_API_KEY=...`，`claude` 启动即可 |
| B. `~/.claude/settings.json` (user) | 个人开发者常驻配置 | 把 `claude-code-settings.json` 合并进 user 级 settings |
| C. 项目 `.claude/settings.local.json` | 团队/单仓库、不污染其它项目 | 只在本仓库目录下生效 |

---

## 3. 方式 A — Shell 环境变量（最简）

适合快速试用。不会持久化，不会影响 `/model` 选择器的模型列表。

```bash
# 必须先 unset 第三方 provider 旗标，否则 Claude Code 会绕过 BASE_URL 直连云
unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY

export ANTHROPIC_BASE_URL=https://litellm.example.com
export ANTHROPIC_API_KEY=sk-REPLACE_WITH_YOUR_LITELLM_VIRTUAL_KEY

# 可选：让 Claude Code 的后台小任务也走 Haiku（总结工具输出、生成标题等）
export ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5-20251001

# 启动 Claude Code
claude
```

启动后：

```
> /model
```

选择器会列出 `default / opus / sonnet / haiku` 四个内置别名（解析为 LiteLLM 上的 Claude 模型）。要切到非 Claude 模型，需要用 **方式 B 或 C** 在 `availableModels` 里列出。或者启动时直接 `claude --model kimi-k2.5`（Claude Code **不校验** 模型名称，直接透传给 `ANTHROPIC_BASE_URL`）。

---

## 4. 方式 B — 用户级 `~/.claude/settings.json`（推荐个人使用）

一次配置，全局生效。`/model` 选择器里会同时列出全部 8 个模型 + 语义 Auto 路由。

### 4.1 settings.json 完整内容

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://litellm.example.com",
    "ANTHROPIC_API_KEY": "sk-REPLACE_WITH_YOUR_LITELLM_VIRTUAL_KEY",

    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-7",
    "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME": "Opus 4.7 (LiteLLM)",
    "ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION": "Anthropic Opus 4.7 via LiteLLM -> Bedrock global inference profile",
    "ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES": "effort,xhigh_effort,max_effort,thinking,adaptive_thinking,interleaved_thinking",

    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-6",
    "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME": "Sonnet 4.6 (LiteLLM)",
    "ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION": "Anthropic Sonnet 4.6 via LiteLLM -> Bedrock global inference profile",
    "ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES": "effort,max_effort,thinking,adaptive_thinking,interleaved_thinking",

    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-4-5-20251001",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME": "Haiku 4.5 (LiteLLM)",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION": "Anthropic Haiku 4.5 via LiteLLM -> Bedrock global inference profile",

    "ANTHROPIC_CUSTOM_MODEL_OPTION": "auto",
    "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME": "Auto (semantic router)",
    "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION": "LiteLLM semantic router: routes by embedding similarity across Haiku / Qwen-Coder / Sonnet 4.6 / Opus 4.7"
  },
  "availableModels": [
    "default",
    "auto",
    "opus",
    "sonnet",
    "haiku",
    "claude-opus-4-7",
    "claude-sonnet-4-6",
    "claude-haiku-4-5-20251001",
    "kimi-k2.5",
    "zai.glm-5",
    "deepseek-v3.2",
    "qwen3-coder-480b",
    "bedrock/us.deepseek.r1-v1:0"
  ]
}
```

### 4.2 放置位置

| OS | 路径 |
|----|------|
| macOS / Linux | `~/.claude/settings.json` |
| Windows | `%USERPROFILE%\.claude\settings.json`（即 `C:\Users\<you>\.claude\settings.json`）|

### 4.3 合并到已有 settings（不要直接覆盖）

如果你已经有 `~/.claude/settings.json`（含 hooks、permissions、statusLine 等），必须合并，不要 `cp` 覆盖：

**macOS / Linux：**

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.bak 2>/dev/null || true
mkdir -p ~/.claude

# 用 jq 深合并（第二个文件覆盖第一个的同名 key）
jq -s '.[0] * .[1]' ~/.claude/settings.json claude-code-settings.json \
  > ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json
```

**Windows PowerShell：**

```powershell
$target = "$env:USERPROFILE\.claude\settings.json"
Copy-Item $target "$target.bak" -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude" | Out-Null

# 如果没装 jq，用 PowerShell 原生合并
$old = if (Test-Path $target) { Get-Content $target | ConvertFrom-Json } else { @{} }
$new = Get-Content claude-code-settings.json | ConvertFrom-Json
foreach ($p in $new.PSObject.Properties) {
  $old | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
}
$old | ConvertTo-Json -Depth 10 | Set-Content $target
```

> **安全提示：** API key 以明文写入 user settings 会被本机任何进程读到。生产上建议用 [`apiKeyHelper`](https://code.claude.com/docs/en/settings#apikeyhelper) 指向取值脚本（从 keychain / 1Password / AWS Secrets Manager 取），而不是直接 `env.ANTHROPIC_API_KEY`。

### 4.4 验证

```bash
claude /model
```

picker 底部会出现 **Auto (semantic router)** 自定义项；`availableModels` 里列出的全部 8 个模型也会可见。

---

## 5. 方式 C — 项目 `.claude/settings.local.json`（团队/单仓库）

只在当前项目目录下生效，不影响其它项目。Claude Code 会自动把这个文件加入 `.gitignore`，适合放个人 API key。

```bash
mkdir -p .claude
cp claude-code-settings.json .claude/settings.local.json
# 或直接手写 .claude/settings.local.json，内容同 §4.1
```

切到其它项目目录后这份配置自动失效。

---

## 6. 在 `/model` 里选模型

三种等价方式（任一即可）：

| 动作 | 命令 |
|------|------|
| 交互式 picker | `/model` 回车，方向键选择 |
| 直接切换 | `/model kimi-k2.5`、`/model opus`、`/model auto` |
| 启动时指定 | `claude --model qwen3-coder-480b` |

模型对应关系（按本文档配置）：

| picker 里显示 | 实际调用的 LiteLLM 模型 | 典型场景 |
|---------------|------------------------|---------|
| **Default** | 账号订阅默认模型 | 不推荐，容易忽略路由 |
| **Auto (semantic router)** | `auto` → 按语义路由到 4 档之一 | 日常通用首选 |
| **opus / Opus 4.7 (LiteLLM)** | `claude-opus-4-7` | 架构设计、长链路任务 |
| **sonnet / Sonnet 4.6 (LiteLLM)** | `claude-sonnet-4-6` | 代码评审、调试 |
| **haiku / Haiku 4.5 (LiteLLM)** | `claude-haiku-4-5-20251001` | 快速 Q&A、简单任务 |
| **kimi-k2.5** | `bedrock/moonshotai.kimi-k2.5` | 长文本、开源替代 |
| **zai.glm-5** | `bedrock/zai.glm-5` | 国产开源替代 |
| **qwen3-coder-480b** | `bedrock/qwen.qwen3-coder-480b-a35b-v1:0` | 便宜的代码生成 |
| **deepseek-v3.2** | `bedrock/deepseek.v3.2` | Aider-Polyglot 强项 |
| **bedrock/us.deepseek.r1-v1:0** | 同 ID（走 `bedrock/*` 透传）| R1 推理模型 |

---

## 7. 非交互模式（print 模式）

提供了 `auto-model/claude-code-auto.sh` 脚本。

### 7.1 脚本用法

```bash
# 基本：默认用 auto 语义路由，JSON 输出
./claude-code-auto.sh "write a python function to reverse a linked list"

# 强制某个模型
./claude-code-auto.sh -m claude-opus-4-7 "design a distributed payment system"
./claude-code-auto.sh -m kimi-k2.5        "总结这篇长文..."
./claude-code-auto.sh -m qwen3-coder-480b "generate a fastapi endpoint"

# 纯文本输出（不走 jq）
./claude-code-auto.sh --text "你好"

# 从 stdin 读提示
echo "review this PR for security issues" | ./claude-code-auto.sh --text

# 流式 JSON 输出
./claude-code-auto.sh --stream "hi"

# 帮助
./claude-code-auto.sh -h
```

### 7.2 脚本关键要点（用户角度只看这几行）

```bash
# === 替换这两行就能复现 ===
export ANTHROPIC_API_KEY="sk-REPLACE_WITH_YOUR_LITELLM_VIRTUAL_KEY"
export ANTHROPIC_BASE_URL="https://litellm.example.com"

# === 下面这些是必须保留的防呆逻辑 ===
unset CLAUDE_CODE_USE_BEDROCK      # 否则 Claude Code 绕过 BASE_URL 直连 Bedrock
unset CLAUDE_CODE_USE_VERTEX
unset CLAUDE_CODE_USE_FOUNDRY
```

脚本会自动加载同目录下的 `claude-code-settings.json`（如存在），所以 `/model` picker 配置同时生效。

### 7.3 脚本内部调用的 CLI

```bash
claude \
  -p                                    # 非交互 print 模式
  --model <auto|kimi-k2.5|...>          # 任何 LiteLLM 已注册的 model_name 都行
  --output-format json                  # text | json | stream-json
  --max-turns 20                        # 防呆：限制 agent loop
  --permission-mode bypassPermissions   # 脚本里不弹权限确认
  --settings ./claude-code-settings.json  # 加载 picker allowlist
  "your prompt here"
```

---

## 8. 常见问题排查

### 8.1 `API Error: 400 The provided model identifier is invalid`

**原因：** Claude Code 2.x 启动时**会**做一次预飞行，如果发现 `CLAUDE_CODE_USE_BEDROCK=1`，它会绕过 `ANTHROPIC_BASE_URL` 直连 Bedrock，用的是 AWS 认证而非我们的 virtual key，自然 `auto` 这种自定义 model 不存在。

**修复：** 启动前执行 `unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY`。脚本已包含。

可以用 `claude auth status` 核实：输出里 `"apiProvider": "anthropic"` 表示正走 `ANTHROPIC_BASE_URL`；如果是 `"bedrock"` 就说明上面那个环境变量污染了。

### 8.2 `API Error: 400 {"error":... "adaptive thinking is not supported on this model"...}`

**原因：** Claude Code 默认对 Opus/Sonnet 加 `thinking` 字段；路由到非 Claude 模型时 Bedrock 拒收。

**修复：** LiteLLM 侧的 `custom_callbacks.py` 已经处理（非 Claude 目标自动剥离）。如果你看到此错，说明 proxy 侧没部署 §3.3 的 callback。

### 8.3 `/model` 里看不到某个模型

**原因：** `availableModels` 是 allowlist，未列出的模型会被隐藏。

**修复：** 在 settings.json 的 `availableModels` 数组里把它加进去。注意**允许任意字符串**，不限于 Claude 模型。

### 8.4 Auto 路由总是跑到 Haiku

**原因：** 提示过短（2-5 字）；或代理侧 `custom_callbacks.py` 没有剥离 `<system-reminder>` 块导致系统提示淹没真实 prompt。

**修复：** 确认 proxy 侧 callback 是最新版（会过滤 `<system-reminder>`）；或提示多打几个字（> 10 字符）。

### 8.5 Claude Code 卡住不输出

**原因：** `CLAUDE_CODE_USE_BEDROCK=1` 污染导致 Claude Code 尝试走 Bedrock；或代理侧 `auto` 注册失败。

**诊断：**

```bash
claude -p --debug api --model auto --permission-mode bypassPermissions --max-turns 1 "hi" 2>&1 | tail -30
```

看 `[API REQUEST]` 的 URL：应当是你的 `ANTHROPIC_BASE_URL`，而不是 `bedrock-runtime.*.amazonaws.com` 或 `api.anthropic.com`。

### 8.6 Claude Code 抱怨 `401 invalid x-api-key` 访问 `api.anthropic.com/api/claude_code/organizations/metrics_enabled`

**原因：** Claude Code 会去 anthropic.com 查帐号 metrics 开关，用的是你的 `ANTHROPIC_API_KEY`。proxy 的 virtual key 在 anthropic.com 自然无效，会报 401。

**影响：** 仅 warning，不影响实际功能。可以无视，或设置 `export DISABLE_TELEMETRY=1`。

---

## 9. 效果核查（可选）

想确认 auto 路由是否按语义工作：

```bash
# 临时获取 master key 看 spend logs
MK=<your LiteLLM master key or admin virtual key>
BASE=https://litellm.example.com

# 记录起点
START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# 用脚本跑 4 种提示
./claude-code-auto.sh --text --max-turns 2 "你好" &
./claude-code-auto.sh --text --max-turns 2 "write a one-line python lambda that squares a number" &
./claude-code-auto.sh --text --max-turns 2 "find the bug: def divide(a,b): return a/b" &
./claude-code-auto.sh --text --max-turns 2 "design a distributed payment system" &
wait
sleep 10

# 看实际被路由到哪个底层模型
curl -sS "$BASE/spend/logs?limit=40" -H "Authorization: Bearer $MK" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
entries = d if isinstance(d, list) else d.get('data', [])
entries = [e for e in entries if (e.get('startTime') or '') >= '$START']
# 过滤掉 5K+ tokens 的 prompt-cache 预热
entries = [e for e in entries if (e.get('total_tokens') or 0) < 5000]
for e in sorted(entries, key=lambda e: e.get('startTime','')):
    print(f\"  {e.get('startTime','')[11:19]}  {e.get('model','').split('/')[-1]:50s}  tokens={e.get('total_tokens')}\")
"
```

预期输出示例：

```
  08:43:01  claude-haiku-4-5-20251001-v1:0                      tokens=230
  08:43:05  qwen.qwen3-coder-480b-a35b-v1:0                     tokens=212
  08:43:11  claude-sonnet-4-6                                   tokens=260
  08:43:13  claude-opus-4-7                                     tokens=320
```

---

## 10. 参考资料

1. [Claude Code Model Configuration 官方文档](https://code.claude.com/docs/en/model-config)
2. [Claude Code Settings 官方文档（settings.json 字段）](https://code.claude.com/docs/en/settings)
3. [Claude Code Environment Variables](https://code.claude.com/docs/en/env-vars)
4. [LiteLLM Auto Routing 文档](https://docs.litellm.ai/docs/proxy/auto_routing)

**附件（本仓库）：**
- [`auto-model/claude-code-settings.json`](./auto-model/claude-code-settings.json) — 直接用于 `~/.claude/settings.json`
- [`auto-model/claude-code-auto.sh`](./auto-model/claude-code-auto.sh) — `-p` 模式运行脚本
- [`litellm-auto-model-setup.md`](./litellm-auto-model-setup.md) — 配套的 proxy 端部署文档
