# Cron tools — план портирования из JS в Crystal

> Источник: `packages/agent-core-v2/src/session/cron/`:
> `tools/cron-create.ts` + `.md`, `tools/cron-list.ts` + `.md`,
> `tools/cron-delete.ts` + `.md`,
> `sessionCronService.ts` (contract), `sessionCronServiceImpl.ts` (impl),
> `cronOps.ts`, а также `packages/agent-core-v2/src/app/cron/`:
> `cron-expr.ts` (parser + cronToHuman + computeNextCronRun +
> hasFireWithinYears), `cronTask.ts` (CronTask type), `format.ts`
> (formatLocalIsoWithOffset).

Цель — 3 тула в `kimi.cr/src/tools/cron.cr` (`Tools::CronCreate`,
`Tools::CronList`, `Tools::CronDelete`) + минимальная `SessionCronService`
абстракция. Инфраструктура срабатывания (polling, jitter, coalesce,
stale-авто-удаление) — отдельная задача (см. §6).

---

## 1. Общая модель

```crystal
struct CronTask
  property id : String        # ULID
  property cron : String      # normalized 5-field
  property prompt : String
  property recurring : Bool = true
  property created_at : Int64
  property last_fired_at : Int64?
  property coalesced_count : Int32 = 0
end

struct CronTaskInit
  property cron : String
  property prompt : String
  property recurring : Bool = true
end

struct ParsedCronExpression
  property minute : Range(Int32, Int32) | Set(Int32)
  property hour : Range(Int32, Int32) | Set(Int32)
  property dom : Range(Int32, Int32) | Set(Int32)
  property month : Range(Int32, Int32) | Set(Int32)
  property dow : Range(Int32, Int32) | Set(Int32)
end
```

### Константы

| Имя                                  | Значение                     |
|--------------------------------------|------------------------------|
| `MAX_CRON_JOBS_PER_SESSION`          | `50`                         |
| `MAX_PROMPT_BYTES`                   | `8 * 1024`                   |
| `ONE_SHOT_MAX_FUTURE_MS`             | `350 * 24 * 60 * 60 * 1000`  |
| `MS_PER_DAY`                         | `86_400_000`                 |
| `PROMPT_PREVIEW_BYTES`               | `200`                        |
| `STALE_THRESHOLD_MS`                 | `7 * MS_PER_DAY`             |
| `CRON_ID_PATTERN`                    | `/^(?:[0-9a-f]{8}|[0-9A-HJKMNP-TV-Z]{26})$/i` |

---

## 2. `CronCreate` — контракт

### 2.1. `name`

`"CronCreate"`.

### 2.2. `description` (verbatim, `cron-create.md`)

Полный текст 91 строка — копировать verbatim из
`packages/agent-core-v2/src/session/cron/tools/cron-create.md`.
Ключевые блоки:

- One-shot (`recurring: false`) — для "remind me at X".
- Recurring (`recurring: true`, default) — для cadence.
- **Avoid `:00` / `:30`** когда request approximate.
- Coalesce semantics — только одна delivery при wake-up, с
  `coalescedCount`.
- Cron-fire envelope (XML).
- 7-day stale — auto-delete after final `stale: true` fire.
- Jitter — recurring: forward ≤ min(10% period, 15 min);
  one-shot: backward ≤ 90s если `:00`/`:30`.
- Session lifetime — persists on `kimi resume`.
- Limits: max 50, prompt 8 KiB, no-fire-within-5-years rejected.
- Returned fields: `id`, `cron`, `humanSchedule`, `recurring`,
  `nextFireAt`.
- "Tell the user how to cancel or modify".

### 2.3. `parameters`

```json
{
  "type": "object",
  "properties": {
    "cron": {
      "type": "string",
      "description": "5-field cron expression in local time: \"M H DoM Mon DoW\" (e.g. \"*/5 * * * *\" = every 5 minutes; \"30 14 28 2 *\" = Feb 28 at 2:30pm local — a pinned date like this repeats yearly unless you also pass recurring: false)."
    },
    "prompt": {
      "type": "string",
      "minLength": 1,
      "maxLength": 8192,
      "description": "The prompt to enqueue at each fire time. Limited to 8 KiB (UTF-8)."
    },
    "recurring": {
      "type": "boolean",
      "default": true,
      "description": "true (default) = fire on every cron match until deleted or auto-expired after 7 days. false = fire once at the next match, then auto-delete. Use false for \"remind me at X\" one-shot requests with pinned minute/hour/dom/month."
    }
  },
  "required": ["cron", "prompt"],
  "additionalProperties": false
}
```

### 2.4. Validation flow (`resolveExecution`)

1. **Killswitch**: `cron.is_disabled?` →
   `ToolResult.error("Cron scheduling is disabled (KIMI_DISABLE_CRON=1).")`.
