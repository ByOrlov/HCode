# HCode — 即使是土豆也能 Vibe-code

[English](./README.md) · [Русский](./README.ru.md) · [Español](./README.es.md) · **中文** · [日本語](./README.ja.md) · [Português](./README.pt.md) · [हिन्दी](./README.hi.md) · [فارسی](./README.fa.md) · [Українська](./README.uk.md) · [Беларуская](./README.be.md)

> **每个空闲 Agent 仅 ~3 MB 内存。单一静态二进制文件。零运行时。GPL 永久开源。**
> 由 Orlov 打造的轻如空气的 AI Agent —— 轻如氢气：**H** 取自最轻的元素，**Code** 取自你交付的代码。

Linux 和 MacOS

```sh
curl -fsSL https://raw.githubusercontent.com/ByOrlov/HCode/main/install.sh | bash
```

Windows

```powershell
irm https://raw.githubusercontent.com/ByOrlov/HCode/master/install.ps1 | iex 
```

**Crystal 1.14 · GPL-2.0-or-later · 原生二进制 · 无运行时**

---

### 内存，排序

从最轻到最重。

| # | Agent       | 语言       | 空闲内存          | 许可证              | 来源   |
|---|-------------|------------|-------------------|---------------------|--------|
| 1 | **HCode**   | **Crystal**| **~3 MB**         | **GPL-2.0-or-later**| [1]    |
| 2 | grok-build  | Rust       | ~20 MB            | Apache-2.0          | [3]    |
| 3 | Codex CLI   | Rust       | ~30 MB            | Apache-2.0          | [2]    |
| 4 | Goose       | Rust + TS  | ~50–100 MB（估算）| Apache-2.0          | [4]    |
| 5 | Claude Code | TS / Node  | ~120 MB（增长）   | 专有                | [7]    |
| 6 | Aider       | Python     | ~150–250 MB（估算）| Apache-2.0          | [6]    |
| 7 | kimi-code   | TS / Node  | ~250 MB+          | MIT                 | [5]    |
| 8 | opencode    | TS / Bun   | ~400 MB           | MIT                 | [8]    |

**差距。** HCode 比最近的 Rust Agent（grok-build）低 ~7×，比最轻的 Node Agent（Claude Code）低 ~40×，比 kimi-code 低 ~80×，比 opencode 低 **~130×**。Node 家族跨度极大 —— 从 ~120 MB 到 ~400 MB —— 因为每一个都按进程附带 V8 运行时并随使用增长。Rust Agent（Codex、grok-build、Goose）原生且精简；HCode 在内存上与它们并驾齐驱，并在可读性和许可证上胜出（见[为什么是 Crystal？](#为什么是-crystal)）。

> Aider（估算 ~150–250 MB）和 kimi-code（~250 MB+）处在同一重量级的边界 —— 它们的相对顺序在误差范围内。

---

## 起源故事

我打开系统监视器，吓坏了。两个 opencode 实例吃掉 **1 GB 内存**。五个 kimi-code 聊天一样 —— 因为每一个都拖着一个完整的 Node.js 运行时。

我想起 2007 年。我妈妈给我买了 **512 MB 内存**，好让我玩 *S.T.A.L.K.E.R.: Shadow of Chernobyl* —— 一款在一台 1 GB 内存的机器上就能跑的完整 3D 游戏。而到了 2026 年，我们在 1 GB 上竟然跑不了两个聊天。什么？**世界疯了。**

更糟的是 —— 这些"聊天"很难被称为**真正的软件**。它们是堆砌了功能的软件原型。真正的软件在性能上不可能这么可怕。而最可怕的是：它们是**永恒的原型**。永恒的临时方案，却作为成品交付。

然后其他开发者转向 Rust 来构建 Agent。Rust 是一种你和编译器搏斗而不是构建东西的语言 —— 另一个极端。而笑点是：基于 Rust 的对手在空闲时占用 **~10× 于 HCode 的内存**。

于是我以 Moonshot-AI 的 TypeScript Agent 为基线，在 Kimi 2.6 和 GLM 5 的帮助下用 Crystal 重写了它的逻辑。最初的结果：空闲 **~3 MB** 对比 kimi-code 的 ~200 MB。核心循环已经能跑。之后峰值消耗确实爬升 —— 到了 ~130 MB —— 对一个聊天记事本来说很可怕，但仍然低于 kimi-code 的空闲占用。

**这个差距，就是 HCode 存在的意义。**

---

## 它为什么存在

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

## 从源码构建

如果你更愿意自己构建 HCode，需要 Crystal ≥ 1.14：

```sh
# 安装 Crystal ≥ 1.14 — https://crystal-lang.org/install/
brew install crystal          # macOS
# sudo pacman -S crystal      # Arch
# Debian/Ubuntu/Windows 见文档

# 构建
git clone https://github.com/ByOrlov/HCode
cd HCode
shards install
rake build            # → ./hcode（release 标志）

# 冒烟测试你的凭证
./hcode --hi

# 无头模式 —— 单次 prompt，流式输出到 stdout
./hcode -p "explain this repo's entry point"

# 交互式 TUI
./hcode
```

---

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
