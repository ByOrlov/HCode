# HCode — Vibe-code even on a potato

**English** · [Русский](./README.ru.md) · [Español](./README.es.md) · [中文](./README.zh.md) · [日本語](./README.ja.md) · [Português](./README.pt.md) · [हिन्दी](./README.hi.md) · [فارسی](./README.fa.md) · [Українська](./README.uk.md) · [Беларуская](./README.be.md)

> **~3 MB of RAM per agent at idle. One static binary. Zero runtime. GPL forever.**
> A lighter-than-air AI agent by Orlov — Hydrogen-light: **H** for the lightest element, **Code** for what you ship.

```sh
curl -fsSL https://raw.githubusercontent.com/ByOrlov/HCode/main/install.sh | bash
```

**Crystal 1.14 · GPL-2.0-or-later · Native Binary · No Runtime**

---

## TL;DR — why this exists

Five coding agents running in parallel and your laptop is on fire. Five HCode agents idle at **~15 MB total**. Five Node.js agents? Anywhere from **600 MB to 2 GB** — guaranteed, forever, per process.

| Setup                       | Idle RAM       | vs. HCode |
|-----------------------------|----------------|-----------|
| 5 × opencode (Node.js)      | **≈ 2 GB**     | **~130×** |
| 5 × kimi-code (Node.js)     | **> 1 GB**     | **~80×**  |
| 5 × Claude Code (Node.js)   | **≈ 600 MB**   | **~40×**  |
| 5 × HCode (Crystal, native) | **≈ 15 MB**    | **1×**    |

That's the whole pitch. A laptop running ten HCode agents should feel like a laptop running none.

---

## Origin Story

I opened the system monitor and was horrified. Two opencode instances were eating **1 GB of RAM**. Five kimi-code chats were doing the same — because each dragged a full Node.js runtime along for the ride.

I remembered 2007. My mother bought me **512 MB of RAM** so I could play *S.T.A.L.K.E.R.: Shadow of Chernobyl* — a full 3D game that ran on a machine with 1 GB of RAM. And now, in 2026, we can't run two chats on 1 GB. What? **The world has gone mad.**

Worse — these "chats" are hard to call **real software**. They're software prototypes with features bolted on. Real software cannot be this horrifying on performance. And the scariest part: they are **eternal prototypes**. Eternal temporary solutions, shipped as finished products.

Then other developers reach for Rust to build agents. Rust is a language where you fight the compiler instead of building things — the opposite extreme. And the punchline: the Rust competitors sit at **~10× HCode's memory while idle**.

So I took Moonshot-AI's TypeScript agent as a baseline and rewrote its logic in Crystal, with help from Kimi 2.6 and GLM 5. First results: **~3 MB idle** versus kimi-code's ~200 MB. The core loop already worked. Peak consumption did climb afterward — up to ~130 MB — which is horrifying for a chat-notepad, but still less than kimi-code at idle.

**That gap is what HCode exists to close.**

---

## The Problem

Spin up five coding agents in parallel. Watch your RAM. Every agent that ships a Node.js runtime pays for it — per process, forever. Each HCode process sits around **3 MB resident** while it waits for the next prompt — not 120, not 250, not 400 MB. Your editor keeps its memory budget. Your laptop stays cool. The OS stops swapping. You can finally run a swarm of agents on the machine you already own.

> The Rust agents — Codex, grok-build, Goose — are native and lean too. Against them HCode's edge isn't RAM, it's **readability and license**. See [The Landscape](#the-landscape) below.

---

## Why Crystal?

We looked hard at Rust, Go, and TypeScript. Each forced a trade-off we did not want to live with. Crystal is the first language that let us keep all three wins at once.

- 🦀 **As safe as Rust, with syntax a human can read.** Static typing, nil-safety, union types, generics, and a macro system — but the code reads like Ruby and runs like C. No borrow checker turning every refactor into a research problem. The two most-hyped native agents — OpenAI's **Codex** and xAI's **grok-build** — are both written in Rust, and their source proves the cost: fast and safe, but adding a tool means fighting lifetimes for a week. Crystal's tool layer is one file you read in an afternoon.
- 🐹 **As light as Go, without the boilerplate.** CSP-style fibers and channels, sub-second compiles, single static binaries — but no `if err != nil` on every other line. You write the feature, not the ceremony.
- 🟦 **As capable as TypeScript, without a Node.js runtime per process.** Crystal compiles ahead-of-time to a native LLVM binary. There is no V8 heap, no JIT warmup, no event loop duplicated inside every agent. Less memory copying, fewer system freezes, millisecond cold starts.