2. **Normalize**: `cron.trim.split(/\s+/).join(" ")`.
3. **Parse**: `parse_cron_expression(normalized)` → rescue →
   `ToolResult.error("Invalid cron expression: #{err.message}")`.
4. **5-year window**: `!has_fire_within_years(parsed, 5, now)` →
   `ToolResult.error("Cron expression #{normalized.inspect} has no fire within 5 years; refusing to schedule.")`.
5. **Session cap**: `cron.list.size >= 50` →
   `ToolResult.error("Cron job cap reached (max 50 per session).")`.
6. **Prompt byte-length**: UTF-8 byte count > 8 KiB →
   `ToolResult.error("Prompt exceeds 8192 bytes (got #{n}).")`.
7. **One-shot future check** (`recurring == false`):
   - `first_fire = compute_next_cron_run(parsed, now)`.
   - `first_fire - now > 350 days` →
     `ToolResult.error("One-shot cron #{normalized.inspect} would not fire until #{iso(first_fire)} (more than a year out). ...")`.

### 2.5. `execute`

1. Re-check session cap (race-safe):
   `cron.list.size >= 50` → error.
2. `task = cron.add_task(CronTaskInit.new(cron: normalized, prompt: prompt, recurring: recurring))`.
3. `ideal = compute_next_cron_run(parsed, now)`.
4. `next_fire_at = ideal.nil? ? nil : cron.compute_display_next_fire(task, parsed, ideal)`.
5. `human_schedule = cron_to_human(parsed)`.
6. `cron.emit_scheduled(task)` — telemetry hook.
7. Output (key-value):
   ```
   id: #{task.id}
   cron: #{normalized}
   humanSchedule: #{human_schedule}
   recurring: #{recurring}
   nextFireAt: #{next_fire_at.nil? ? "null" : format_local_iso_with_offset(next_fire_at)}
   ```

### 2.6. Approval / display

- `description: recurring ? "Scheduling cron #{cron}" : "Scheduling one-shot #{cron}"`.
- `approvalRule: literalRulePattern("CronCreate", JSON.stringify({cron, prompt, recurring}))`.
  - **Subject** включает все три поля (для user-confirmation prompt).

---

## 3. `CronList` — контракт

### 3.1. `name`

`"CronList"`.

### 3.2. `description` (verbatim, `cron-list.md`)

Полный текст 54 строки — копировать verbatim из
`packages/agent-core-v2/src/session/cron/tools/cron-list.md`.
Описывает формат записей, stale-флаг, refresh pattern.

### 3.3. `parameters`

Strict-пустой объект:

```json
{
  "type": "object",
  "properties": {},
  "additionalProperties": false
}
```

### 3.4. `preview_prompt(prompt)`

UTF-8 byte-length-based truncation до 200 байт с сохранением границы
codepoint:

```crystal
def preview_prompt(prompt : String) : String
  bytes = prompt.bytes
  return prompt if bytes.size <= 200
  end_idx = 200
  while end_idx > 0 && (bytes[end_idx] & 0b1100_0000) == 0b1000_0000
    end_idx -= 1
  end
  String.new(bytes[0, end_idx]) + "…(truncated)"
end
```

### 3.5. `execute` — формат вывода

```
cron_jobs: 3
id: 01HFG7K5...
cron: */5 * * * *
humanSchedule: every 5 minutes
prompt: "check the deploy"
nextFireAt: 2026-07-18T14:32:11+03:00
recurring: true
ageDays: 2.45
stale: false
---
id: ...
...
```

- Empty: `"cron_jobs: 0\nNo cron jobs scheduled."`.
- Records join with `"\n---\n"`.

### 3.6. `render_record(task, now_ms)`

```crystal
def render_record(task : CronTask, now_ms : Int64) : String
  recurring = task.recurring
  age_ms = now_ms - task.created_at
  age_days = (age_ms.to_f / MS_PER_DAY) rescue 0.0
  stale = cron.stale?(task)

  human_schedule = task.cron
  next_fire_iso = "null"
  begin
    parsed = parse_cron_expression(task.cron)
    human_schedule = cron_to_human(parsed)
    next_fire_ms = cron.get_next_fire_for_task(task.id)
    next_fire_iso = format_local_iso_with_offset(next_fire_ms) unless next_fire_ms.nil?
  rescue
    # defensive: render with raw cron + null next fire
  end

  [
    "id: #{task.id}",
    "cron: #{task.cron}",
    "humanSchedule: #{human_schedule}",
    %(prompt: #{preview_prompt(task.prompt).inspect}),  # JSON-encoded
    "nextFireAt: #{next_fire_iso}",
    "recurring: #{recurring}",
    "ageDays: #{age_days.round(2).to_s}",  # "0.00", "2.45"
    "stale: #{stale}",
  ].join('\n')
end
```

