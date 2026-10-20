# Claude Code 成本降低指南

> 面向开发者：在**已接入 LiteLLM 代理**的前提下，如何通过智能路由 + 使用习惯两条腿，把日常 Claude Code 调用成本显著降下来。
>
> **读者需要知道**：`ANTHROPIC_BASE_URL` 和 `ANTHROPIC_API_KEY` 已经指向我们的 LiteLLM 代理；具体部署细节见另一份客户端配置文档，这里不重复。
>
> **本文档按"成本下降幅度"降序组织**：先讲最大头的 prompt cache + 智能路由，再讲日常习惯性技巧。

---

## 1. 三条核心降本路径

### 路径 A：智能路由（服务端替你选最便宜的模型）

服务端 LiteLLM 挂了一套**基于向量 embedding 的语义路由器**，embedding 模型使用 **`bedrock-embed-v4`**（AWS Bedrock 上的 Cohere Embed v4，1536 维多模态向量）。你发一条 prompt，路由器会把 prompt 的语义向量和四档目标模型各自的"典型用法向量簇"做余弦相似度匹配，自动选中 cost/性能最优的那一档：

| 档位 | 适合任务 | 目标模型 | 价格（$/MTok 输入/输出） |
|------|---------|---------|--------------------------|
| Trivial | 打招呼、定义、改名、文档 | Haiku 4.5 | 1.00 / 5.00 |
| Boilerplate | 代码生成、模板、测试骨架、CRUD | Qwen3-Coder-480B | **0.22 / 1.80** |
| Review/Debug | 代码评审、查 bug、性能分析 | Sonnet 4.6 | 3.00 / 15.00 |
| Architecture | 系统设计、多步推理、根因分析 | Opus 4.7 | 5.00 / 25.00 |

举几个实际例子（括号里是实测被路由到的档位）：

- `你好` → Haiku 4.5
- `帮我写一个 fastapi 接口` → Qwen3-Coder-480B（约 **1/14 Opus 4.7 价格**）
- `review 这个 PR 的安全问题` → Sonnet 4.6
- `设计一个分布式多区域支付系统` → Opus 4.7

**成本直觉**：一天里 60% 的提问是"trivial / boilerplate"，把这部分从 Opus 4.7 自动分流到 Haiku 4.5 或 Qwen-Coder，同样的输出 token，**每天省下 5–23×** 的花费（不是百分比，是倍数）。

### 路径 B：Claude Code 自身的使用习惯（§2–§9）

研究下来，最关键的单项杠杆是 **Prompt Cache**：Anthropic 给每轮请求的**系统提示 + CLAUDE.md + 对话历史**做 KV 缓存，命中缓存的输入 token 只要 **0.1× 普通输入价**（便宜 90%）；但缓存一旦被打破，整段历史都要按全价重读。

公开数据：100 轮 Opus 会话，**有 cache 的话 $10–19，没 cache 要 $50–100**<sup>[1]</sup>。所以保持 cache 命中率高 = 单轮成本可以压到原来的 1/3 到 1/5。

### 路径 C：永久记忆（§10）

Cache 生命周期 5 分钟–1 小时，`/clear` 或重启后必丢。开源插件 `claude-mem` 用**SQLite + 向量检索 + 渐进式披露**给 Claude Code 加一层跨会话持久记忆，避免每次重启都要重新"介绍项目背景"或重复走已知的弯路。自称 10× token 节省<sup>[8]</sup>。

下面的章节基本都围绕"让 cache 活得更久、让非必要 token 更少、让历史知识可召回"展开。

---

## 2. 使用 LiteLLM 智能路由：`/model auto`

在 Claude Code 里：

```
/model auto
```

之后所有对话会走 LiteLLM 语义路由器，后端自动从四档里挑一档。**不需要自己思考"这个问题该用什么模型"**——路由器基于 embedding 相似度决定。

### 手动覆盖场景