**One language. Three wins. Zero runtime.**

---

## Ideology

**Memory is a feature, not a footnote.** Most agent frameworks treat RAM as somebody else's problem. They ship a full V8 runtime, a bundler, a transpiler, and a `node_modules` tree — and tax you for each of those, per process, forever. HCode refuses. An idle agent should be invisible. A laptop running ten agents should feel like a laptop running none.

**The wire belongs to everyone.** HCode is built on the OpenAI Chat Completions wire format over SSE. Any compatible endpoint — Moonshot, Z.AI, Zhipu, OpenAI, a local model — plugs into the same transport. No vendor lock-in. Bring your own key, your own model, your own endpoint, and swap them at runtime from the TUI.

**Open source, irrevocably.** HCode is GPL-2.0-or-later. Every derivative must ship its source. You can study it, fork it, run it in production, embed it in your product — as long as the source comes along.

---

## No Borders, No Middleman

Codex and Claude Code route every request through their vendor's paid backend — which also means they inherit that vendor's country blocklist. Install them from the wrong region and they refuse to start. grok-build is open source but xAI-shaped.

HCode speaks the open wire. Point it at any OpenAI-compatible endpoint — Moonshot, Z.AI, OpenAI, a local Ollama box, a model on your own GPU. **No vendor account required to install. No "unsupported country." No proxy you pay a markup for.** Your reach is bounded by your provider, never by the agent.

---

## Features

- 🪶 **Tiny footprint** — ~3 MB resident per idle agent; Boehm GC starts at ~1 MB; fibers cost ~8 KB of stack each.
- 🔌 **Many providers, one binary** — Moonshot, Z.AI/Zhipu (pay-as-you-go + Coding Plan), and any OpenAI-compatible endpoint. Switch live from the TUI without restarting.
- ⚡ **Native compilation** — `crystal build` produces a single static binary. No runtime, no installer, no `node_modules`.
- 🧠 **A real agent loop** — streaming SSE, parallel tool calls via fibers, tool-call deduplication with streak force-stop, abort with a 2-second grace timeout, context-overflow recovery (413 → degrade → compaction), and append-only JSONL session persistence.
- 🛠️ **Built-in tools** — Bash, Read, Write, Edit, Glob, Grep, TodoList, and an agent-swarm primitive — permission-gated, with danger detection.
- 🧵 **Fibers, not processes** — run dozens of concurrent agents inside one process, or one binary per agent. You pick the isolation trade-off.
- 💾 **Resumable sessions** — append-only JSONL event log, on-disk compatible with the TypeScript version.
- 🎛️ **Interactive TUI** — streaming markdown, tool cards, diff preview, multiline editor, slash commands, model / provider / permission selectors, session picker.
- 🔒 **GPL-2.0-or-later** — open source, can't be closed.

---

## Providers

HCode speaks the OpenAI Chat Completions wire format over SSE. **Anything that speaks it works.**

| Provider                     | Status | Notes                                       |
|------------------------------|--------|---------------------------------------------|
| Moonshot                     | ✅     | Default backend. OAuth or API key.          |
| Z.AI / Zhipu (pay-as-you-go) | ✅     | OpenAI-compatible.                          |
| Z.AI / Zhipu (Coding Plan)   | ✅     | Subscription endpoint.                      |
| Any OpenAI-compatible        | ✅     | Point at any endpoint that speaks the wire. |
| Mock                         | ✅     | Scripted provider for self-tests and demos. |

Switch live from the TUI (`/provider`), or pin one in `~/.hcode/config.toml`.

---

## Install

HCode ships as a single native binary — no runtime, no `node_modules`. Pick your platform:

### macOS / Linux

```sh
curl -fsSL https://raw.githubusercontent.com/ByOrlov/HCode/main/install.sh | bash
```

The installer downloads the latest release for your architecture, places the binary at `~/.hcode/bin/hcode`, and adds that directory to your `PATH`. Restart your shell (or `source ~/.zshrc` / `~/.bashrc`) and run:

```sh
hcode
```

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/ByOrlov/HCode/main/install.ps1 | iex
```

The installer downloads the latest release, places the binary at `%LOCALAPPDATA%\hcode\bin\hcode.exe`, and adds that directory to your user `PATH`. Restart your terminal and run:

```powershell
hcode
```

### Supported platforms

| Platform           | Asset                              |
|--------------------|------------------------------------|
| Linux x86_64       | `hcode-x86_64-linux.tar.gz`        |
| Linux aarch64      | `hcode-aarch64-linux.tar.gz`       |
| macOS (Intel)      | `hcode-x86_64-darwin.tar.gz`       |
| macOS (Apple Silicon) | `hcode-aarch64-darwin.tar.gz`   |
| Windows x86_64     | `hcode-x86_64-windows.zip`         |

### Updating

Run `/upgrade` inside the TUI to check the latest GitHub release and replace your binary in place — no reinstall, no package manager:

```
/upgrade
```

The rolling release version follows `YYYY.MM.DD.N` (e.g. `2026.07.31.1`). To install a specific release manually, download the matching asset from the [releases page](https://github.com/ByOrlov/HCode/releases).

---

## Build from source

If you prefer to build HCode yourself, you need Crystal ≥ 1.14:

```sh
# Install Crystal ≥ 1.14 — https://crystal-lang.org/install/
brew install crystal          # macOS
# sudo pacman -S crystal      # Arch
# see docs for Debian/Ubuntu/Windows

# Build
git clone https://github.com/ByOrlov/HCode
cd HCode
shards install
rake build            # → ./hcode (release flags)

# Smoke-test your credentials
./hcode --hi

# Headless — one-shot prompt, streams to stdout
./hcode -p "explain this repo's entry point"