### 3.7. Approval / display

- `approvalRule: "CronList"`. Без subject.
- `description: "Listing scheduled cron jobs"`.

---

## 4. `CronDelete` — контракт

### 4.1. `name`

`"CronDelete"`.

### 4.2. `description` (verbatim, `cron-delete.md`)

Полный текст 43 строки — копировать verbatim из
`packages/agent-core-v2/src/session/cron/tools/cron-delete.md`.
Описывает refresh pattern, irreversibility, call CronList first.

### 4.3. `parameters`

```json
{
  "type": "object",
  "properties": {
    "id": {
      "type": "string",
      "description": "The cron job id (ULID) returned by CronCreate / CronList."
    }
  },
  "required": ["id"],
  "additionalProperties": false
}
```

### 4.4. Validation / ветки

1. **ID shape**: `!CRON_ID_PATTERN.matches?(args.id)` →
   `ToolResult.error("Invalid cron job id #{args.id.inspect} — must be a ULID.")`.
   - Принимает либо 8-hex (`[0-9a-f]{8}`), либо 26-char Crockford Base32
     ULID (`[0-9A-HJKMNP-TV-Z]{26}`, case-insensitive).

### 4.5. `execute`

1. `removed = cron.remove_tasks([args.id])`.
2. `removed.empty?` →
   `ToolResult.error("No cron job with id #{args.id}.")`.
3. `cron.emit_deleted(args.id)` — telemetry.
4. `ToolResult.ok("Deleted cron job #{args.id}.")`.

### 4.6. Approval / display

- `approvalRule: "CronDelete"`.
- `description: "Deleting cron #{args.id}"`.

---

## 5. `SessionCronService` — абстракция

```crystal
abstract class SessionCronService
  abstract def enabled? : Bool
  abstract def disabled? : Bool
  abstract def add_task(init : CronTaskInit) : CronTask
  abstract def remove_tasks(ids : Array(String)) : Array(String)
  abstract def get_task(id : String) : CronTask?
  abstract def list : Array(CronTask)
  abstract def now : Int64
  abstract def stale?(task : CronTask) : Bool
  abstract def get_next_fire_time : Int64?
  abstract def get_next_fire_for_task(task_id : String) : Int64?
  abstract def compute_display_next_fire(task : CronTask, parsed : ParsedCronExpression, ideal_ms : Int64) : Int64?
  abstract def load_from_store(replace : Bool = false) : Nil
  abstract def start : Nil
  abstract def stop : Nil
  abstract def tick : Nil
  abstract def flush_persist : Nil
  abstract def emit_scheduled(task : CronTask) : Nil
  abstract def emit_deleted(task_id : String) : Nil
end
```

### Stale rule

```crystal
def stale?(task : CronTask) : Bool
  return false unless task.recurring
  return false if ENV.has_key?("KIMI_CRON_NO_STALE")
  (now - task.created_at) >= STALE_THRESHOLD_MS
end
```

### Jitter

- **Recurring**: forward offset `<= min(period_ms * 0.1, 15 * 60 * 1000)`.
  Period вычисляется из cron-expression (минимальный inter-fire interval).
- **One-shot**: backward offset `<= 90_000` ms **только если** ideal fire
  lands on `:00` или `:30` minute mark.

Jitter — deterministic per task_id (hash of id → offset), чтобы persisted
state при resume не пересчитывался.

### Persistence

- On session close → save `{session_dir}/cron.json` со списком задач.
- On `kimi resume` → load, восстановить `created_at`, вычислить
  `coalesced_count` для missed fires (только последняя).
- Tasks не переносятся в новый session.

### Firing

- Tick-loop (Fiber + sleep until next fire time).
- Idle-only delivery: инъекция через `Context::Memory#add_injection` с
  XML-envelope `<cron-fire jobId="..." cron="..." recurring="..."
  coalescedCount="N" stale="true|false"><prompt>...</prompt></cron-fire>`.
- Coalesce: если несколько ideal-fire пропущено — одна delivery с
  `coalescedCount = N`.
- Stale auto-delete: на 7-day recurring — одна финальная delivery с
  `stale: true`, затем `remove_tasks([id])`.

---

## 6. cron-expr parser (`parse_cron_expression`)

Подмножество стандартного 5-field cron:

- Fields: `minute hour dom month dow` (в этом порядке).
- Operators: `*`, `*/N`, `N`, `N-M` (range), `N,M,K` (list),
  `N-M/S` (stepped range).
- `dom` и `dow` — OR-семантика (как в Vixie cron): если оба не `*`,
  fire когда **либо** dom **либо** dow совпадает.
- `dow` `0` и `7` — оба Sunday.
- Минимальный inter-fire period (для jitter cap) — вычисляется из
  expression (минимальный шаг хотя бы одной из минут/часов).