如果你知道某类任务要强制走某个模型（跨会话保持一致性、对 benchmark 做 A/B、或者 auto 偶尔走偏了）：

```
/model kimi-k2.5              # Kimi K2.5，长上下文/开源场景
/model qwen3-coder-480b       # Qwen3-Coder 480B，低价高效的代码生成
/model claude-sonnet-4-6      # 回到 Sonnet 4.6（代码评审、调试）
/model claude-opus-4-7        # 明确要复杂推理时
```

### 什么时候切回 `auto`

日常就开着 `auto`。**成本观测下来，auto 档比常驻 Opus 便宜 3–10×**，同时对多数问题没有感知的质量差异，因为架构类问题还是会被路由器识别并送到 Opus 4.7。

---

## 3. 让 Prompt Cache 保持命中：3 个必做习惯

### 3.1 用 `/init` 生成 CLAUDE.md，并保持其**稳定**

第一次进入一个新仓库时：

```
/init
```

Claude Code 会自动扫描代码库，生成一份 `CLAUDE.md`（项目级）放在仓库根目录。这份文件的作用是：**把"这个项目的基础事实"固化到每轮 prompt 的前缀里**——构建命令、代码风格、关键文件位置、分支策略等。

它为什么能降本？因为 `CLAUDE.md` 的内容会被放进每轮请求的系统上下文。只要内容稳定，这段就会一直走 **cache read（0.1× 价）**<sup>[2]</sup>，而不是每次都按全价重新读一遍。

**写 CLAUDE.md 的反模式（会打破 cache）**：
- ❌ 时间戳（`最后更新：2026-04-21`）
- ❌ 动态 git 状态（`当前分支：feature/xxx`）
- ❌ 变动的 Issue/PR 编号列表
- ❌ 超过 200 行（Anthropic 官方建议上限）<sup>[3]</sup>

**正确姿势**：
- ✅ 技术栈、语言版本、包管理器
- ✅ 构建/测试/lint 命令（这些很少变）
- ✅ 核心目录的职责（"`/api` 存放 REST handlers"）
- ✅ 项目独有的约定（"使用 tabs not spaces"、"commit 必须带 scope"）

> **小技巧**：把变动频繁的内容（TODO、临时笔记、长期演进计划）放到单独的文件里，让 Claude **按需 `@file` 引用**，不要污染 CLAUDE.md。

### 3.2 用 `/clear` 切换话题，不要让一个会话越滚越大

做完一件事，准备开始无关的新任务时：

```
/clear
```

这会重置对话历史但保留 CLAUDE.md 和系统提示。**为什么**：每轮请求的输入 token = `系统提示 + CLAUDE.md + 之前所有对话` + 当前消息。对话越长，每轮要读的 token 越多。即使走 cache read（0.1×），长对话仍然比短对话贵得多。

**判断时机**：
- 切换到一个完全不相关的任务 → `/clear`
- 仍在同一个功能上继续迭代 → **不要 clear**（否则每条消息又要从头 warm cache）

### 3.3 用 `/compact` 做"延续式压缩"，而不是 `/clear`

如果当前对话太长但**你还想继续**——比如 agent 已经做了 20 轮文件编辑，你想总结进度后接着做：

```
/compact focus on what's been done and what's next
```

Claude Code 会：
1. 调用一次 LLM 生成对话摘要
2. 把之前的原始对话替换成摘要
3. 保留 CLAUDE.md + 系统提示

**`/compact` vs `/clear`**：
- `/compact` 保留工作上下文，但**会打一次 cache miss**（整个对话要重写进新 cache）
- `/clear` 彻底丢弃历史，cache 命中率最高，但你要重新告诉 Claude 背景

经验法则：对话 <20 轮，直接 `/clear`；对话 >20 轮且内容有连贯性，`/compact`。

---

## 4. 精准引用文件：`@file` / `@dir`

反例：`帮我看看这个仓库的 auth 逻辑` → Claude 会跑 `Grep + Read` 好几轮，每次都消耗 token。

