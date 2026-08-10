# HCode — ポテトでも Vibe-code

**日本語** · [English](./README.md) · [Русский](./README.ru.md) · [Español](./README.es.md) · [中文](./README.zh.md) · [Português](./README.pt.md) · [हिन्दी](./README.hi.md) · [فارسی](./README.fa.md) · [Українська](./README.uk.md) · [Беларуская](./README.be.md)

> **アイドル時エージェントあたり RAM ~3 MB。静的バイナリ 1 つ。ランタイムゼロ。GPL 永遠。**
> Orlov による空気より軽い AI エージェント —— 水素のように軽い：最も軽い元素から **H**、あなたが届けるものから **Code**。

Linux & MacOS

```sh
curl -fsSL https://raw.githubusercontent.com/ByOrlov/HCode/main/install.sh | bash
```

Windows

```powershell
irm https://raw.githubusercontent.com/ByOrlov/HCode/master/install.ps1 | iex 
```

**Crystal 1.14 · GPL-2.0-or-later · ネイティブバイナリ · ランタイムなし**

---

### メモリ、整列済み

羽根級から重量級まで。

| # | エージェント  | 言語       | アイドル RAM       | ライセンス           | ソース |
|---|---------------|------------|--------------------|----------------------|--------|
| 1 | **HCode**     | **Crystal**| **~3 MB**          | **GPL-2.0-or-later** | [1]    |
| 2 | grok-build    | Rust       | ~20 MB             | Apache-2.0           | [3]    |
| 3 | Codex CLI     | Rust       | ~30 MB             | Apache-2.0           | [2]    |
| 4 | Goose         | Rust + TS  | ~50–100 MB（推定） | Apache-2.0           | [4]    |
| 5 | Claude Code   | TS / Node  | ~120 MB（増加）    | プロプライエタリ     | [7]    |
| 6 | Aider         | Python     | ~150–250 MB（推定）| Apache-2.0           | [6]    |
| 7 | kimi-code     | TS / Node  | ~250 MB+           | MIT                  | [5]    |
| 8 | opencode      | TS / Bun   | ~400 MB            | MIT                  | [8]    |

