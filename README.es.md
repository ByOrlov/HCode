# H2Code — Vibe-code hasta en una patata

[English](./README.md) · [Русский](./README.ru.md) · **Español** · [中文](./README.zh.md) · [日本語](./README.ja.md) · [Português](./README.pt.md) · [हिन्दी](./README.hi.md) · [فارسی](./README.fa.md) · [Українська](./README.uk.md) · [Беларуская](./README.be.md)

> **~3 MB de RAM por agente en reposo. Un único binario estático. Cero runtime. GPL para siempre.**
> Un agente de IA más ligero que el aire, por Orlov — ligero como el hidrógeno: **H** del elemento más ligero, **Code** de lo que entregas.

Linux y macOS

```sh
curl -fsSL https://raw.githubusercontent.com/ByOrlov/H2Code/main/install.sh | bash
```

Windows

```powershell
irm https://raw.githubusercontent.com/ByOrlov/H2Code/master/install.ps1 | iex 
```

**Crystal 1.14 · GPL-2.0-or-later · Binario nativo · Sin runtime**

---

### Memoria, ordenada

De pluma a peso pesado.

| # | Agente      | Lenguaje   | RAM en reposo    | Licencia            | Fuente |
|---|-------------|------------|------------------|---------------------|--------|
| 1 | **H2Code**   | **Crystal**| **~3 MB**        | **GPL-2.0-or-later**| [1]    |
| 2 | grok-build  | Rust       | ~20 MB           | Apache-2.0          | [3]    |
| 3 | Codex CLI   | Rust       | ~30 MB           | Apache-2.0          | [2]    |
| 4 | Goose       | Rust + TS  | ~50–100 MB (est) | Apache-2.0          | [4]    |
| 5 | Claude Code | TS / Node  | ~120 MB (crece)  | propietaria         | [7]    |
| 6 | Aider       | Python     | ~150–250 MB(est) | Apache-2.0          | [6]    |
| 7 | kimi-code   | TS / Node  | ~250 MB+         | MIT                 | [5]    |
| 8 | opencode    | TS / Bun   | ~400 MB          | MIT                 | [8]    |

