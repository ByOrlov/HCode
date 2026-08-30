# AgentSwarm — план портирования из JS в Crystal

> Источник: `packages/agent-core-v2/src/agent/swarm/tools/agent-swarm.ts`
> + `sessionSwarm.ts`, `swarmService.ts`, `swarmOps.ts`, `swarm.ts`, `agent-swarm.md`,
>   `enter-reminder.md`, `exit-reminder.md`.

Цель — тул `AgentSwarm` в `h2code.cr/src/tools/agent_swarm.cr` с **идентичным**
LLM-контрактом (имя, описание, JSON Schema, правила валидации, формат XML-вывода).
Полноценная интеграция с session-swarm coordinator'ом вынесена отдельно (см. раздел
«Интеграция»), сам тул должен оставаться чистым: парсинг, валидация, рендер.

---

## 1. Контракт тула (JS → Crystal)

| Поле           | JS (`AgentSwarmTool`)                                       | Crystal (`Tools::AgentSwarm`)                          |
|----------------|-------------------------------------------------------------|---------------------------------------------------------|
| `name`         | `'AgentSwarm' as const`                                     | `"AgentSwarm"`                                          |
| `description`  | `AGENT_SWARM_DESCRIPTION` (`agent-swarm.md?raw`)            | Текст из `agent-swarm.md` (константа)                   |
| `parameters`   | `toInputJsonSchema(AgentSwarmToolInputSchema)` (zod → JSON) | Эквивалентная JSON Schema (через `JSON.parse`)          |
| `execute`      | `resolveExecution(args).execute(ctx)`                       | `execute(input : JSON::Any) : ToolResult`               |

### 1.1. `description` — точный текст `agent-swarm.md`

```
Launch multiple subagents from one prompt template, existing agent resumes, or both.

Use AgentSwarm when many subagents should run the same kind of task over different inputs. The placeholder is exactly `{{item}}`. For example, with `prompt_template` set to `Review {{item}} for likely regressions.` and `items` set to `["src/a.ts", "src/b.ts"]`, AgentSwarm launches two new subagents with those two concrete prompts. For a few differently-shaped tasks, make separate `Agent` calls in one message instead.

Use `resume_agent_ids` to continue subagents that already exist from earlier work, such as ones that failed or timed out: map each agent id to the prompt for that resumed subagent (usually `continue` if no extra information is needed). You may combine `resume_agent_ids` with `items` in the same call to resume existing subagents and launch new ones. Do not duplicate resumed work in `items`.

Each of these is enforced — a violation is rejected before any subagent starts: provide at least 2 `items` unless you pass `resume_agent_ids`; whenever `items` are present, `prompt_template` is required and must contain `{{item}}`; and the filled-in prompts must be distinct (two items that expand to the same prompt are rejected).

Use enough subagents to keep the work focused and parallel. AgentSwarm supports up to 128 subagents, and launches are queued automatically, so it is safe to split large tasks into many clear, independent items.

If `AgentSwarm` is called, that call must be the only tool call in the response.
```

### 1.2. `parameters` — JSON Schema (zod → JSON Schema)

Поля (object, strict):

| Поле                | Тип                                    | Required | Описание                                                                                  |
|---------------------|----------------------------------------|----------|-------------------------------------------------------------------------------------------|
| `description`       | `string` (trim, min 1)                 | ✅        | Short description for the whole swarm.                                                    |
| `subagent_type`     | `string` (trim, min 1)                 | ❌        | Defaults to `coder`. Resumed subagents keep their original type.                          |
| `prompt_template`   | `string` (trim, min 1)                 | ❌        | Обязателен при `items`. Должен содержать `{{item}}`.                                      |
| `items`             | `array<string>` (max 128, trim, min 1) | ❌        | Значения для подстановки `{{item}}`. Каждый → новый субагент.                             |
| `resume_agent_ids`  | `object<string,string>`                | ❌        | Map `agent_id → resume prompt`. Resume запускается **до** новых item-субагентов.          |

`additionalProperties: false`.

### 1.3. Константы (1:1 из `agent-swarm.ts`)

| Имя                              | Значение   |
|----------------------------------|------------|
| `DEFAULT_SUBAGENT_TYPE`          | `"coder"`  |
| `PROMPT_TEMPLATE_PLACEHOLDER`    | `"{{item}}"` |
| `MAX_AGENT_SWARM_SUBAGENTS`      | `128`      |

---

