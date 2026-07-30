# HCode — Vibe-code até num torrada

[English](./README.md) · [Русский](./README.ru.md) · [Español](./README.es.md) · [中文](./README.zh.md) · [日本語](./README.ja.md) · **Português** · [हिन्दी](./README.hi.md) · [فارسی](./README.fa.md) · [Українська](./README.uk.md) · [Беларуская](./README.be.md)

> **~3 MB de RAM por agente em repouso. Um único binário estático. Zero runtime. GPL para sempre.**
> Um agente de IA mais leve que o ar, por Orlov — leve como o hidrogênio: **H** do elemento mais leve, **Code** do que você entrega.

```sh
curl -fsSL https://raw.githubusercontent.com/ByOrlov/HCode/main/install.sh | bash
```

**Crystal 1.14 · GPL-2.0-or-later · Binário nativo · Sem runtime**

---

## TL;DR — por que isso existe

Cinco agentes de código rodando em paralelo e seu laptop pega fogo. Cinco agentes HCode inativos consomem **~15 MB no total**. Cinco agentes Node.js? De **600 MB a 2 GB** — garantido, para sempre, por processo.

| Configuração                 | RAM em repouso | vs. HCode |
|------------------------------|----------------|-----------|
| 5 × opencode (Node.js)       | **≈ 2 GB**     | **~130×** |
| 5 × kimi-code (Node.js)      | **> 1 GB**     | **~80×**  |
| 5 × Claude Code (Node.js)    | **≈ 600 MB**   | **~40×**  |
| 5 × HCode (Crystal, nativo)  | **≈ 15 MB**    | **1×**    |

Essa é toda a proposta. Um laptop rodando dez agentes HCode deve parecer um laptop rodando nenhum.

---

## História de origem

Abri o monitor do sistema e fiquei horrorizado. Duas instâncias do opencode devoravam **1 GB de RAM**. Cinco chats do kimi-code faziam o mesmo — porque cada um arrastava consigo um runtime completo de Node.js.

Lembrei de 2007. Minha mãe me comprou **512 MB de RAM** para que eu pudesse jogar *S.T.A.L.K.E.R.: Shadow of Chernobyl* — um jogo 3D completo que rodava numa máquina com 1 GB de RAM. E agora, em 2026, não conseguimos rodar dois chats em 1 GB. Quê? **O mundo enlouqueceu.**

Pior — esses "chats" custam a chamar de **software de verdade**. São protótipos de software com funcionalidades enxertadas. Software real não pode ser tão horrível em performance. E o mais assustador: são **protótipos eternos**. Soluções temporárias eternas, entregues como produtos acabados.

Depois outros desenvolvedores recorrem ao Rust para construir agentes. Rust é uma linguagem onde você briga com o compilador em vez de construir coisas — o extremo oposto. E a piada: os concorrentes em Rust ficam em **~10× a memória do HCode em repouso**.

Então peguei o agente em TypeScript da Moonshot-AI como base e reescrevi sua lógica em Crystal, com a ajuda do Kimi 2.6 e do GLM 5. Primeiros resultados: **~3 MB em repouso** contra os ~200 MB do kimi-code. O loop principal já funcionava. O consumo de pico subiu depois — até ~130 MB — o que é horroroso para um bloco de notas-chat, mas ainda menos que o kimi-code em repouso.

**Essa brecha é o que o HCode existe para fechar.**

---

## O problema

Suba cinco agentes de código em paralelo. Olhe sua RAM. Todo agente que embute um runtime de Node.js paga por isso — por processo, para sempre. Cada processo HCode fica em torno de **3 MB residentes** enquanto espera o próximo prompt — não 120, não 250, não 400 MB. Seu editor mantém seu orçamento de memória. Seu laptop continua fresco. O SO para de fazer swap. Você finalmente pode rodar um enxame de agentes na máquina que já tem.