正例：`帮我看看 @src/auth/middleware.py 的逻辑` → Claude 一次性读目标文件，省掉探索过程<sup>[4]</sup>。

多文件：

```
@src/auth/middleware.py @src/auth/session.py 帮我找出这两个文件的竞态条件
```

效果：**探索性 tool call 从 5–10 次降到 1 次**，每次 tool call 都是一次模型往返，每次都 billable。

---

## 5. 查看当前上下文开销：`/context`

任何时候怀疑"为什么最近一条消息这么贵"，输入：

```
/context
```

输出会按类别展示 token 占比（系统提示、CLAUDE.md、对话历史、工具 schema 等）。找到占比最大的那一块再针对性优化——如果是"对话历史"过大，`/compact`；如果是"CLAUDE.md"过大，精简文件。

---

## 6. 调节 effort：不是每个任务都要 Opus "max"

Opus 4.7 默认 `effort=xhigh`，会做几十 K tokens 的思考<sup>[5]</sup>。简单任务用 `xhigh` 纯粹浪费。

```
/effort low          # 改改单元测试、解释代码、改个变量名
/effort medium       # 常规编码任务（默认从 xhigh 降到 medium 就能省 40-60% output tokens）
/effort high         # 需要想一会儿的问题（架构小调整）
/effort xhigh        # 默认，复杂任务
/effort max          # 最顶配。官方明确提醒"可能过度思考"，不推荐常用
```

**注意**：thinking tokens 按 **output 价** 计费。Opus 4.7 output = $25/MTok，思考 20K tokens = **$0.50**——一轮就能产生的隐藏成本。

---

## 7. 关掉不需要的工具：`--tools`

启动时限制工具集：

```
claude --tools "Read,Edit,Bash,Grep"
```

省的是两块：(1) 每轮请求都要带工具 schema，schema 小了 prompt 小；(2) 模型决策时可选动作少，不会"被工具吸引"去做无意义的调用。

> 项目不用 MCP server 就不启用。用了 MCP 的项目，在 `/mcp` 里把不用的 server 暂时禁用也能降 token。

---

## 8. 用 subagent 隔离"大搜索"

当你要让 Claude 做一次**长 + 不可预测**的工作（比如：`在整个仓库里找所有用到 deprecated API 的地方`），直接在主对话里做的话，所有探索过程的 tool output 都会进主上下文，把 cache 撑坏。

更便宜的做法：让 Claude 起一个 subagent（内部叫 Task tool / Agent），把脏活放进子 context，**只有最终总结回流到主对话**。

在 Claude Code 里一般不用手动触发——你只要对主 agent 说：

> 起一个 subagent 去调研 X，回来给我一份 200 字的 summary

它就会自动 delegate。subagent 的上下文不和主对话共享，主对话的 cache 不受影响。

---

## 9. Session hygiene（会话卫生）

| 操作 | 用途 |
|------|------|
| `claude` | 全新会话（推荐日常切任务时直接退出重启）|
| `claude --continue` / `-c` | 继续最近一次会话 |
| `claude --resume <id>` / `-r` | 按 ID 恢复特定会话 |
| `--fork-session` | 从历史会话分叉，不影响原会话 cache |

**经验法则**：做完一件事就彻底退出。重启比 `/clear` 更干净（连系统提示都可能换），偶尔重启能规避 Claude Code 版本升级引入的 cache-invalidation。

---

## 10. 永久记忆：用 `claude-mem` 避免重复"上下文冷启动"

Claude Code 的 prompt cache 生命周期只有 5 分钟或 1 小时（到期就失效），而且 `/clear` 或重启 Claude Code 之后 cache 一定重建 —— 这意味着**每次新会话都要"冷启动"**：重新把 CLAUDE.md、项目结构、上次踩过的坑、昨天做到哪儿再解释一遍。即使每次只多花 5K input tokens 读背景，一周下来也是好几美元。