## 2. Функции JS версии → Crystal-эквиваленты

### 2.1. `createAgentSwarmSpecs(args, getResumeItem)` → `AgentSwarm.build_specs`

Вход: `AgentSwarmToolInput`, колбэк `getResumeItem(agent_id) -> String?`.
Возвращает массив `AgentSwarmSpec` (Spawn | Resume), порядок: сначала resume, потом items.

**Правила валидации** (выполняются ДО запуска любого субагента):

1. `resume_count == 0 && item_count < 2` → throw `"AgentSwarm requires at least 2 items unless resume_agent_ids is provided."`
2. `total_count > 128` → throw `"AgentSwarm supports at most 128 subagents."`
3. Если `items` есть, но `prompt_template` пуст/отсутствует → throw `"prompt_template is required when items are provided."`
4. Если `prompt_template` есть, но не содержит `{{item}}` → throw `"prompt_template must include the {{item}} placeholder."`
5. Дубликат готового prompt'а (две item, расширившиеся в один и тот же текст) → throw `"Duplicate subagent prompts from items {N} and {M}. AgentSwarm requires distinct subagents."`

**Поля spec:**

```crystal
abstract struct AgentSwarmSpec
  getter index : Int32
  getter prompt : String
  property item : String?
end

struct Spawn < AgentSwarmSpec    # kind: "spawn"
struct Resume < AgentSwarmSpec   # kind: "resume"; getter agent_id : String
```

`index` начинается с 1 и считается сквозным по массиву specs.

### 2.2. `hasMinimumAgentSwarmInputs(itemCount, resumeCount)` → `AgentSwarm.has_minimum_inputs?`

`resumeCount > 0 || itemCount >= 2`.

### 2.3. `childDescription(swarmDescription, index, profileName)` → `AgentSwarm.child_description`

`"#{swarmDescription} ##{index} (#{profileName})"`.

### 2.4. `renderSwarmResults(results)` → `AgentSwarm.render_results`

Рендерит XML-подобный блок:

```
<agent_swarm_result>
<summary>completed: N, failed: M[, aborted: K]</summary>
[<resume_hint>Call AgentSwarm with resume_agent_ids using the agent_id values in this result to continue unfinished work.</resume_hint>]
<subagent[ mode="resume"][ agent_id="..."][ item="..."][ state="..."] outcome="completed|failed|aborted">{body}</subagent>
...
</agent_swarm_result>
```

