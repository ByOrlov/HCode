# HCode — Vibe-code até num torrada

[English](./README.md) · [Русский](./README.ru.md) · [Español](./README.es.md) · [中文](./README.zh.md) · [日本語](./README.ja.md) · **Português** · [हिन्दी](./README.hi.md) · [فارسی](./README.fa.md) · [Українська](./README.uk.md) · [Беларуская](./README.be.md)

> **~3 MB de RAM por agente em repouso. Um único binário estático. Zero runtime. GPL para sempre.**
> Um agente de IA mais leve que o ar, por Orlov — leve como o hidrogênio: **H** do elemento mais leve, **Code** do que você entrega.

Linux e MacOS

```sh
curl -fsSL https://raw.githubusercontent.com/ByOrlov/HCode/main/install.sh | bash
```

Windows

```powershell
irm https://raw.githubusercontent.com/ByOrlov/HCode/master/install.ps1 | iex 
```

**Crystal 1.14 · GPL-2.0-or-later · Binário nativo · Sem runtime**

---

### Memória, ordenada

Do mais leve ao mais pesado.

| # | Agente      | Linguagem | RAM em repouso   | Licença             | Fonte |
|---|-------------|-----------|------------------|---------------------|-------|
| 1 | **HCode**   | **Crystal**| **~3 MB**        | **GPL-2.0-or-later**| [1]   |
| 2 | grok-build  | Rust      | ~20 MB           | Apache-2.0          | [3]   |
| 3 | Codex CLI   | Rust      | ~30 MB           | Apache-2.0          | [2]   |
| 4 | Goose       | Rust + TS | ~50–100 MB (est) | Apache-2.0          | [4]   |
| 5 | Claude Code | TS / Node | ~120 MB (cresce) | proprietária        | [7]   |
| 6 | Aider       | Python    | ~150–250 MB(est) | Apache-2.0          | [6]   |
| 7 | kimi-code   | TS / Node | ~250 MB+         | MIT                 | [5]   |
| 8 | opencode    | TS / Bun  | ~400 MB          | MIT                 | [8]   |

**A brecha.** O HCode fica ~7× abaixo do agente em Rust mais próximo (grok-build), ~40× abaixo do agente Node mais leve (Claude Code), ~80× abaixo do kimi-code e **~130× abaixo do opencode.** A família Node cobre uma faixa enorme — de ~120 MB até ~400 MB — porque cada um embute um runtime V8 por processo e cresce com o uso. Os agentes em Rust (Codex, grok-build, Goose) são nativos e enxutos; o HCode acompanha o ritmo deles em RAM e os vence em legibilidade e licença (veja [Por que Crystal?](#por-que-crystal)).

> Aider (est. ~150–250 MB) e kimi-code (~250 MB+) estão na fronteira da mesma categoria de peso — sua ordem relativa está dentro da margem.


---

## História de origem

Abri o monitor do sistema e fiquei horrorizado. Duas instâncias do opencode devoravam **1 GB de RAM**. Cinco chats do kimi-code faziam o mesmo — porque cada um arrastava consigo um runtime completo de Node.js.

Lembrei de 2007. Minha mãe me comprou **512 MB de RAM** para que eu pudesse jogar *S.T.A.L.K.E.R.: Shadow of Chernobyl* — um jogo 3D completo que rodava numa máquina com 1 GB de RAM. E agora, em 2026, não conseguimos rodar dois chats em 1 GB. Quê? **O mundo enlouqueceu.**

Pior — esses "chats" custam a chamar de **software de verdade**. São protótipos de software com funcionalidades enxertadas. Software real não pode ser tão horrível em performance. E o mais assustador: são **protótipos eternos**. Soluções temporárias eternas, entregues como produtos acabados.

Depois outros desenvolvedores recorrem ao Rust para construir agentes. Rust é uma linguagem onde você briga com o compilador em vez de construir coisas — o extremo oposto. E a piada: os concorrentes em Rust ficam em **~10× a memória do HCode em repouso**.

Então peguei o agente em TypeScript da Moonshot-AI como base e reescrevi sua lógica em Crystal, com a ajuda do Kimi 2.6 e do GLM 5. Primeiros resultados: **~3 MB em repouso** contra os ~200 MB do kimi-code. O loop principal já funcionava. O consumo de pico subiu depois — até ~130 MB — o que é horroroso para um bloco de notas-chat, mas ainda menos que o kimi-code em repouso.

**Essa brecha é o que o HCode existe para fechar.**

---

## Por que existe

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

---

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