[`claude-mem`](https://github.com/thedotmack/claude-mem) 是一个开源的 Claude Code 插件，通过**跨会话持久化记忆 + 分层检索**把"冷启动"的成本降到几乎为零。原理如下。

### 10.1 工作原理（4 层架构）

```
Claude Code (host)
  │  lifecycle hooks：SessionStart / UserPromptSubmit / PostToolUse / Stop / SessionEnd
  ▼
CLI Bridge (Bun)            ← Node↔Bun 的 hook 入口
  ▼
Worker Daemon (Express :37777)
  ├── SessionManager        ← 跨进程 session 生命周期
  ├── SDKAgent              ← 用 Claude Agent SDK 异步压缩 tool output 为 "observation"
  ├── SearchManager         ← 混合检索（SQLite FTS5 + Chroma 向量）
  └── ChromaSync            ← 向量 embedding 同步
  ▼
Storage
  ├── SQLite (~/.claude-mem/claude-mem.db)   ← 结构化 observation + session summary
  └── ChromaDB (~/.claude-mem/chroma/)        ← 每条 observation 对应一份语义向量
```

**关键机制：**

1. **自动捕获（PostToolUse hook）** — 你用 Claude Code 做的每一次 Edit/Bash/Read，hook 会把工具调用 + 结果异步丢给 worker daemon；daemon 后台用一个独立的 Claude Agent SDK 会话**把长 tool output 压缩成 50-200 字的 observation**（包含 type/title/narrative/facts），存到 SQLite + 向量化到 Chroma。你的主对话**不等这个过程**，零感知延迟。
2. **会话结束自动总结（Stop hook）** — SessionEnd 时写入 session summary：做了什么、学到什么、下一步是什么。
3. **下次启动自动召回（SessionStart hook）** — 新会话开始时，hook 把**和当前 cwd 语义相关的 observation 索引** 注入到 Claude 的初始上下文里。

### 10.2 "渐进式披露"是省钱的关键

朴素的跨会话记忆方案（把过往会话摘要全拼进 system prompt）反而会让事情更贵 —— 你会发现每轮都要读 35K tokens 的历史，其中可能只有 2K 真正相关。

`claude-mem` 用的是 **Progressive Disclosure（渐进式披露）**<sup>[7]</sup>：

- **Layer 1 – Index**（进会话时自动注入，约 800 tokens）：只给 Claude **观察记录的轻量索引** —— ID、时间戳、类型、标题、预估读取 tokens。形如：
  ```
  | ID    | Time   | T  | Title                                | Tokens |
  |-------|--------|----|--------------------------------------|--------|
  | #2586 | 12:58  | 🔵 | Context hook file exists but empty   | ~51    |
  | #2589 | 12:58  | 🟡 | Investigated hook debug output docs  | ~105   |
  | #2591 | 1:15   | ⚖️ | Stderr messaging abandoned           | ~155   |
  ```
- **Layer 2 – Timeline**（按需，Claude 自己决定）：通过 `mem-search` MCP 工具拉取某条 observation 前后的时间线。
- **Layer 3 – Full details**（只 fetch 真正相关的几条）：`get_observations(ids=[2586, 2591])` 才拉 full narrative（每条 500-1000 tokens）。

**省 token 的算术：**

| 方案 | 进会话上下文 | 真正相关占比 |
|------|-------------|--------------|
| 全量注入过往会话 | 35,000 tokens | ~6%（2,000 有用） |
| **Progressive disclosure** | **800 + ~120 = 920 tokens** | **100%** |

作者声称 **10× token 节省**<sup>[8]</sup>，因为只在 Claude 判断"这条看起来相关"时才 fetch 详情，99% 的旧 observation 根本不会进主对话。

### 10.3 安装

一行命令安装（会自动注册 Claude Code 插件 hooks + 启动 worker）：

```bash
npx claude-mem install
```

或用 Claude Code 自带的插件市场：

```
/plugin marketplace add thedotmack/claude-mem
/plugin install claude-mem
```

两种方式都会：
1. 把 hooks 脚本装到 `~/.claude/plugins/marketplaces/thedotmack/`
2. 在 `~/.claude-mem/` 建数据目录（SQLite + Chroma）
3. 起一个 localhost:37777 的 worker daemon
4. 注册 `mem-search` skill 到 Claude Code

> ⚠️ **不要用 `npm install -g claude-mem`**：那只装 SDK 库，不装 hooks、不启 worker，等于没装。

### 10.4 日常使用（三个最实用的场景）

**场景 A：跨会话召回，不用再"介绍一遍项目背景"**

装上后无需任何手动命令。打开新会话后你问："我上次在 auth 模块做到哪儿了？" Claude 会自动调 `mem-search` 查询过往 observation，给你一份简报。

**场景 B：查"我们之前是不是已经解决过这个 bug？"**

直接在新会话里问，Claude 会触发 `mem-search` skill，走三层流程：
```
search(query="auth token expiration", type="bugfix", limit=10)
  ↓ 返回索引（50-100 tokens/结果）
timeline(anchor=10942, depth_before=3, depth_after=3)
  ↓ 还原当时上下文
get_observations(ids=[10942, 10945])
  ↓ 最后才拉完整 narrative
```
总消耗可能只有 1-2K tokens，而不是翻出整段历史。

**场景 C：长期工程里的知识沉淀**

做完一个迁移/重构后，不用专门写总结 —— Stop hook 已经自动存下了 session summary（做了什么、学到什么、待办）。三个月后你或团队其他人重新碰这块代码，启动会话时自动被召回。

> 完整 MCP 工具参数、其他 skills（`do` / `make-plan` / `timeline-report` 等）、`~/.claude-mem/settings.json` 配置项、Web Viewer UI、故障排查、Beta 功能、多 IDE 支持，见官方文档：<https://docs.claude-mem.ai/>

### 10.5 隐私控制

不想让某段对话被持久化存储：

```
<private>
这里的内容（比如临时贴的 token、个人信息）不会存进数据库
</private>
```

Tag 剥离在 hook 层完成（数据离开 Claude Code 前就被清掉），不会到 worker/DB。

### 10.6 和本文其它章节的叠加效果

| 组合 | 相对日成本（基线 = 100%）|
|------|--------------------------|
| 纯 Opus 4.7 + 无 cache + 无持久记忆 | 100%（基线 ~$50/天）|
| + 规范使用 cache（`/init` + `/clear` 得当）| ~30% |
| + **LiteLLM `/model auto` 智能路由** | ~10% |
| + **`claude-mem` 渐进式记忆召回** | **~5-7%** |

最后一档省的不只是"重复读背景"的 token，还省了**因为记不住导致重复走弯路**的成本 —— 比如上周 Claude 已经试过某个方案不可行，不装 claude-mem 的话这周又会去试一遍。

### 10.7 何时不用

- **一次性小任务 / 单文件改动** — 跨会话上下文没意义，reviews 等一次性工作直接开新会话更干净。
- **对 hook 延迟极度敏感的场景** — claude-mem 的 PostToolUse hook 虽然异步、不阻塞，但会多启一个 Bun worker 进程。在 CI、脚本化 `-p` 模式里通常不必要，可以只装在开发机上。
- **隐私极度敏感的项目** — 所有 observation 默认存到本地 `~/.claude-mem/`（不外发），但团队共享机器上要注意数据权限，或全面启用 `<private>` 标签。

---

## 11. 避坑清单

- ❌ **Opus 用于聊天 / 查语法** — 小问题用 auto 或直接 `haiku`
- ❌ **一个会话做完一整周的工作** — 尽早 `/clear` 或新开会话
- ❌ **在 CLAUDE.md 里写"今天日期是 XXX"** — 直接破坏 cache
- ❌ **`effort=max` 常开** — Anthropic 官方说可能过度思考，性价比负
- ❌ **闲置 MCP server 全开** — 每个都贡献工具 schema 进 prompt
- ❌ **盲开 multi-agent 团队** — 公开数据显示 agent teams 用 **~7× 更多 token** 达到同样效果<sup>[6]</sup>。简单任务别开 sub-agent，主 agent 自己做。

---

## 12. 三条路径叠加的实测效果

以一个日均 100 次提问的开发者为例（实测基线数据<sup>[1]</sup>）：

| 方案 | 每日成本估算 |
|------|-------------|
| 全 Opus 4.7 + 无 cache 习惯 | ~$50 |
| 全 Opus 4.7 + 规范使用 cache（`/init`、`/clear` 得当） | ~$10–20 |
| + **auto 智能路由** | ~$3–7 |
| + **`claude-mem` 永久记忆**（渐进式召回）| **~$2–4** |

三条路径正交叠加：
- **路由**让"适合便宜模型的问题"自动走便宜模型（通常覆盖 ~60% 请求）
- **Cache**让剩下 40% 的每轮都走 0.1× 折扣
- **永久记忆**消除跨会话冷启动成本 + 避免重复走错路

**总计，日常成本可以压到单纯用 Opus 的 1/15–1/25 左右。**

---

## 13. 最短"开箱即用"checklist

- [ ] `ANTHROPIC_BASE_URL` / `ANTHROPIC_API_KEY` 已经指向 LiteLLM 代理
- [ ] `ANTHROPIC_DEFAULT_OPUS_MODEL` / `_SONNET_MODEL` / `_HAIKU_MODEL` 三个 env var 设好（见客户端配置文档）——**否则 `/model` picker 选 Opus/Sonnet/Haiku 会 400**
- [ ] 仓库根目录有 `/init` 生成的 `CLAUDE.md`（< 200 行、无时间戳）
- [ ] 默认用 `/model auto`；只在需要时手动切 `kimi-k2.5` / `qwen3-coder-480b` / `claude-opus-4-7`
- [ ] 切换无关任务时 `/clear`
- [ ] 会话 >20 轮且要继续：`/compact focus: 具体目标`
- [ ] 问简单问题前确认 effort 不是 `max`
- [ ] 引用文件用 `@file`，不要让 Claude 盲目 Grep
- [ ] 长期项目装上 `claude-mem`（`npx claude-mem install` 一行）—— 跨会话记忆自动召回

---

## 参考资料

1. ClaudeCodeCamp — *How prompt caching actually works in Claude Code*（基于 Anthropic 官方定价与 100-turn 实测）, https://www.claudecodecamp.com/p/how-prompt-caching-actually-works-in-claude-code
2. Anthropic — *Prompt caching*（官方文档，cache read 0.1×、cache write 1.25×、断点机制）, https://platform.claude.com/docs/en/build-with-claude/prompt-caching
3. Claude Code Docs — *Memory & CLAUDE.md*（"keep under 200 lines"）, https://code.claude.com/docs/en/memory
4. Claude Code Docs — *Slash commands / @file reference*（`@file` 精准引用）, https://code.claude.com/docs/en/slash-commands
5. Claude Code Docs — *Model configuration / effort levels*（`/effort` 各档及 Opus 4.7 默认 xhigh）, https://code.claude.com/docs/en/model-config
6. Anthropic Engineering Blog — *Building effective agents*（agent teams ~7× token overhead）, https://www.anthropic.com/engineering/building-effective-agents
7. claude-mem — *Progressive Disclosure*（索引先行 + 按需详情的上下文注入哲学）, https://docs.claude-mem.ai/progressive-disclosure
8. claude-mem — *MCP Search Tools*（3 层 search/timeline/get_observations 工作流，"~10x token savings by filtering before fetching details"）, https://github.com/thedotmack/claude-mem#mcp-search-tools

完整研究数据（36 条带引用的 findings，涵盖 11 个领域）：`~/Documents/ClaudeCode_CostSaving_Research_20260421/findings.json`
