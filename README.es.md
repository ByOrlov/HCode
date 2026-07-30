# HCode — Vibe-code hasta en una patata

[English](./README.md) · [Русский](./README.ru.md) · **Español** · [中文](./README.zh.md) · [日本語](./README.ja.md) · [Português](./README.pt.md) · [हिन्दी](./README.hi.md) · [فارسی](./README.fa.md)

> **~3 MB de RAM por agente en reposo. Un único binario estático. Cero runtime. GPL para siempre.**
> Un agente de IA más ligero que el aire, por Orlov — ligero como el hidrógeno: **H** del elemento más ligero, **Code** de lo que entregas.

```sh
brew install crystal && git clone https://github.com/YOU/hcode
cd hcode && shards install && rake build && ./hcode
```

**Crystal 1.14 · GPL-2.0-or-later · Binario nativo · Sin runtime**

---

## TL;DR — por qué existe esto

Cinco agentes de código en paralelo y tu portátil arde. Cinco agentes HCode inactivos consumen **~15 MB en total**. ¿Cinco agentes Node.js? De **600 MB a 2 GB** — garantizado, para siempre, por proceso.

| Configuración                | RAM en reposo  | vs. HCode |
|------------------------------|----------------|-----------|
| 5 × opencode (Node.js)       | **≈ 2 GB**     | **~130×** |
| 5 × kimi-code (Node.js)      | **> 1 GB**     | **~80×**  |
| 5 × Claude Code (Node.js)    | **≈ 600 MB**   | **~40×**  |
| 5 × HCode (Crystal, nativo)  | **≈ 15 MB**    | **1×**    |

Esa es toda la propuesta. Un portátil con diez agentes HCode debería sentirse como uno sin ninguno.

---

## Historia de origen

Abrí el monitor del sistema y me horroricé. Dos instancias de opencode devoraban **1 GB de RAM**. Cinco chats de kimi-code hacían lo mismo — porque cada uno arrastraba consigo un runtime completo de Node.js.

Recordé 2007. Mi madre me compró **512 MB de RAM** para que pudiera jugar a *S.T.A.L.K.E.R.: Shadow of Chernobyl* — un juego 3D completo que corría en una máquina con 1 GB de RAM. Y ahora, en 2026, no podemos correr dos chats en 1 GB. ¿Qué? **El mundo se ha vuelto loco.**

Peor — a estos "chats" les cuesta llamarse **software de verdad**. Son prototipos de software con funciones atornilladas. El software real no puede ser tan horroroso en rendimiento. Y lo más aterrador: son **prototipos eternos**. Soluciones temporales eternas, entregadas como productos acabados.

Luego otros desarrolladores recurren a Rust para construir agentes. Rust es un lenguaje donde peleas con el compilador en vez de construir cosas — la otra cara de la moneda. Y el remate: los competidores en Rust se sitúan en **~10× la memoria de HCode en reposo**.

Así que tomé el agente en TypeScript de Moonshot-AI como base y reescribí su lógica en Crystal, con ayuda de Kimi 2.6 y GLM 5. Primeros resultados: **~3 MB en reposo** frente a los ~200 MB de kimi-code. El bucle principal ya funcionaba. El consumo pico subió después — hasta ~130 MB — lo cual es horroroso para un bloc de notas-chat, pero todavía menos que kimi-code en reposo.

**Esa brecha es lo que HCode existe para cerrar.**

---

## El problema

Lanza cinco agentes de código en paralelo. Mira tu RAM. Cada agente que incluye un runtime de Node.js lo paga — por proceso, para siempre. Cada proceso HCode se sitúa en torno a **3 MB residentes** mientras espera el siguiente prompt — no 120, no 250, no 400 MB. Tu editor mantiene su presupuesto de memoria. Tu portátil se mantiene fresco. El SO deja de hacer swapping. Por fin puedes correr un enjambre de agentes en la máquina que ya tienes.