**差。** HCode は最寄りの Rust エージェント（grok-build）より ~7× 下、最も軽い Node エージェント（Claude Code）より ~40× 下、kimi-code より ~80× 下、opencode より **~130× 下**に位置する。Node 系は巨大な幅をまたぐ —— ~120 MB から ~400 MB まで —— なぜならそれぞれがプロセスごとに V8 ランタイムを同梱し、使用とともに増大するからだ。Rust エージェント（Codex、grok-build、Goose）はネイティブで軽量；HCode は RAM で互角に並び、可読性とライセンスで勝る（[なぜ Crystal か？](#なぜ-crystal-か)を参照）。

> Aider（推定 ~150–250 MB）と kimi-code（~250 MB+）は同じ重量級の境界にいる —— 相対順序は誤差の範囲内だ。


---

## オリジンストーリー

システムモニタを開いて絶望した。opencode インスタンス 2 つが **1 GB の RAM** を食っていた。kimi-code のチャット 5 つも同じ —— なぜなら、それぞれが完全な Node.js ランタイムを引きずっていたからだ。

2007 年を思い出した。母が **512 MB の RAM** を買ってくれて、*S.T.A.L.K.E.R.: Shadow of Chernobyl* —— 1 GB の RAM で動く完全な 3D ゲーム —— を遊べるようになった。そして 2026 年、1 GB でチャット 2 つも動かせない。は？**世界は狂った。**

さらに悪いことに —— これらの「チャット」は**本物のソフトウェア**とは呼び難い。機能をボルトで留めただけのソフトウェアプロトタイプだ。本物のソフトウェアが性能でこれほど恐ろしいはずがない。そして最も恐ろしいのは：それらは**永遠のプロトタイプ**だ。完成品として出荷される、永遠の暫定ソリューション。

そして他の開発者はエージェントを作るために Rust に手を伸ばす。Rust は、ものを作る代わりにコンパイラと戦う言語だ —— 正反対の極端。そしてオチ：Rust の競合はアイドル時で **HCode の ~10 倍のメモリ**に居座る。

そこで Moonshot-AI の TypeScript エージェントをベースに、Kimi 2.6 と GLM 5 の助けを借りて、そのロジックを Crystal で書き直した。最初の結果：kimi-code の ~200 MB に対してアイドル **~3 MB**。コアループはすでに動いた。その後ピーク消費は上昇した —— ~130 MB まで —— これはチャットメモ帳としては恐ろしいが、それでも kimi-code のアイドルよりは少ない。

**その差を埋めるために HCode は存在する。**

---

## これが存在する理由

コーディングエージェントを 5 つ並行で立ち上げろ。RAM を見よ。Node.js ランタイムを同梱するエージェントはすべて、その代償を払う —— プロセスごとに、永遠に。各 HCode プロセスは次のプロンプトを待つ間、約 **3 MB resident** に留まる —— 120 でも 250 でも 400 MB でもない。エディタはメモリ予算を守る。ノート PC は涼しいままだ。OS はスワップをやめる。あなたはついに、すでに持っているマシンでエージェントの群れを走らせられる。

> Rust エージェント —— Codex、grok-build、Goose —— もネイティブで軽量だ。それらに対する HCode の強みは RAM ではなく、**可読性とライセンス**だ。下の[ランドスケープ](#ランドスケープ)を参照。

---

## なぜ Crystal か？

Rust、Go、TypeScript を真剣に検討した。どれも、私たちが受け入れたくないトレードオフを強いた。Crystal は、3 つの勝利を同時に維持させてくれた初めての言語だ。

- 🦀 **Rust と同等に安全で、人間が読める構文。** 静的型付け、nil 安全、ユニオン型、ジェネリクス、マクロシステム —— それでいてコードは Ruby のように読め、C のように動く。リファクタリングごとに研究課題に変える borrow checker はない。最も喧伝された 2 つのネイティブエージェント —— OpenAI の **Codex** と xAI の **grok-build** —— はどちらも Rust で書かれており、そのソースは代償を裏付ける：高速で安全だが、ツールを一つ追加すると lifetime と 1 週間戦うことになる。Crystal のツール層は、午後 1 回で読み切れる 1 ファイルだ。
- 🐹 **Go と同等に軽く、ボイラープレートなし。** CSP スタイルのファイバとチャネル、サブ秒のコンパイル、単一の静的バイナリ —— しかし他行ごとの `if err != nil` はない。あなたは機能を書くのであり、儀式を書くのではない。
- 🟦 **TypeScript と同等に高機能で、プロセスごとの Node.js ランタイムなし。** Crystal は AOT でネイティブな LLVM バイナリにコンパイルされる。V8 ヒープはなく、JIT のウォームアップはなく、エージェントごとに複製されるイベントループもない。メモリコピーは少なく、システムのフリーズは少なく、ミリ秒のコールドスタート。

**1 つの言語。3 つの勝利。ランタイムゼロ。**

---

## ソースからビルド

ご自身で HCode をビルドしたい場合は、Crystal ≥ 1.14 が必要：

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

---

### 自由

メモリは物語の半分だ。もう半分は：コードを誰が所有するか、どこで動かすことを許されるか、そしてプロンプトが実際にどこへ行くか。

| エージェント  | ライセンス           | 国別ブロック  | 強制ルータ        | 自前エンドポイント |
|---------------|----------------------|---------------|-------------------|--------------------|
| Claude Code   | プロプライエタリ     | あり          | あり（Anthropic） | なし               |
| Codex CLI     | Apache-2.0           | あり          | あり（OpenAI）    | なし               |
| grok-build    | Apache-2.0           | 部分          | xAI デフォルト    | 部分               |
| Goose         | Apache-2.0           | なし          | なし              | あり               |
| Aider         | Apache-2.0           | なし          | なし              | あり               |
| opencode      | MIT                  | なし          | なし              | あり               |
| kimi-code     | MIT                  | なし          | Moonshot          | あり               |
| **HCode**     | **GPL-2.0-or-later** | **なし**      | **なし**          | **あり**           |


## ライセンス

HCode は **GPL-2.0-or-later** で公開されている。

Copyright © 2026 **Oleg Orlov** <orelcokolov@gmail.com> · byorlov.com.
All rights reserved. 全文は [LICENSE](./LICENSE) を参照。

> **なぜ MIT ではなく GPL-2.0 なのか？** opencode と kimi-code はどちらも MIT だ —— 誰でもそれらをクローズドソース製品に取り込み、決して還元しないことができる。HCode はコピーレフトだ：派生物はすべて同じ条件でソースを同梱しなければならない。コミュニティは常に、再閉鎖できない自由で使えるバージョンを持つ。
>
> **デュアルライセンス。** 著作権は著者単独で保持されているため、プロジェクトは GPL コピーレフトを回避する必要のある者（例えば HCode をクローズドソース製品に組み込む場合）に別個の商用ライセンスを追加で提供できる。この選択肢を維持するため、外部からの貢献には著者に再許諾権を付与する CLA が求められる。[CONTRIBUTING.md](./CONTRIBUTING.md) を参照。

---

## コントリビュート

PR を歓迎する —— プロジェクトが GPL と商用ライセンスの両方を維持できるよう、CLA に署名してほしい。[CONTRIBUTING.md](./CONTRIBUTING.md) を参照。