**La brecha.** H2Code se sitúa ~7× por debajo del agente en Rust más cercano (grok-build), ~40× por debajo del agente Node más ligero (Claude Code), ~80× por debajo de kimi-code y **~130× por debajo de opencode.** La familia Node cubre un rango enorme — desde ~120 MB hasta ~400 MB — porque cada uno incluye un runtime V8 por proceso y crece con el uso. Los agentes en Rust (Codex, grok-build, Goose) son nativos y ligeros; H2Code les sigue el ritmo en RAM y les gana en legibilidad y licencia (ver [¿Por qué Crystal?](#por-qué-crystal)).

> Aider (est. ~150–250 MB) y kimi-code (~250 MB+) están en la frontera de la misma categoría de peso — su orden relativo está dentro del margen.


---

## Historia de origen

Abrí el monitor del sistema y me horroricé. Dos instancias de opencode devoraban **1 GB de RAM**. Cinco chats de kimi-code hacían lo mismo — porque cada uno arrastraba consigo un runtime completo de Node.js.

Recordé 2007. Mi madre me compró **512 MB de RAM** para que pudiera jugar a *S.T.A.L.K.E.R.: Shadow of Chernobyl* — un juego 3D completo que corría en una máquina con 1 GB de RAM. Y ahora, en 2026, no podemos correr dos chats en 1 GB. ¿Qué? **El mundo se ha vuelto loco.**

Peor — a estos "chats" les cuesta llamarse **software de verdad**. Son prototipos de software con funciones atornilladas. El software real no puede ser tan horroroso en rendimiento. Y lo más aterrador: son **prototipos eternos**. Soluciones temporales eternas, entregadas como productos acabados.

Luego otros desarrolladores recurren a Rust para construir agentes. Rust es un lenguaje donde peleas con el compilador en vez de construir cosas — la otra cara de la moneda. Y el remate: los competidores en Rust se sitúan en **~10× la memoria de H2Code en reposo**.

Así que tomé el agente en TypeScript de Moonshot-AI como base y reescribí su lógica en Crystal, con ayuda de Kimi 2.6 y GLM 5. Primeros resultados: **~3 MB en reposo** frente a los ~200 MB de kimi-code. El bucle principal ya funcionaba. El consumo pico subió después — hasta ~130 MB — lo cual es horroroso para un bloc de notas-chat, pero todavía menos que kimi-code en reposo.

**Esa brecha es lo que H2Code existe para cerrar.**

---

## Por qué existe

Lanza cinco agentes de código en paralelo. Mira tu RAM. Cada agente que incluye un runtime de Node.js lo paga — por proceso, para siempre. Cada proceso H2Code se sitúa en torno a **3 MB residentes** mientras espera el siguiente prompt — no 120, no 250, no 400 MB. Tu editor mantiene su presupuesto de memoria. Tu portátil se mantiene fresco. El SO deja de hacer swapping. Por fin puedes correr un enjambre de agentes en la máquina que ya tienes.

> Los agentes en Rust — Codex, grok-build, Goose — también son nativos y ligeros. Contra ellos la ventaja de H2Code no es la RAM, es la **legibilidad y la licencia**. Ver [El panorama](#el-panorama) más abajo.

---

## ¿Por qué Crystal?

Miramos con detenimiento Rust, Go y TypeScript. Cada uno nos obligaba a un compromiso con el que no queríamos vivir. Crystal es el primer lenguaje que nos permitió mantener las tres victorias a la vez.

- 🦀 **Tan seguro como Rust, con sintaxis que un humano puede leer.** Tipado estático, seguridad frente a nil, tipos unión, genéricos y un sistema de macros — pero el código se lee como Ruby y corre como C. Sin borrow checker que convierta cada refactor en un problema de investigación. Los dos agentes nativos más aclamados — **Codex** de OpenAI y **grok-build** de xAI — están escritos en Rust, y su código fuente demuestra el coste: rápidos y seguros, pero añadir una herramienta significa pelear con los lifetimes durante una semana. La capa de herramientas de Crystal es un archivo que lees en una tarde.
- 🐹 **Tan ligero como Go, sin el boilerplate.** Fibers y canales estilo CSP, compilaciones inferiores al segundo, binarios estáticos únicos — pero sin `if err != nil` en cada línea. Escribes la función, no la ceremonia.
- 🟦 **Tan capaz como TypeScript, sin un runtime de Node.js por proceso.** Crystal compila ahead-of-time a un binario nativo LLVM. No hay heap de V8, no hay calentamiento de JIT, no hay event loop duplicado dentro de cada agente. Menos copia de memoria, menos congelaciones del sistema, arranques en frío de milisegundos.

**Un lenguaje. Tres victorias. Cero runtime.**

---

## Compilar desde la fuente

Si prefieres compilar H2Code tú mismo, necesitas Crystal ≥ 1.14 y ripgrep (`rg`):

```sh
# Instala Crystal ≥ 1.14 — https://crystal-lang.org/install/
brew install crystal          # macOS
# sudo pacman -S crystal      # Arch
# consulta la docs para Debian/Ubuntu/Windows

# Instala ripgrep (necesario para las herramientas Grep y Glob)
brew install ripgrep            # macOS
# sudo apt-get install ripgrep  # Debian/Ubuntu
# sudo pacman -S ripgrep        # Arch

# Compilación
git clone https://github.com/ByOrlov/H2Code
cd H2Code
shards install
rake build            # → ./h2code (flags de release)

# Prueba tus credenciales
./h2code --hi

# Headless — prompt de un solo disparo, salida en streaming a stdout
./h2code -p "explain this repo's entry point"

# TUI interactiva
./h2code
```

---

### Libertad

La memoria es la mitad de la historia. La otra mitad: quién posee el código, dónde tienes permitido ejecutarlo y adónde van realmente tus prompts.

| Agente      | Licencia            | Bloqueo por país | Router forzado  | Endpoint propio (BYO) |
|-------------|---------------------|------------------|-----------------|----------------------|
| Claude Code | propietaria         | sí               | sí (Anthropic)  | no                   |
| Codex CLI   | Apache-2.0          | sí               | sí (OpenAI)     | no                   |
| grok-build  | Apache-2.0          | parcial          | xAI por defecto | parcial              |
| Goose       | Apache-2.0          | no               | no              | sí                   |
| Aider       | Apache-2.0          | no               | no              | sí                   |
| opencode    | MIT                 | no               | no              | sí                   |
| kimi-code   | MIT                 | no               | Moonshot        | sí                   |
| **H2Code**   | **GPL-2.0-or-later**| **no**           | **no**          | **sí**               |


## Licencia

H2Code se publica bajo **GPL-2.0-or-later**.

Copyright © 2026 **Oleg Orlov** <orelcokolov@gmail.com> · byorlov.com.
All rights reserved. Consulta [LICENSE](./LICENSE) para el texto completo.

> **¿Por qué GPL-2.0 y no MIT?** opencode y kimi-code son ambos MIT — cualquiera puede absorberlos en un producto cerrado y no devolver nunca nada. H2Code es copyleft: cada derivado debe publicar su fuente bajo los mismos términos. La comunidad siempre tiene una versión libre y utilizable que no se puede volver a cerrar.
>
> **Doble licencia.** Los derechos de autor los posee únicamente el autor, por lo que el proyecto puede ofrecer adicionalmente una licencia comercial separada a quienes necesiten evitar el copyleft de GPL (p. ej. integrar H2Code dentro de un producto cerrado). Para mantener esa opción viable, las contribuciones externas requieren un CLA que concede al autor una licencia para relicenciar. Ver [CONTRIBUTING.md](./CONTRIBUTING.md).

---

## Contribuir

Las PR son bienvenidas — por favor firma el CLA para que el proyecto pueda mantener viables tanto la GPL como la licencia comercial. Ver [CONTRIBUTING.md](./CONTRIBUTING.md).