### `compute_next_cron_run(parsed, from_ms)`

Возвращает ms-таймстамп следующего матча после `from_ms`, либо nil если
нет в обозримом будущем. Сканирует минута-за-минутой (с early-exit
оптимизациями по полю).

### `has_fire_within_years(parsed, years, from_ms)`

True если `compute_next_cron_run(parsed, from_ms)` и
`next - from_ms <= years * 365 * day_ms`.

### `cron_to_human(parsed)`

Best-effort English:

- `*/N * * * *` → `"every N minutes"`
- `0 N * * *` → `"at N:00 daily"`
- `0 N * * 1-5` → `"at N:00 on weekdays"`
- и т.д. (см. JS impl для полного списка паттернов).

---

## 7. `format_local_iso_with_offset(ms)`

ISO 8601 с numeric offset:

```
2026-07-18T14:32:11+03:00
```

- Local time (через `Time.local` в Crystal).
- Offset в формате `±HH:MM`.
- Не UTC (UTC → `+00:00`).

---

## 8. План реализации (чек-лист)

- [ ] Прочитать JS: `tools/cron-*.ts` + `.md`,
      `sessionCronService.ts`, `sessionCronServiceImpl.ts`,
      `cronOps.ts`, `app/cron/cron-expr.ts`, `app/cron/cronTask.ts`,
      `app/cron/format.ts`.
- [x] Описать контракт в `md-tools/cron.md`.
- [ ] Реализовать `ParsedCronExpression`, `parse_cron_expression` (с
      поддержкой `*`, `*/N`, ranges, lists, stepped ranges, dom/dow OR).
- [ ] Реализовать `compute_next_cron_run` (минутный сканер).
- [ ] Реализовать `has_fire_within_years`.
- [ ] Реализовать `cron_to_human`.
- [ ] Реализовать `format_local_iso_with_offset` (через `Time::Location.local`).
- [ ] Реализовать `SessionCronService` (abstract) + простую
      in-memory impl (`Array(CronTask)` + tick-loop fiber).
- [ ] Реализовать jitter (deterministic hash-based).
- [ ] Реализовать persistence (`cron.json` save/load).
- [ ] Реализовать `Tools::CronCreate` (§2) со всеми ветками валидации.
- [ ] Реализовать `Tools::CronList` (§3) с `preview_prompt` (UTF-8 safe).
- [ ] Реализовать `Tools::CronDelete` (§4) с ULID-shape проверкой.
- [ ] Реализовать cron-fire envelope XML injection в
      `Context::Memory#add_injection` при tick-срабатывании.
- [ ] Реализовать coalesce (single delivery on wake) + stale
      auto-delete.
- [ ] Регистрация тулов в `src/kimi.cr:166` для main agent.
- [ ] Уважать `KIMI_DISABLE_CRON=1` (killswitch).
- [ ] Тесты в `spec/tools/cron_spec.cr`:
  - [ ] CronCreate — parse errors, 5-year reject, cap reached,
        prompt too large, one-shot too far, killswitch, success output
        format, `nextFireAt` formatting.
  - [ ] CronList — empty/non-empty, preview truncation, stale flag,
        ageDays rounding, malformed cron defensive render.
  - [ ] CronDelete — invalid id shape, not-found error, success.
- [ ] Обновить `FIX-TOOLS.md`: отметить строки #16–#18 выполненными.

---

## 9. Расхождения / допущения

- ULID generation — нужна библиотека (`ulid` shard) или собственная
  реализация Crockford-Base32 из 26 chars. Для тестов можно генерить
  short id (8 hex).
- Tick-loop в Crystal — `spawn` + `sleep` с условием прерывания на
  `stop`. В отличие от JS `setInterval`, нет автоматического interrupt;
  использовать `Channel(Nil)` для wake-up.
- `KIMI_CRON_NO_STALE` — env-var disable для stale behavior.
- Доставка cron-fire envelope — через `Context::Memory#add_injection`
  (как skill/plan-mode/task notifications). Помечается
  `MessageOrigin::Injection`.
- Idle-only delivery: scheduler должен знать, есть ли активный turn.
  Hook на Loop runner: `loop.idle?` проверяется перед injection.
- Coalesce count — рассчитывается при wake-up как
  `(now - last_fired_at) / period_ms` clamped to `>= 1`.
- One-shot jitter backward (90s) — применяется только когда `:00`/`:30`,
  для избежания herd.
- В отличие от JS, нет `Buffer.byteLength` — в Crystal
  `String#bytes.size` для UTF-8 byte-length.
- `JSON.generate(prompt)` для JSON-encoding в CronList → в Crystal
  `prompt.to_json` (без outer quoting) или ручной escape.