> Os agentes em Rust — Codex, grok-build, Goose — também são nativos e enxutos. Contra eles a vantagem do HCode não é RAM, é **legibilidade e licença**. Veja [O cenário](#o-cenário) abaixo.

---

## Por que Crystal?

Olhamos com atenção Rust, Go e TypeScript. Cada um nos obrigava a um compromisso com o qual não queríamos viver. Crystal é a primeira linguagem que nos permitiu manter as três vitórias ao mesmo tempo.

- 🦀 **Tão seguro quanto Rust, com sintaxe que um humano consegue ler.** Tipagem estática, segurança contra nil, tipos união, genéricos e um sistema de macros — mas o código se lê como Ruby e roda como C. Sem borrow checker transformando todo refactor num problema de pesquisa. Os dois agentes nativos mais badalados — **Codex** da OpenAI e **grok-build** da xAI — estão ambos escritos em Rust, e o código-fonte deles comprova o custo: rápidos e seguros, mas adicionar uma ferramenta significa brigar com lifetimes por uma semana. A camada de ferramentas do Crystal é um arquivo que você lê numa tarde.
- 🐹 **Tão leve quanto Go, sem o boilerplate.** Fibers e canais estilo CSP, compilações abaixo de um segundo, binários estáticos únicos — mas sem `if err != nil` em toda outra linha. Você escreve a funcionalidade, não a cerimônia.
- 🟦 **Tão capaz quanto TypeScript, sem um runtime de Node.js por processo.** Crystal compila ahead-of-time para um binário nativo LLVM. Não há heap do V8, não há warmup de JIT, não há event loop duplicado dentro de cada agente. Menos cópia de memória, menos travamentos do sistema, arranques a frio em milissegundos.

**Uma linguagem. Três vitórias. Zero runtime.**

---

## Ideologia

**Memória é uma característica, não uma nota de rodapé.** A maioria dos frameworks de agentes trata a RAM como problema dos outros. Eles embutem um runtime completo de V8, um bundler, um transpilador e uma árvore de `node_modules` — e te cobram por cada um deles, por processo, para sempre. O HCode se recusa. Um agente inativo deve ser invisível. Um laptop rodando dez agentes deve parecer um laptop rodando nenhum.

**O protocolo pertence a todos.** O HCode é construído sobre o formato de protocolo OpenAI Chat Completions via SSE. Qualquer endpoint compatível — Moonshot, Z.AI, Zhipu, OpenAI, um modelo local — se conecta ao mesmo transporte. Sem lock-in de fornecedor. Traga sua própria chave, seu próprio modelo, seu próprio endpoint, e troque-os em tempo de execução pela TUI.

**Código aberto, de forma irrevogável.** O HCode é GPL-2.0-or-later. Todo derivativo deve publicar seu código-fonte. Você pode estudá-lo, fazer fork, rodá-lo em produção, embuti-lo no seu produto — desde que o código-fonte venha junto.

---

## Sem fronteiras, sem intermediário

Codex e Claude Code roteiam toda requisição pelo backend pago do seu fornecedor — o que também significa que herdam a lista de bloqueio de países desse fornecedor. Instale-os da região errada e eles se recusam a iniciar. grok-build é código aberto, mas com formato xAI.

O HCode fala o protocolo aberto. Aponte-o para qualquer endpoint compatível com OpenAI — Moonshot, Z.AI, OpenAI, uma caixa local de Ollama, um modelo na sua própria GPU. **Sem conta de fornecedor para instalar. Sem "país não suportado". Sem proxy pelo qual você paga um sobrepreço.** Seu alcance é limitado pelo seu provedor, nunca pelo agente.

---

## Funcionalidades

- 🪶 **Pegada minúscula** — ~3 MB residentes por agente inativo; o Boehm GC parte de ~1 MB; cada fiber custa ~8 KB de pilha.
- 🔌 **Muitos provedores, um binário** — Moonshot, Z.AI/Zhipu (pay-as-you-go + Coding Plan), e qualquer endpoint compatível com OpenAI. Troque em quente pela TUI sem reiniciar.
- ⚡ **Compilação nativa** — `crystal build` produz um único binário estático. Sem runtime, sem instalador, sem `node_modules`.
- 🧠 **Um loop de agente de verdade** — streaming SSE, chamadas de ferramentas em paralelo via fibers, desduplicação de chamadas de ferramentas com parada forçada de sequências, abort com grace-timeout de 2 segundos, recuperação de estouro de contexto (413 → degradar → compactação) e persistência de sessão JSONL somente-acréscimo.
- 🛠️ **Ferramentas embutidas** — Bash, Read, Write, Edit, Glob, Grep, TodoList e um primitivo agent-swarm — com porta de permissões e detecção de perigo.
- 🧵 **Fibers, não processos** — rode dezenas de agentes concorrentes dentro de um processo, ou um binário por agente. Você escolhe o compromisso de isolamento.
- 💾 **Sessões retomáveis** — log de eventos JSONL somente-acréscimo, compatível em disco com a versão TypeScript.
- 🎛️ **TUI interativa** — markdown em streaming, cartões de ferramentas, pré-visualização de diff, editor multilinha, comandos slash, seletores de modelo / provedor / permissões, seletor de sessão.
- 🔒 **GPL-2.0-or-later** — código aberto, não pode ser fechado.

---

## Provedores

O HCode fala o formato de protocolo OpenAI Chat Completions via SSE. **Qualquer um que o fala, funciona.**

| Provedor                     | Estado | Notas                                            |
|------------------------------|--------|--------------------------------------------------|
| Moonshot                     | ✅     | Backend padrão. OAuth ou API key.                |
| Z.AI / Zhipu (pay-as-you-go) | ✅     | Compatível com OpenAI.                           |
| Z.AI / Zhipu (Coding Plan)   | ✅     | Endpoint por assinatura.                         |
| Qualquer compatível OpenAI   | ✅     | Aponte para qualquer endpoint que fale o protocolo. |
| Mock                         | ✅     | Provedor roteirizado para autotestes e demos.    |

Troque em quente pela TUI (`/provider`), ou fixe um em `~/.hcode/config.toml`.

---

## Instalação

O HCode é distribuído como um único binário nativo — sem runtime, sem `node_modules`. Escolha sua plataforma:

### macOS / Linux

```sh
curl -fsSL https://raw.githubusercontent.com/ByOrlov/HCode/main/install.sh | bash
```

O instalador baixa o release mais recente para sua arquitetura, coloca o binário em `~/.hcode/bin/hcode` e adiciona esse diretório ao seu `PATH`. Reinicie seu shell (ou `source ~/.zshrc` / `~/.bashrc`) e execute:

```sh
hcode
```

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/ByOrlov/HCode/main/install.ps1 | iex
```

O instalador baixa o release mais recente, coloca o binário em `%LOCALAPPDATA%\hcode\bin\hcode.exe` e adiciona esse diretório ao seu `PATH` de usuário. Reinicie seu terminal e execute:

```powershell
hcode
```

### Plataformas suportadas

| Plataforma            | Asset                              |
|-----------------------|------------------------------------|
| Linux x86_64          | `hcode-x86_64-linux.tar.gz`        |
| Linux aarch64         | `hcode-aarch64-linux.tar.gz`       |
| macOS (Intel)         | `hcode-x86_64-darwin.tar.gz`       |
| macOS (Apple Silicon) | `hcode-aarch64-darwin.tar.gz`      |
| Windows x86_64        | `hcode-x86_64-windows.zip`         |

### Atualizando

Execute `/upgrade` dentro da TUI para verificar o release mais recente do GitHub e substituir seu binário no lugar — sem reinstalação, sem gerenciador de pacotes:

```
/upgrade
```

A versão de release contínuo segue `YYYY.MM.DD.N` (p. ex. `2026.07.31.1`). Para instalar um release específico manualmente, baixe o asset correspondente na [página de releases](https://github.com/ByOrlov/HCode/releases).

---

## Compilação a partir do código-fonte

Se você prefere compilar o HCode por conta própria, precisa do Crystal ≥ 1.14:

```sh
# Instale o Crystal ≥ 1.14 — https://crystal-lang.org/install/
brew install crystal          # macOS
# sudo pacman -S crystal      # Arch
# veja a docs para Debian/Ubuntu/Windows

# Compilação
git clone https://github.com/ByOrlov/HCode
cd HCode
shards install
rake build            # → ./hcode (flags de release)

# Teste suas credenciais
./hcode --hi

# Headless — prompt de disparo único, saída em streaming para stdout
./hcode -p "explain this repo's entry point"

# TUI interativa
./hcode
```

Chaves por variáveis de ambiente: `MOONSHOT_API_KEY`, `ZAI_API_KEY` / `ZHIPU_API_KEY`, … ou blocos `[provider.*]` em `~/.hcode/config.toml`. As sessões vivem em `~/.hcode/sessions/`; retome com `-c` ou escolha uma pela TUI.

---

## O cenário

RSS em repouso, do mundo real. Uma mistura de medições do autor, relatórios de projetos upstream e estimativas rotuladas — cada célula é rastreável a uma fonte abaixo.

### Memória, ordenada

Do mais leve ao mais pesado.

| # | Agente      | Linguagem | RAM em repouso   | Licença             | Fonte |
|---|-------------|-----------|------------------|---------------------|-------|
| 1 | **HCode**   | **Crystal**| **~3 MB**        | **GPL-2.0-or-later**| [1]   |
| 2 | Codex CLI   | Rust      | ~30 MB           | Apache-2.0          | [2]   |
| 3 | grok-build  | Rust      | ~30–60 MB (est)  | Apache-2.0          | [3]   |
| 4 | Goose       | Rust + TS | ~50–100 MB (est) | Apache-2.0          | [4]   |
| 5 | Claude Code | TS / Node | ~120 MB (cresce) | proprietária        | [7]   |
| 6 | Aider       | Python    | ~150–250 MB(est) | Apache-2.0          | [6]   |
| 7 | kimi-code   | TS / Node | ~250 MB+         | MIT                 | [5]   |
| 8 | opencode    | TS / Bun  | ~400 MB          | MIT                 | [8]   |

**A brecha.** O HCode fica ~10× abaixo do agente em Rust mais próximo (Codex), ~40× abaixo do agente Node mais leve (Claude Code), ~80× abaixo do kimi-code e **~130× abaixo do opencode.** A família Node cobre uma faixa enorme — de ~120 MB até ~400 MB — porque cada um embute um runtime V8 por processo e cresce com o uso. Os agentes em Rust (Codex, grok-build, Goose) são nativos e enxutos; o HCode acompanha o ritmo deles em RAM e os vence em legibilidade e licença (veja [Por que Crystal?](#por-que-crystal)).

> Aider (est. ~150–250 MB) e kimi-code (~250 MB+) estão na fronteira da mesma categoria de peso — sua ordem relativa está dentro da margem.

### Liberdade

Memória é metade da história. A outra metade: quem possui o código, onde você tem permissão de rodá-lo, e para onde seus prompts realmente vão.

| Agente      | Licença             | Bloqueio por país | Router forçado  | Endpoint próprio (BYO) |
|-------------|---------------------|-------------------|-----------------|------------------------|
| Claude Code | proprietária        | sim               | sim (Anthropic) | não                    |
| Codex CLI   | Apache-2.0          | sim               | sim (OpenAI)    | não                    |
| grok-build  | Apache-2.0          | parcial           | xAI por padrão  | parcial                |
| Goose       | Apache-2.0          | não               | não             | sim                    |
| Aider       | Apache-2.0          | não               | não             | sim                    |
| opencode    | MIT                 | não               | não             | sim                    |
| kimi-code   | MIT                 | não               | Moonshot        | sim                    |
| **HCode**   | **GPL-2.0-or-later**| **não**           | **não**         | **sim**                |

**Duas histórias, um agente.** Contra os agentes Node (opencode, Claude Code, kimi-code), o HCode vence em RAM por 40–130×. Contra os agentes Rust (Codex, grok-build, Goose), a brecha de RAM é pequena — aí o HCode vence em **legibilidade** (sem borrow checker, sintaxe tipo Ruby) e **licença** (GPL permanece aberto para sempre; Apache pode ser fechado). Contra os bloqueados por fornecedor (Codex, Claude Code), o HCode vence em **liberdade**: sem bloqueio de país, sem intermediário pago. O HCode é o único agente que é ao mesmo tempo o mais leve, o nativo mais legível, o único copyleft e o único sem amarras de fornecedor.

### Fontes

- **[1] HCode** — medição do autor, RSS em repouso. Base documentada em [`PLAN.md`](./PLAN.md) (Crystal + Boehm GC, ~1 MB de base de GC, ~8 KB de pilha por fiber).
- **[2] Codex CLI** — medição do autor, RSS em repouso (~30 MB). Binário nativo em Rust, [`openai/codex`](https://github.com/openai/codex).
- **[3] grok-build** — sem medição pública; estimativa para TUI/harness nativo em Rust. [`xai-org/grok-build`](https://github.com/xai-org/grok-build).
- **[4] Goose** — sem medição pública; estimativa para núcleo Rust + UI TS/V8 embutida. [`aaif-goose/goose`](https://github.com/aaif-goose/goose).
- **[5] kimi-code** — medição do autor, ~250 MB+ RSS em repouso (TypeScript / Node.js). Substitui a estimativa interna de planejamento em `PLAN.md`.
- **[6] Aider** — sem número público em repouso; estimativa para CPython + tree-sitter + deps litellm. Crescimento patológico reportado em [`Aider-AI/aider#573`](https://github.com/Aider-AI/aider/issues/573).
- **[7] Claude Code** — código fechado. Medição do autor, ~120 MB RSS em repouso; cresce ao longo do tempo por um vazamento de memória nativa ("119.6 MB/hour"): [`anthropics/claude-code#70168`](https://github.com/anthropics/claude-code/issues/70168) e a label `perf:memory`.
- **[8] opencode** — medição do autor, ~400 MB RSS em repouso (TypeScript / Bun). [`anomalyco/opencode`](https://github.com/anomalyco/opencode).

*O RSS em repouso varia conforme SO, tamanho do repo e duração da sessão. Binários nativos (Rust/Crystal) são estáveis; runtimes (Node/Python) crescem com o uso. Números marcados (est.) não foram medidos em laboratório — são estimativas de ordem de grandeza para agentes que não publicam dados de memória.*

---

## Consumo de RAM

O HCode é projetado para manter a memória limitada por processo.

### Repouso

~**3 MB de RSS** por agente inativo. Isso é o runtime do Crystal, a base do Boehm GC e um pequeno estado de TUI. Sem runtime de Node.js/V8 por processo.

### Pico

Medido no Linux com os benchmarks em `benchmarks/`:

| Cenário | RSS de pico | Notas |
|---|---|---|
| 2 000 turnos (5 KB assistente + 50 KB resultado de ferramenta, com compactação) | ~37 MB | A TUI guarda apenas pré-visualizações; o histórico completo vive em `wire.jsonl` |
| 10 000 chamadas pequenas a ferramentas | ~20 MB | |
| Único resultado de ferramenta de 10 MB (Bash `MAX_OUTPUT_BYTES`) | ~31 MB | O contexto guarda a saída completa; a pré-visualização da TUI é ~1 KB |
| Única resposta de assistente de 10 MB | ~67 MB | Estresse sintético; uma resposta de 10 MB é maior do que a janela de contexto de 262k tokens permite |

Um turno típico com um resultado de ferramenta de 50 KB são aproximadamente **13 000 tokens**. Com uma janela de contexto de 262 144 tokens, um comprimento completo de contexto equivale a cerca de **20 turnos**. Então **2 000 turnos já passam de 10 comprimentos completos de contexto** num único processo, e o RSS de pico permanece abaixo de ~40 MB.

### Por que o RSS pode permanecer alto após um pico

O Boehm GC não devolve páginas liberadas ao SO imediatamente. Após uma grande alocação (p. ex. `request.to_json` sobre um contexto grande) o RSS pode permanecer inflado mesmo que a memória `live` tenha caído. É comportamento do allocator, não um vazamento de objetos da aplicação.

## Licença

O HCode é publicado sob a **GPL-2.0-or-later**.

Copyright © 2026 **Oleg Orlov** <orelcokolov@gmail.com> · byorlov.com.
Todos os direitos reservados. Consulte [LICENSE](./LICENSE) para o texto completo.

> **Por que GPL-2.0 e não MIT?** opencode e kimi-code são ambos MIT — qualquer um pode absorvê-los num produto fechado e nunca devolver nada. O HCode é copyleft: todo derivativo deve publicar seu código-fonte sob os mesmos termos. A comunidade tem sempre uma versão livre e utilizável que não pode ser refechada.
>
> **Licenciamento duplo.** Os direitos autorais são detidos exclusivamente pelo autor, de modo que o projeto pode adicionalmente oferecer uma licença comercial separada a quem precise evitar o copyleft da GPL (p. ex. embutir o HCode dentro de um produto fechado). Para manter essa opção viável, contribuições externas exigem um CLA que concede ao autor uma licença para relicenciar. Veja [CONTRIBUTING.md](./CONTRIBUTING.md).

---

## Contribuir

PRs são bem-vindas — por favor assine o CLA para que o projeto possa manter tanto a GPL quanto a licença comercial viáveis. Veja [CONTRIBUTING.md](./CONTRIBUTING.md).
