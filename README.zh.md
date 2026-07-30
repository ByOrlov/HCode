# HCode — 即使是土豆也能 Vibe-code

[English](./README.md) · [Русский](./README.ru.md) · [Español](./README.es.md) · **中文** · [日本語](./README.ja.md) · [Português](./README.pt.md) · [हिन्दी](./README.hi.md) · [فارسی](./README.fa.md)

> **每个空闲 Agent 仅 ~3 MB 内存。单一静态二进制文件。零运行时。GPL 永久开源。**
> 由 Orlov 打造的轻如空气的 AI Agent —— 轻如氢气：**H** 取自最轻的元素，**Code** 取自你交付的代码。

```sh
brew install crystal && git clone https://github.com/YOU/hcode
cd hcode && shards install && rake build && ./hcode
```

**Crystal 1.14 · GPL-2.0-or-later · 原生二进制 · 无运行时**

---

## TL;DR —— 它为什么存在

五个编码 Agent 并行，你的笔记本就开始着火。五个 HCode Agent 空闲时总计只有 **~15 MB**。五个 Node.js Agent？从 **600 MB 到 2 GB** —— 保证，永久，每个进程。

| 配置                         | 空闲内存      | 对比 HCode |
|------------------------------|---------------|------------|
| 5 × opencode (Node.js)       | **≈ 2 GB**    | **~130×**  |
| 5 × kimi-code (Node.js)      | **> 1 GB**    | **~80×**   |
| 5 × Claude Code (Node.js)    | **≈ 600 MB**  | **~40×**   |
| 5 × HCode (Crystal，原生)    | **≈ 15 MB**   | **1×**     |

这就是全部卖点。一台跑着十个 HCode Agent 的笔记本，应该感觉像一台什么都没跑的笔记本。

---

## 起源故事

我打开系统监视器，吓坏了。两个 opencode 实例吃掉 **1 GB 内存**。五个 kimi-code 聊天一样 —— 因为每一个都拖着一个完整的 Node.js 运行时。

我想起 2007 年。我妈妈给我买了 **512 MB 内存**，好让我玩 *S.T.A.L.K.E.R.: Shadow of Chernobyl* —— 一款在一台 1 GB 内存的机器上就能跑的完整 3D 游戏。而到了 2026 年，我们在 1 GB 上竟然跑不了两个聊天。什么？**世界疯了。**

更糟的是 —— 这些"聊天"很难被称为**真正的软件**。它们是堆砌了功能的软件原型。真正的软件在性能上不可能这么可怕。而最可怕的是：它们是**永恒的原型**。永恒的临时方案，却作为成品交付。

然后其他开发者转向 Rust 来构建 Agent。Rust 是一种你和编译器搏斗而不是构建东西的语言 —— 另一个极端。而笑点是：基于 Rust 的对手在空闲时占用 **~10× 于 HCode 的内存**。

于是我以 Moonshot-AI 的 TypeScript Agent 为基线，在 Kimi 2.6 和 GLM 5 的帮助下用 Crystal 重写了它的逻辑。最初的结果：空闲 **~3 MB** 对比 kimi-code 的 ~200 MB。核心循环已经能跑。之后峰值消耗确实爬升 —— 到了 ~130 MB —— 对一个聊天记事本来说很可怕，但仍然低于 kimi-code 的空闲占用。

**这个差距，就是 HCode 存在的意义。**

---

## 问题所在

并行启动五个编码 Agent。盯着你的内存。每一个附带 Node.js 运行时的 Agent 都要为此买单 —— 按进程，永久。每个 HCode 进程在等待下一个 prompt 时只有约 **3 MB 常驻** —— 不是 120，不是 250，不是 400 MB。你的编辑器守住它的内存预算。你的笔记本保持凉爽。操作系统停止交换。你终于可以在你已经拥有的机器上跑一个 Agent 群。