Где:
- `summary` — `completed: N`/`failed: M`/`aborted: K`, каждый только если > 0, через `, `.
- `resume_hint` выводится когда есть **одновременно**: хотя бы один не-completed результат **и** хотя бы один результат с `agent_id != nil`.
- `mode="resume"` — только для `Resume`-спецификаций.
- `agent_id` — присутствует только если есть (заполнен coordinator'ом).
- `item` — присутствует только если есть в спецификации; **экранируется** под XML (`&` → `&amp;`, `"` → `&quot;`, `<` → `&lt;`, `>` → `&gt;`).
- `state` — присутствует только если есть (`started` | `not_started`).
- `body` = `result.result` если status `completed`, иначе `result.error ?? "unknown error"`.

### 2.5. `renderSwarmSummary(completed, failed, aborted=0)` → `render_summary`

Массив `["completed: N", "failed: M", "aborted: K"]` (только ненулевые), `join(", ")`.

### 2.6. `escapeXmlAttribute(value)` → `escape_xml_attribute`

`&` → `&amp;`, `"` → `&quot;`, `<` → `&lt;`, `>` → `&gt;`. Порядок важен — `&` первым.

### 2.7. `normalizeOptionalString(value)` → `normalize_optional_string`

`nil` → `nil`. Иначе `trim`. Если `empty?`, то `nil`, иначе обрезанное значение.

---

## 3. `IAgentSwarmService` — swarm mode (Опционально для Crystal)

Простой in-memory флаг swarm-mode. JS хранит через wire Ops + SystemReminder;
для Crystal достаточно поля `@swarm_trigger : SwarmModeTrigger?` + двух методов:

| JS (`AgentSwarmService`)        | Crystal                                                              |
|---------------------------------|----------------------------------------------------------------------|
| `enter(trigger)`                | `enter(trigger : SwarmModeTrigger)` — устанавливает флаг, добавляет `enter-reminder` как injection в `Context::Memory` (если trigger != `tool`) |
| `exit()`                        | `exit()` — снимает флаг, удаляет последний injection если он swarm_mode, иначе добавляет `exit-reminder` |
| `isActive`                      | `active?`                                                            |
| auto-exit на `turn.ended`       | вызывается из `Loop::Agent#run_turn` перед возвратом (если trigger ∈ `task`, `tool`) |

`SwarmModeTrigger = Manual | Task | Tool`.

---

## 4. Интеграция с `Context::Memory` и `Loop::Agent`

Для контракта тула — не требуется. Тулу достаточно:

1. Принять input, провалидировать (см. §2.1).
2. Построить specs (см. §2.1).
3. Если есть инжекченный **runner** (колбэк `(spec) -> SwarmRunResult`) — запустить все specs параллельно (через `Fiber` + `Channel`), собрать результаты в порядке specs.
4. Если runner'а нет — вернуть единое `ToolResult.error("AgentSwarm is not available: no subagent runtime is registered in this build.")`.
5. Отрендерить XML (см. §2.4) и вернуть как `ToolResult.success(xml)`.

Подключение runner'а:

```crystal
class AgentSwarm < Tool
  def self.runner=(r : SwarmRunner?)
    @@runner = r
  end
  def self.runner : SwarmRunner?
    @@runner
  end
end

alias SwarmRunner = AgentSwarmSpec, String, SwarmRunContext -> SwarmRunResult
```

Это позволит позже подключить `Loop::Agent` как subagent runtime, не меняя контракт тула.

---

## 5. План реализации (чек-лист)

- [x] Прочитать JS версию `agent-swarm.ts`, `sessionSwarm.ts`, `swarmService.ts`, `swarmOps.ts`, `swarm.ts`, `agent-swarm.md`, `enter-reminder.md`, `exit-reminder.md`.
- [x] Описать контракт в `md-tools/swarm.md`.
- [x] Реализовать структуру `AgentSwarmSpec` (Spawn / Resume) + `SwarmRunResult`.
- [x] Реализовать класс `Tools::AgentSwarm < Tool`:
  - [x] `name`, `description` (как `DESCRIPTION`), `parameters`.
  - [x] `execute(input)` → парсинг в `AgentSwarmInput`.
  - [x] Валидация входа (5 правил из §2.1) → `ToolResult.error(...)` при нарушении.
  - [x] Построение specs (resume → spawn, индексация с 1).
  - [x] Рендер XML-вывода (`render_results`, `render_summary`, `escape_xml_attribute`).
  - [x] Интеграция с опциональным `@@runner` (если не задан — единая ошибка).
- [x] Зарегистрировать тул в `Tools::Registry` (`src/h2code.cr`).
- [x] Тесты в `spec/tools/agent_swarm_spec.cr` (14 примеров, все зелёные):
  - [x] Ошибка при `items.size < 2` без `resume_agent_ids`.
  - [x] Ошибка при `items` без `prompt_template`.
  - [x] Ошибка при `prompt_template` без `{{item}}`.
  - [x] Ошибка при дубликате item-промптов.
  - [x] Успешный рендер `<agent_swarm_result>` с N completed / M failed.
  - [x] `resume_hint` появляется только когда есть failures и есть agent_id.
  - [x] Экранирование спецсимволов в `item` XML-атрибуте.
  - [x] Порядок resume-then-spawn и сквозная 1-индексация.
  - [x] `state`-атрибут появляется только когда runner его вернул.
  - [x] `subagent_type` по умолчанию `coder`.
- [x] Обновить `FIX-TOOLS.md`: отметить строку #2 выполненной.

---

## 6. Расхождения / допущения

- В JS `execute` оборачивается в `try/catch` и возвращает `isError: true` на любом throw.
  В Crystal — `rescue ex : ...` с тем же поведением.
- В JS `display.kind: 'agent_call'` идёт в `ToolExecution.display` — у Crystal такого
  поля нет (`ToolResult` только `content` / `is_error` / `truncated?`). Опущено без потери
  контракта — это UI-метаданные, которые Crystal TUI пока не использует.
- `approvalRule: this.name` / `accesses: ToolAccesses.all()` — Crystal `Permission::Manager`
  уже использует `tool.name` как правило по умолчанию; отдельной настройки не нужно.
- `signal: AbortSignal` — Crystal использует `AbortController`, который уже передаётся в
  `Tool#execute` через контекст выполнения (см. `ToolBatch`). При появлении runner'а он
  получит доступ к контроллеру.
