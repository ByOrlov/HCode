# TOOLS-LEAKS — Фикс удержания памяти в Read/Edit и смежных тулзах

Состояние: план согласован 2026-07-19. Симптом: пик ~80 МБ, рост — в основном
после вызовов Read и Edit. Причина — не утечка в C-смысли (Boehm GC работает),
а **retention**: файл-контент не вытесняется из долгоживущих структур.

## A. Подтверждённые источники retention

| ID | Где | Что хранится | Вытеснение |
|---|---|---|---|
| **A1** | `src/loop/dedup.cr:6-35` `DedupTracker @call_history` | Для каждого tool-call — кортеж `{tool, canonical_args}`. Для Edit/Write это полный `old_string`+`new_string`/`content` (через `canonicalize` в `tool_batch.cr:92,186-194`). | **Нет.** `reset_step` — пустой стаб. Растёт монотонно до конца процесса. |
| **A2** | `src/context/memory.cr:18` `Memory @history` | Каждый Read < 50 КБ — целиком; `ToolCall.arguments` с полным args Edit/Write. | Только compaction при 90 % контекста. До этого — монотонный рост до ~1 МБ. |
| **A3** | `src/permission/manager.cr:44,71,87` `@session_approvals` | Ключ `"#{tool}:#{args}"` при выборе «Approve for session». | **Нет.** Только manual-режим + ApproveSession. |

## B. Вторичные (bounded / мелкие)

- **B1.** `TUI::App @messages` (`app.cr:68`) — trimming в пределах turn
  (`merge_turn_steps`), между turn-ами не компактится.
- **B2.** `TUI::Editor @history` (`editor.cr:7,125`) — отправленные промпты, без cap.

## C. Проверено, не источник

`ToolResult`/`ToolDisplay` (стек-локальные), `Context::Undo` (in-place),
`Session::Store` (читает с диска), LLM-провайдеры (фреш-массив на `chat`),
`@previous_lines`, `CharWidth @@width_cache` (FIFO 4096), `Bash` IO buffers,
`TodoList`, `Cron`, `Event`.

---

## План реализации

### Fix 1 — DedupTracker: SHA256 + ring buffer (`src/loop/dedup.cr`)

Заменить хранилище кортежей на хэш-суммы и ограничить FIFO-кольцом.

```crystal
require "openssl"

MAX_STREAK  = 12
MAX_HISTORY = 24   # NEW: ring cap per tool

@call_history : Hash(String, Array(String)) = {} of String => Array(String)

def check_and_track(tool_name, canonical_args) : DedupAction
  key    = tool_name
  digest = OpenSSL::Digest.new("SHA256").update(canonical_args).hexstring
  history = @call_history[key]? || [] of String

  streak = 0
  history.reverse_each do |d|
    break if d != digest
    streak += 1
  end

  history << digest
  history.shift if history.size > MAX_HISTORY
  @call_history[key] = history

  new_streak = streak + 1
  # ... без изменений: ForceStop / FinalWarning / DecisionMenu / Reminder / Allow
end
```

**Эффект:** `N × 2c` chars навсегда → `24 × 64 байт` на инструмент.

### Fix 2 — Permission cache: SHA256 (`src/permission/manager.cr:71,87`)

```crystal
require "openssl"

cache_key = "#{tool_name}:#{OpenSSL::Digest.new("SHA256").update(args).hexstring}"
```

Только 2 точечные замены. Поведение ApproveSession сохранено (тот же args →
тот же ключ → повторный approve не запрашивается).

### Fix 3 — ОТМЕНЁН (mid-session eviction)

Реализован и протестирован, но **откатан назад** после ревизии рисков:
поведенческая регрессия — модель видит `<tool result evicted to save context>`
вместо содержимого старых Read-ов и может пере-запрашивать тулзы.
В типовой сессии выигрыш не оправдывает риск.

Исходный код:
- `src/context/memory.cr` — `evict_old_tool_results` метод **удалён**
- `src/loop/agent.cr` — env `HCODE_CONTEXT_EVICT_PERCENT` и порог **удалены**

Альтернатива: при реальной нехватке памяти работает compaction на 90 %
(через summariser), которая сохраняет смысловой контекст вместо тэга.

### Fix 4 — TUI cross-turn trim (`src/tui/app.cr:2690`, метод `merge_turn_steps`)

Расширить существующий метод: после обрезки в текущем turn-е — второй
проход по старым turn-ам. Сравнивает позиции user-сообщений, последние
`KEEP_RECENT_TURNS = ENV["HCODE_TUI_KEEP_RECENT_TURNS"]?&.to_i? || 50`
оставляет нетронутыми, более старые — схлопывает в один `step_summary`
на turn (счётчик thinking/tool уже поддерживается структурой).

### Fix 5 — Benchmark `benchmarks/dedup_retention_benchmark.cr`

По образцу `edit_memory_benchmark.cr` (переиспользовать `rss_mb`/`measure`):

1. 50 итераций `dedup.check_and_track("Edit", args)` где `args` = 200 КБ JSON.
   Замеры: `Baseline` / `After 50 dedup calls` / `After GC.collect`.
   Ожидаемо: до фикса — рост ~10 МБ; после — рост < 100 КБ.
2. 50 итераций `permission.check` через mock approve_session для 200 КБ args.
   Аналогичные замеры.

---

## Trade-offs / риски

| Правка | Риск | Митигация |
|---|---|---|
| 1 (SHA256 в dedup) | Коллизия SHA256 → ложный «повтор». ~10⁻⁴⁷ на call. | Приемлемо. Поведение для разных args идентично. |
| 2 (SHA256 в approval) | Один и тот же args повторно не спросит — это и есть смысл ApproveSession. | Поведение сохранено. |
| 3 (eviction 70 %) | **ОТМЕНЕН** — модель теряет контент старых Read-ов, может пере-запрашивать тулзы. Compaction на 90 % достаточна. | — |
| 4 (cross-turn trim) | Старые шаги в UI сворачиваются в одну строку. | `step_summary` уже умеет показывать «thinking N times, tool M times». Env для cap. |

## Спеки

- `spec/loop/dedup_spec.cr` — ring cap (25+ вызовов → размер == 24),
  SHA256-детект повтора (одинаковые args → тот же streak).
- `spec/permission/manager_spec.cr` — same args после ApproveSession →
  повторный approve не запрашивается; разные args → запрашивается.
- `spec/context/memory_evict_spec.cr` — ~~удалён вместе с Fix 3~~.
- `spec/tui/app_merge_turns_spec.cr` — 60 user-сообщений + 60 tool → после
  merge остаётся ≤ ~50 turn-ов + summary на каждый старый.

## Порядок применения

1. Fix 1 (DedupTracker) — наибольший эффект для Edit.
2. Fix 2 (Permission) — точечный, дешёвый.
3. ~~Fix 3 (Memory eviction)~~ — **отменён** (поведенческая регрессия).
4. Fix 4 (TUI cross-turn) — для долгих сессий.
5. Specs на каждую правку.
6. Benchmark, замер до/после.