> Los agentes en Rust — Codex, grok-build, Goose — también son nativos y ligeros. Contra ellos la ventaja de HCode no es la RAM, es la **legibilidad y la licencia**. Ver [El panorama](#el-panorama) más abajo.

---

## ¿Por qué Crystal?

Miramos con detenimiento Rust, Go y TypeScript. Cada uno nos obligaba a un compromiso con el que no queríamos vivir. Crystal es el primer lenguaje que nos permitió mantener las tres victorias a la vez.

- 🦀 **Tan seguro como Rust, con sintaxis que un humano puede leer.** Tipado estático, seguridad frente a nil, tipos unión, genéricos y un sistema de macros — pero el código se lee como Ruby y corre como C. Sin borrow checker que convierta cada refactor en un problema de investigación. Los dos agentes nativos más aclamados — **Codex** de OpenAI y **grok-build** de xAI — están escritos en Rust, y su código fuente demuestra el coste: rápidos y seguros, pero añadir una herramienta significa pelear con los lifetimes durante una semana. La capa de herramientas de Crystal es un archivo que lees en una tarde.
- 🐹 **Tan ligero como Go, sin el boilerplate.** Fibers y canales estilo CSP, compilaciones inferiores al segundo, binarios estáticos únicos — pero sin `if err != nil` en cada línea. Escribes la función, no la ceremonia.
- 🟦 **Tan capaz como TypeScript, sin un runtime de Node.js por proceso.** Crystal compila ahead-of-time a un binario nativo LLVM. No hay heap de V8, no hay calentamiento de JIT, no hay event loop duplicado dentro de cada agente. Menos copia de memoria, menos congelaciones del sistema, arranques en frío de milisegundos.

**Un lenguaje. Tres victorias. Cero runtime.**

---

## Ideología

**La memoria es una característica, no una nota al pie.** La mayoría de frameworks de agentes tratan la RAM como problema de otro. Incluyen un runtime completo de V8, un bundler, un transpilador y un árbol de `node_modules` — y te gravan por cada uno de ellos, por proceso, para siempre. HCode se niega. Un agente inactivo debe ser invisible. Un portátil con diez agentes debería sentirse como uno sin ninguno.

**El protocolo pertenece a todos.** HCode se construye sobre el formato de protocolo OpenAI Chat Completions por SSE. Cualquier endpoint compatible — Moonshot, Z.AI, Zhipu, OpenAI, un modelo local — se enchufa al mismo transporte. Sin dependencia de proveedor. Trae tu propia clave, tu propio modelo, tu propio endpoint, y cámbialos en tiempo de ejecución desde la TUI.

**Código abierto, de forma irrevocable.** HCode es GPL-2.0-or-later. Cada derivado debe publicar su fuente. Puedes estudiarlo, hacerle fork, correrlo en producción, integrarlo en tu producto — siempre que la fuente venga incluida.

---

## Sin fronteras, sin intermediarios

Codex y Claude Code enrutan cada petición a través del backend de pago de su proveedor — lo que también significa que heredan la lista de bloqueo de países de ese proveedor. Instálalos desde la región equivocada y se niegan a arrancar. grok-build es de código abierto, pero con la forma de xAI.

HCode habla el protocolo abierto. Apúntalo a cualquier endpoint compatible con OpenAI — Moonshot, Z.AI, OpenAI, una caja local de Ollama, un modelo en tu propia GPU. **Sin cuenta de proveedor para instalar. Sin "país no soportado". Sin proxy por el que pagas un sobrecargo.** Tu alcance lo limita tu proveedor, nunca el agente.

---

## Características

- 🪶 **Huella minúscula** — ~3 MB residentes por agente inactivo; el Boehm GC arranca desde ~1 MB; cada fiber cuesta ~8 KB de pila.
- 🔌 **Muchos proveedores, un binario** — Moonshot, Z.AI/Zhipu (pay-as-you-go + Coding Plan), y cualquier endpoint compatible con OpenAI. Cambia en caliente desde la TUI sin reiniciar.
- ⚡ **Compilación nativa** — `crystal build` produce un único binario estático. Sin runtime, sin instalador, sin `node_modules`.
- 🧠 **Un bucle de agente real** — streaming SSE, llamadas a herramientas en paralelo vía fibers, desduplicación de llamadas a herramientas con parada forzada de rachas, abort con grace-timeout de 2 segundos, recuperación ante desbordamiento de contexto (413 → degradar → compactación) y persistencia de sesión JSONL solo-append.
- 🛠️ **Herramientas integradas** — Bash, Read, Write, Edit, Glob, Grep, TodoList y un primitivo agent-swarm — con puerta de permisos y detección de peligro.
- 🧵 **Fibers, no procesos** — corre docenas de agentes concurrentes dentro de un proceso, o un binario por agente. Tú eliges el compromiso de aislamiento.
- 💾 **Sesiones reanudables** — log de eventos JSONL solo-append, compatible en disco con la versión TypeScript.
- 🎛️ **TUI interactiva** — markdown en streaming, tarjetas de herramientas, vista previa de diff, editor multilínea, comandos slash, selectores de modelo / proveedor / permisos, selector de sesión.
- 🔒 **GPL-2.0-or-later** — código abierto, no se puede cerrar.

---

## Proveedores

HCode habla el formato de protocolo OpenAI Chat Completions por SSE. **Cualquiera que lo hable, funciona.**

| Proveedor                    | Estado | Notas                                       |
|------------------------------|--------|---------------------------------------------|
| Moonshot                     | ✅     | Backend por defecto. OAuth o API key.       |
| Z.AI / Zhipu (pay-as-you-go) | ✅     | Compatible con OpenAI.                      |
| Z.AI / Zhipu (Coding Plan)   | ✅     | Endpoint por suscripción.                   |
| Cualquiera compatible OpenAI | ✅     | Apunta a cualquier endpoint que hable el protocolo. |
| Mock                         | ✅     | Proveedor guionizado para autotests y demos. |

Cambia en caliente desde la TUI (`/provider`), o fija uno en `~/.hcode/config.toml`.

---

## Inicio rápido

```sh
# Instala Crystal ≥ 1.14 — https://crystal-lang.org/install/
brew install crystal          # macOS
# sudo pacman -S crystal      # Arch
# consulta la docs para Debian/Ubuntu/Windows

# Compilación
git clone https://github.com/YOU/hcode
cd hcode
shards install
rake build            # → ./hcode (flags de release)

# Prueba tus credenciales
./hcode --hi

# Headless — prompt de un solo disparo, salida en streaming a stdout
./hcode -p "explain this repo's entry point"

# TUI interactiva
./hcode
```

Claves por variables de entorno: `MOONSHOT_API_KEY`, `ZAI_API_KEY` / `ZHIPU_API_KEY`, … o bloques `[provider.*]` en `~/.hcode/config.toml`. Las sesiones viven en `~/.hcode/sessions/`; reanúdalas con `-c` o elige una desde la TUI.

---

## El panorama

RSS en reposo, del mundo real. Una mezcla de mediciones del autor, informes de proyectos upstream y estimaciones etiquetadas — cada celda es trazable a una fuente más abajo.

### Memoria, ordenada

De pluma a peso pesado.

| # | Agente      | Lenguaje   | RAM en reposo    | Licencia            | Fuente |
|---|-------------|------------|------------------|---------------------|--------|
| 1 | **HCode**   | **Crystal**| **~3 MB**        | **GPL-2.0-or-later**| [1]    |
| 2 | Codex CLI   | Rust       | ~30 MB           | Apache-2.0          | [2]    |
| 3 | grok-build  | Rust       | ~30–60 MB (est)  | Apache-2.0          | [3]    |
| 4 | Goose       | Rust + TS  | ~50–100 MB (est) | Apache-2.0          | [4]    |
| 5 | Claude Code | TS / Node  | ~120 MB (crece)  | propietaria         | [7]    |
| 6 | Aider       | Python     | ~150–250 MB(est) | Apache-2.0          | [6]    |
| 7 | kimi-code   | TS / Node  | ~250 MB+         | MIT                 | [5]    |
| 8 | opencode    | TS / Bun   | ~400 MB          | MIT                 | [8]    |

**La brecha.** HCode se sitúa ~10× por debajo del agente en Rust más cercano (Codex), ~40× por debajo del agente Node más ligero (Claude Code), ~80× por debajo de kimi-code y **~130× por debajo de opencode.** La familia Node cubre un rango enorme — desde ~120 MB hasta ~400 MB — porque cada uno incluye un runtime V8 por proceso y crece con el uso. Los agentes en Rust (Codex, grok-build, Goose) son nativos y ligeros; HCode les sigue el ritmo en RAM y les gana en legibilidad y licencia (ver [¿Por qué Crystal?](#por-qué-crystal)).

> Aider (est. ~150–250 MB) y kimi-code (~250 MB+) están en la frontera de la misma categoría de peso — su orden relativo está dentro del margen.

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
| **HCode**   | **GPL-2.0-or-later**| **no**           | **no**          | **sí**               |

**Dos historias, un agente.** Contra los agentes Node (opencode, Claude Code, kimi-code), HCode gana en RAM por 40–130×. Contra los agentes Rust (Codex, grok-build, Goose), la brecha de RAM es pequeña — ahí HCode gana en **legibilidad** (sin borrow checker, sintaxis tipo Ruby) y **licencia** (GPL se mantiene abierto para siempre; Apache puede cerrarse). Contra los bloqueados por proveedor (Codex, Claude Code), HCode gana en **libertad**: ni bloqueo de país ni intermediario de pago. HCode es el único agente que es a la vez el más ligero, el nativo más legible, el único copyleft y el único sin ataduras de proveedor.

### Fuentes

- **[1] HCode** — medición del autor, RSS en reposo. Base documentada en [`PLAN.md`](./PLAN.md) (Crystal + Boehm GC, ~1 MB de base de GC, ~8 KB de pila por fiber).
- **[2] Codex CLI** — medición del autor, RSS en reposo (~30 MB). Binario nativo en Rust, [`openai/codex`](https://github.com/openai/codex).
- **[3] grok-build** — sin medición pública; estimación para TUI/harness nativo en Rust. [`xai-org/grok-build`](https://github.com/xai-org/grok-build).
- **[4] Goose** — sin medición pública; estimación para núcleo Rust + UI TS/V8 embebida. [`aaif-goose/goose`](https://github.com/aaif-goose/goose).
- **[5] kimi-code** — medición del autor, ~250 MB+ RSS en reposo (TypeScript / Node.js). Sustituye la estimación de planificación interna en `PLAN.md`.
- **[6] Aider** — sin cifra pública en reposo; estimación para CPython + tree-sitter + dependencias litellm. Crecimiento patológico reportado en [`Aider-AI/aider#573`](https://github.com/Aider-AI/aider/issues/573).
- **[7] Claude Code** — código cerrado. Medición del autor, ~120 MB RSS en reposo; crece con el tiempo por una fuga de memoria nativa ("119.6 MB/hour"): [`anthropics/claude-code#70168`](https://github.com/anthropics/claude-code/issues/70168) y la etiqueta `perf:memory`.
- **[8] opencode** — medición del autor, ~400 MB RSS en reposo (TypeScript / Bun). [`anomalyco/opencode`](https://github.com/anomalyco/opencode).

*El RSS en reposo varía según SO, tamaño del repo y duración de la sesión. Los binarios nativos (Rust/Crystal) son estables; los runtimes (Node/Python) crecen con el uso. Las cifras marcadas (est.) no se midieron en laboratorio — son estimaciones de orden de magnitud para agentes que no publican datos de memoria.*

---

## Consumo de RAM

HCode está diseñado para mantener la memoria acotada por proceso.

### Reposo

~**3 MB de RSS** por agente inactivo. Esto es el runtime de Crystal, la base del Boehm GC y un pequeño estado de TUI. Sin runtime de Node.js/V8 por proceso.

### Pico

Medido en Linux con los benchmarks de `benchmarks/`:

| Escenario | RSS pico | Notas |
|---|---|---|
| 2 000 turnos (5 KB asistente + 50 KB resultado de herramienta, con compactación) | ~37 MB | La TUI solo guarda vistas previas; el historial completo vive en `wire.jsonl` |
| 10 000 llamadas pequeñas a herramientas | ~20 MB | |
| Único resultado de herramienta de 10 MB (Bash `MAX_OUTPUT_BYTES`) | ~31 MB | El contexto guarda la salida completa; la vista previa de TUI es ~1 KB |
| Única respuesta de asistente de 10 MB | ~67 MB | Estrés sintético; una respuesta de 10 MB es mayor de lo que permite la ventana de contexto de 262k tokens |

Un turno típico con un resultado de herramienta de 50 KB son aproximadamente **13 000 tokens**. Con una ventana de contexto de 262 144 tokens, una longitud completa de contexto equivale a unas **20 turnos**. Así que **2 000 turnos ya superan las 10 longitudes completas de contexto** en un único proceso, y el RSS pico se mantiene por debajo de ~40 MB.

### Por qué el RSS puede mantenerse alto tras un pico

El Boehm GC no devuelve las páginas liberadas al SO de inmediato. Tras una gran asignación (p. ej. `request.to_json` sobre un contexto grande) el RSS puede permanecer inflado aunque la memoria `live` haya bajado. Es comportamiento del allocator, no una fuga de objetos de la aplicación.

## Licencia

HCode se publica bajo **GPL-2.0-or-later**.

Copyright © 2026 **Oleg Orlov** <orelcokolov@gmail.com> · byorlov.com.
All rights reserved. Consulta [LICENSE](./LICENSE) para el texto completo.

> **¿Por qué GPL-2.0 y no MIT?** opencode y kimi-code son ambos MIT — cualquiera puede absorberlos en un producto cerrado y no devolver nunca nada. HCode es copyleft: cada derivado debe publicar su fuente bajo los mismos términos. La comunidad siempre tiene una versión libre y utilizable que no se puede volver a cerrar.
>
> **Doble licencia.** Los derechos de autor los posee únicamente el autor, por lo que el proyecto puede ofrecer adicionalmente una licencia comercial separada a quienes necesiten evitar el copyleft de GPL (p. ej. integrar HCode dentro de un producto cerrado). Para mantener esa opción viable, las contribuciones externas requieren un CLA que concede al autor una licencia para relicenciar. Ver [CONTRIBUTING.md](./CONTRIBUTING.md).

---

## Contribuir

Las PR son bienvenidas — por favor firma el CLA para que el proyecto pueda mantener viables tanto la GPL como la licencia comercial. Ver [CONTRIBUTING.md](./CONTRIBUTING.md).