# Interactive TUI
./hcode
```

Keys via env: `MOONSHOT_API_KEY`, `ZAI_API_KEY` / `ZHIPU_API_KEY`, … or `[provider.*]` blocks in `~/.hcode/config.toml`. Sessions live under `~/.hcode/sessions/`; resume with `-c` or pick one from the TUI.

---

## The Landscape

Idle RSS, real-world. A mix of author measurements, upstream project reports, and labeled estimates — every cell is traceable to a source below.

### Memory, sorted

From featherweight to heavyweight.

| # | Agent       | Lang       | Idle RAM         | License             | Source |
|---|-------------|------------|------------------|---------------------|--------|
| 1 | **HCode**   | **Crystal**| **~3 MB**        | **GPL-2.0-or-later**| [1]    |
| 2 | grok-build  | Rust       | ~20 MB           | Apache-2.0          | [3]    |
| 3 | Codex CLI   | Rust       | ~30 MB           | Apache-2.0          | [2]    |
| 4 | Goose       | Rust + TS  | ~50–100 MB (est) | Apache-2.0          | [4]    |
| 5 | Claude Code | TS / Node  | ~120 MB (grows)  | proprietary         | [7]    |
| 6 | Aider       | Python     | ~150–250 MB(est) | Apache-2.0          | [6]    |
| 7 | kimi-code   | TS / Node  | ~250 MB+         | MIT                 | [5]    |
| 8 | opencode    | TS / Bun   | ~400 MB          | MIT                 | [8]    |

**The gap.** HCode sits ~7× under the nearest Rust agent (grok-build), ~40× under the lightest Node agent (Claude Code), ~80× under kimi-code, and **~130× under opencode.** The Node family spans an enormous range — from ~120 MB up to ~400 MB — because each one ships a V8 runtime per process and grows with use. The Rust agents (Codex, grok-build, Goose) are native and lean; HCode keeps pace with them on RAM and beats them on readability and license (see [Why Crystal?](#why-crystal)).

> Aider (est. ~150–250 MB) and kimi-code (~250 MB+) sit on the border of the same weight class — their relative order is within the margin.

### Freedom

Memory is half the story. The other half: who owns the code, where you're allowed to run it, and where your prompts actually go.

| Agent       | License             | Country-blocked | Forced router   | BYO endpoint |
|-------------|---------------------|-----------------|-----------------|--------------|
| Claude Code | proprietary         | yes             | yes (Anthropic) | no           |
| Codex CLI   | Apache-2.0          | yes             | yes (OpenAI)    | no           |
| grok-build  | Apache-2.0          | partial         | xAI default     | partial      |
| Goose       | Apache-2.0          | no              | no              | yes          |
| Aider       | Apache-2.0          | no              | no              | yes          |
| opencode    | MIT                 | no              | no              | yes          |
| kimi-code   | MIT                 | no              | Moonshot        | yes          |
| **HCode**   | **GPL-2.0-or-later**| **no**          | **no**          | **yes**      |

**Two stories, one agent.** Against the Node agents (opencode, Claude Code, kimi-code), HCode wins on RAM by 40–130×. Against the Rust agents (Codex, grok-build, Goose), the RAM gap is small — there HCode wins on **readability** (no borrow checker, Ruby-like syntax) and **license** (GPL stays open forever; Apache can be closed). Against the vendor-locked (Codex, Claude Code), HCode wins on **freedom**: no country block, no paid middleman. HCode is the only agent that is at once the lightest, the most readable native one, the only copyleft one, and the only one with zero vendor strings attached.

### Sources

- **[1] HCode** — author measurement, idle RSS. Baseline documented in [`PLAN.md`](./PLAN.md) (Crystal + Boehm GC, ~1 MB GC baseline, ~8 KB per fiber stack).
- **[2] Codex CLI** — author measurement, idle RSS (~30 MB). Native Rust binary, [`openai/codex`](https://github.com/openai/codex).
- **[3] grok-build** — author measurement, idle RSS (~20 MB). Native Rust binary, [`xai-org/grok-build`](https://github.com/xai-org/grok-build).
- **[4] Goose** — no public measurement; estimate for Rust core + embedded TS/V8 UI. [`aaif-goose/goose`](https://github.com/aaif-goose/goose).
- **[5] kimi-code** — author measurement, ~250 MB+ idle RSS (TypeScript / Node.js). Supersedes the internal planning estimate in `PLAN.md`.
- **[6] Aider** — no public idle number; estimate for CPython + tree-sitter + litellm deps. Pathological growth reported in [`Aider-AI/aider#573`](https://github.com/Aider-AI/aider/issues/573).
- **[7] Claude Code** — closed source. Author measurement, ~120 MB idle RSS; grows over time via a native memory leak ("119.6 MB/hour"): [`anthropics/claude-code#70168`](https://github.com/anthropics/claude-code/issues/70168) and the `perf:memory` label.
- **[8] opencode** — author measurement, ~400 MB idle RSS (TypeScript / Bun). [`anomalyco/opencode`](https://github.com/anomalyco/opencode).

*Idle RSS varies by OS, repo size, and session length. Native binaries (Rust/Crystal) are stable; runtimes (Node/Python) grow with use. Numbers marked (est.) are not lab-measured — they are order-of-magnitude estimates for agents that publish no memory data.*

---

## RAM Consumption

HCode is designed to keep memory bounded per process.

### Idle

~**3 MB RSS** per idle agent. This is the Crystal runtime, Boehm GC baseline, and a small TUI state. No Node.js/V8 runtime per process.

### Peak

Measured on Linux with the benchmarks in `benchmarks/`:

| Scenario | Peak RSS | Notes |
|---|---|---|
| 2 000 turns (5 KB assistant + 50 KB tool result, with compaction) | ~37 MB | TUI stores only tool previews; full history lives in `wire.jsonl` |
| 10 000 small tool calls | ~20 MB | |
| Single 10 MB tool result (Bash `MAX_OUTPUT_BYTES`) | ~31 MB | Context holds the full output; TUI preview is ~1 KB |
| Single 10 MB assistant response | ~67 MB | Synthetic stress; a 10 MB response is larger than the 262k-token context window allows |

A typical turn with a 50 KB tool result is roughly **13 000 tokens**. With a 262 144-token context window, one full context length is about **20 turns**. So **2 000 turns is already well over 10 full context lengths** in a single process, and peak RSS stays under ~40 MB.

### Why RSS can stay high after a peak

Boehm GC does not return freed pages to the OS immediately. After a large allocation (e.g. `request.to_json` on a big context) the RSS may remain inflated even though `live` memory has dropped. This is allocator behavior, not a leak of application objects.

## License

HCode is released under the **GPL-2.0-or-later**.

Copyright © 2026 **Oleg Orlov** <orelcokolov@gmail.com> · byorlov.com.
All rights reserved. See [LICENSE](./LICENSE) for the full text.

> **Why GPL-2.0, not MIT?** opencode and kimi-code are both MIT — anyone can absorb them into a closed-source product and never give back. HCode is copyleft: every derivative must ship its source under the same terms. The community always has a free, usable version that cannot be re-closed.
>
> **Dual licensing.** The copyright is held solely by the author so the project can additionally offer a separate commercial license to parties that need to avoid GPL copyleft (e.g. embedding HCode inside a closed-source product). To keep that option viable, outside contributions require a CLA that grants the author a license to relicense. See [CONTRIBUTING.md](./CONTRIBUTING.md).

---

## Contributing

PRs welcome — please sign the CLA so the project can keep both the GPL and the commercial license viable. See [CONTRIBUTING.md](./CONTRIBUTING.md).