> Rust Agent —— Codex、grok-build、Goose —— 同样是原生且精简的。对阵它们时 HCode 的优势不在内存，而在**可读性与许可证**。见下方的[全景图](#全景图)。

---

## 为什么是 Crystal？

我们认真审视了 Rust、Go 和 TypeScript。每一种都迫使我们接受一个我们不愿忍受的权衡。Crystal 是第一个让我们同时拿下三场胜利的语言。

- 🦀 **和 Rust 一样安全，语法却能让人类读懂。** 静态类型、nil 安全、联合类型、泛型和宏系统 —— 但代码读起来像 Ruby，跑起来像 C。没有 borrow checker 把每次重构变成研究课题。两个最被热炒的原生 Agent —— OpenAI 的 **Codex** 和 xAI 的 **grok-build** —— 都用 Rust 写成，它们的源码印证了代价：又快又安全，但加一个工具意味着和 lifetime 搏斗一周。Crystal 的工具层是一个下午就能读完的一个文件。
- 🐹 **和 Go 一样轻，却没有样板代码。** CSP 风格的 fiber 和 channel、亚秒级编译、单一静态二进制 —— 但没有每隔一行就出现的 `if err != nil`。你写的是功能，不是仪式。
- 🟦 **和 TypeScript 一样强大，却没有每个进程一个 Node.js 运行时。** Crystal 提前编译为原生 LLVM 二进制。没有 V8 堆，没有 JIT 预热，没有在每个 Agent 内重复的事件循环。更少的内存拷贝，更少的系统卡顿，毫秒级冷启动。

**一种语言。三场胜利。零运行时。**

---

## 理念

**内存是特性，不是脚注。** 大多数 Agent 框架把 RAM 当成别人的问题。它们附带一整套 V8 运行时、打包器、转译器和一棵 `node_modules` 树 —— 并按每一个、按进程、永久地向你收税。HCode 拒绝。一个空闲的 Agent 应该是隐形的。一台跑十个 Agent 的笔记本应该感觉像一台一个都没跑。

**协议属于所有人。** HCode 构建在 SSE 之上的 OpenAI Chat Completions 线协议格式。任何兼容端点 —— Moonshot、Z.AI、Zhipu、OpenAI、本地模型 —— 都接入同一套传输。没有厂商锁定。带上你自己的 key、你自己的模型、你自己的端点，并能在运行时从 TUI 里切换。

**开源，不可撤销。** HCode 是 GPL-2.0-or-later。每个衍生作品都必须附带其源码。你可以研究它、fork 它、在生产中运行它、把它嵌入你的产品 —— 只要源码跟着一起。

---

## 无国界，无中间商

Codex 和 Claude Code 把每个请求都路由到各自厂商的付费后端 —— 这也意味着它们继承了该厂商的国家封锁名单。从错误地区安装它们，它们就拒绝启动。grok-build 是开源的，但带着 xAI 的形状。

HCode 说的是开放协议。把它指向任何 OpenAI 兼容端点 —— Moonshot、Z.AI、OpenAI、本地的 Ollama 盒子、你自己 GPU 上的模型。**安装无需厂商账号。没有"不支持的国家"。没有你为加价付费的代理。** 你的范围由你的提供商限定，永远不由 Agent 限定。

---

## 特性

- 🪶 **极小占用** —— 每个空闲 Agent 约 3 MB 常驻；Boehm GC 从约 1 MB 起步；每个 fiber 约 8 KB 栈。
- 🔌 **多家提供商，一个二进制** —— Moonshot、Z.AI/Zhipu（pay-as-you-go + Coding Plan）以及任何 OpenAI 兼容端点。从 TUI 实时切换，无需重启。
- ⚡ **原生编译** —— `crystal build` 产出一个单一静态二进制。无运行时，无安装器，无 `node_modules`。
- 🧠 **真正的 Agent 循环** —— SSE 流式、通过 fiber 的并行工具调用、带连胜强制停止的工具调用去重、2 秒宽限超时的 abort、上下文溢出恢复（413 → 降级 → 压缩），以及 append-only 的 JSONL 会话持久化。
- 🛠️ **内置工具** —— Bash、Read、Write、Edit、Glob、Grep、TodoList 以及一个 agent-swarm 原语 —— 权限门控，带危险检测。
- 🧵 **fiber，而非进程** —— 在一个进程内跑几十个并发 Agent，或一个 Agent 一个二进制。由你选择隔离权衡。
- 💾 **可恢复会话** —— append-only 的 JSONL 事件日志，磁盘格式与 TypeScript 版本兼容。
- 🎛️ **交互式 TUI** —— 流式 markdown、工具卡片、diff 预览、多行编辑器、slash 命令、模型 / 提供商 / 权限选择器、会话选择器。
- 🔒 **GPL-2.0-or-later** —— 开源，无法被关闭。

---

## 提供商

HCode 说的是 SSE 之上的 OpenAI Chat Completions 线协议格式。**任何说这套协议的都行。**

| 提供商                       | 状态  | 备注                                      |
|------------------------------|-------|-------------------------------------------|
| Moonshot                     | ✅    | 默认后端。OAuth 或 API key。              |
| Z.AI / Zhipu（pay-as-you-go）| ✅    | OpenAI 兼容。                             |
| Z.AI / Zhipu（Coding Plan）  | ✅    | 订阅端点。                                |
| 任意 OpenAI 兼容             | ✅    | 指向任何说这套协议的端点。                |
| Mock                         | ✅    | 脚本化的提供商，用于自测和演示。          |

从 TUI 实时切换（`/provider`），或在 `~/.hcode/config.toml` 里固定一个。

---

## 快速开始

```sh
# 安装 Crystal ≥ 1.14 — https://crystal-lang.org/install/
brew install crystal          # macOS
# sudo pacman -S crystal      # Arch
# Debian/Ubuntu/Windows 见文档

# 构建
git clone https://github.com/YOU/hcode
cd hcode
shards install
rake build            # → ./hcode（release 标志）

# 冒烟测试你的凭证
./hcode --hi

# 无头模式 —— 单次 prompt，流式输出到 stdout
./hcode -p "explain this repo's entry point"

# 交互式 TUI
./hcode
```

密钥通过环境变量：`MOONSHOT_API_KEY`、`ZAI_API_KEY` / `ZHIPU_API_KEY`，……或 `~/.hcode/config.toml` 里的 `[provider.*]` 块。会话存放在 `~/.hcode/sessions/`；用 `-c` 恢复或从 TUI 里选一个。

---

## 全景图

空闲 RSS，来自真实世界。混合了作者实测、上游项目报告和标注估算 —— 每一格都能追溯到下方的来源。

### 内存，排序

从最轻到最重。

| # | Agent       | 语言       | 空闲内存          | 许可证              | 来源   |
|---|-------------|------------|-------------------|---------------------|--------|
| 1 | **HCode**   | **Crystal**| **~3 MB**         | **GPL-2.0-or-later**| [1]    |
| 2 | Codex CLI   | Rust       | ~30 MB            | Apache-2.0          | [2]    |
| 3 | grok-build  | Rust       | ~30–60 MB（估算） | Apache-2.0          | [3]    |
| 4 | Goose       | Rust + TS  | ~50–100 MB（估算）| Apache-2.0          | [4]    |
| 5 | Claude Code | TS / Node  | ~120 MB（增长）   | 专有                | [7]    |
| 6 | Aider       | Python     | ~150–250 MB（估算）| Apache-2.0          | [6]    |
| 7 | kimi-code   | TS / Node  | ~250 MB+          | MIT                 | [5]    |
| 8 | opencode    | TS / Bun   | ~400 MB           | MIT                 | [8]    |

**差距。** HCode 比最近的 Rust Agent（Codex）低 ~10×，比最轻的 Node Agent（Claude Code）低 ~40×，比 kimi-code 低 ~80×，比 opencode 低 **~130×**。Node 家族跨度极大 —— 从 ~120 MB 到 ~400 MB —— 因为每一个都按进程附带 V8 运行时并随使用增长。Rust Agent（Codex、grok-build、Goose）原生且精简；HCode 在内存上与它们并驾齐驱，并在可读性和许可证上胜出（见[为什么是 Crystal？](#为什么是-crystal)）。

> Aider（估算 ~150–250 MB）和 kimi-code（~250 MB+）处在同一重量级的边界 —— 它们的相对顺序在误差范围内。

### 自由

内存只是故事的一半。另一半是：谁拥有代码、你被允许在哪里运行它，以及你的 prompt 实际去了哪里。

| Agent       | 许可证              | 国家封锁    | 强制路由          | 自带端点（BYO）|
|-------------|---------------------|-------------|-------------------|----------------|
| Claude Code | 专有                | 是          | 是（Anthropic）   | 否             |
| Codex CLI   | Apache-2.0          | 是          | 是（OpenAI）      | 否             |
| grok-build  | Apache-2.0          | 部分        | xAI 默认          | 部分           |
| Goose       | Apache-2.0          | 否          | 否                | 是             |
| Aider       | Apache-2.0          | 否          | 否                | 是             |
| opencode    | MIT                 | 否          | 否                | 是             |
| kimi-code   | MIT                 | 否          | Moonshot          | 是             |
| **HCode**   | **GPL-2.0-or-later**| **否**      | **否**            | **是**         |

**两个故事，一个 Agent。** 对阵 Node Agent（opencode、Claude Code、kimi-code），HCode 以 40–130× 的内存优势取胜。对阵 Rust Agent（Codex、grok-build、Goose），内存差距很小 —— 那里 HCode 胜在**可读性**（没有 borrow checker，Ruby 风语法）和**许可证**（GPL 永久开放；Apache 可被关闭）。对阵厂商锁定（Codex、Claude Code），HCode 胜在**自由**：没有国家封锁，没有付费中间商。HCode 是唯一同时是最轻、最可读的原生 Agent、唯一的 copyleft Agent、以及唯一不附带任何厂商绳索的 Agent。

### 来源

- **[1] HCode** —— 作者实测，空闲 RSS。基线记录在 [`PLAN.md`](./PLAN.md)（Crystal + Boehm GC，约 1 MB GC 基线，每个 fiber 栈约 8 KB）。
- **[2] Codex CLI** —— 作者实测，空闲 RSS（约 30 MB）。原生 Rust 二进制，[`openai/codex`](https://github.com/openai/codex)。
- **[3] grok-build** —— 无公开测量；对原生 Rust TUI/harness 的估算。[`xai-org/grok-build`](https://github.com/xai-org/grok-build)。
- **[4] Goose** —— 无公开测量；对 Rust 核心 + 内嵌 TS/V8 UI 的估算。[`aaif-goose/goose`](https://github.com/aaif-goose/goose)。
- **[5] kimi-code** —— 作者实测，约 250 MB+ 空闲 RSS（TypeScript / Node.js）。取代 `PLAN.md` 中的内部规划估算。
- **[6] Aider** —— 无公开空闲数字；对 CPython + tree-sitter + litellm 依赖的估算。病态增长报告于 [`Aider-AI/aider#573`](https://github.com/Aider-AI/aider/issues/573)。
- **[7] Claude Code** —— 闭源。作者实测，约 120 MB 空闲 RSS；随时间增长，源于原生内存泄漏（"119.6 MB/hour"）：[`anthropics/claude-code#70168`](https://github.com/anthropics/claude-code/issues/70168) 及 `perf:memory` 标签。
- **[8] opencode** —— 作者实测，约 400 MB 空闲 RSS（TypeScript / Bun）。[`anomalyco/opencode`](https://github.com/anomalyco/opencode)。

*空闲 RSS 随操作系统、仓库大小和会话长度而变化。原生二进制（Rust/Crystal）稳定；运行时（Node/Python）随使用增长。标注（估算）的数字并非实验室测量 —— 它们是对未公布内存数据的 Agent 的数量级估算。*

---

## 内存消耗

HCode 的设计目标是让每个进程的内存保持有界。

### 空闲

每个空闲 Agent 约 **3 MB RSS**。这是 Crystal 运行时、Boehm GC 基线以及少量 TUI 状态。每个进程没有 Node.js/V8 运行时。

### 峰值

在 Linux 上用 `benchmarks/` 里的基准测试测得：

| 场景 | 峰值 RSS | 备注 |
|---|---|---|
| 2 000 轮（5 KB assistant + 50 KB 工具结果，带压缩） | ~37 MB | TUI 仅存工具预览；完整历史在 `wire.jsonl` |
| 10 000 次小工具调用 | ~20 MB | |
| 单次 10 MB 工具结果（Bash `MAX_OUTPUT_BYTES`） | ~31 MB | 上下文持有完整输出；TUI 预览约 1 KB |
| 单次 10 MB assistant 响应 | ~67 MB | 合成压力；10 MB 响应已超过 262k token 上下文窗口所允许 |

一个带 50 KB 工具结果的典型轮次约为 **13 000 tokens**。在 262 144 token 的上下文窗口下，一个完整上下文长度约 **20 轮**。所以 **2 000 轮已远超 10 个完整上下文长度**，而峰值 RSS 仍保持在 ~40 MB 以下。

### 为什么峰值之后 RSS 可能维持高位

Boehm GC 不会立即把释放的页面归还给操作系统。在一次大分配之后（例如对大上下文做 `request.to_json`），即使 `live` 内存已下降，RSS 仍可能保持膨胀。这是分配器行为，不是应用对象的泄漏。

## 许可证

HCode 以 **GPL-2.0-or-later** 发布。

Copyright © 2026 **Oleg Orlov** <orelcokolov@gmail.com> · byorlov.com.
All rights reserved. 完整文本见 [LICENSE](./LICENSE)。

> **为什么是 GPL-2.0 而非 MIT？** opencode 和 kimi-code 都是 MIT —— 任何人都可以把它们吸收进闭源产品而永不回馈。HCode 是 copyleft：每个衍生作品都必须以相同条款附带其源码。社区永远拥有一个免费的、可用的、无法被再次关闭的版本。
>
> **双重许可。** 版权仅由作者持有，因此项目可以额外向需要规避 GPL copyleft 的方（例如把 HCode 嵌入闭源产品）提供独立的商业许可证。为保持该选项可行，外部贡献需要签署 CLA，授予作者再许可权。见 [CONTRIBUTING.md](./CONTRIBUTING.md)。

---

## 贡献

欢迎 PR —— 请签署 CLA，以便项目能同时维持 GPL 和商业许可证的可行性。见 [CONTRIBUTING.md](./CONTRIBUTING.md)。
