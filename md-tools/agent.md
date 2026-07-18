# Agent — план портирования из JS в Crystal

> Источник: `packages/agent-core-v2/src/session/subagent/tools/agent.ts`
> + `subagent-task.ts`, `subagent.ts`, `subagentService.ts`, `runAgentTurn.ts`,
>   `mirrorAgentRun.ts`, `agentProfileCatalog/*`, `agent.md`,
>   `agent-background-enabled.md`, `agent-background-disabled.md`,
>   `agentLifecycle/subagentMetadata.ts`, `agent/task/*`,
>   `agent/task/notificationXml.ts`.

Цель — тул `Agent` в `kimi.cr/src/tools/agent.cr` с **идентичным**
LLM-контрактом (имя, описание, JSON Schema, правила валидации, формат вывода)
и опциональным инжекченным `AgentRunner`, отвечающим за фактический запуск
субагента. Сам тул должен оставаться чистым: парсинг, валидация, рендер.

---

## 1. Контракт тула (JS → Crystal)

| Поле           | JS (`AgentTool`)                                              | Crystal (`Tools::Agent`)                                |
|----------------|---------------------------------------------------------------|----------------------------------------------------------|
| `name`         | `'Agent' as const`                                            | `"Agent"`                                                |
| `description`  | динамический getter, см. §1.2                                 | `DESCRIPTION_BASE` + фоновый абзац + блок profiles       |
| `parameters`   | `toInputJsonSchema(AgentToolInputSchema)` (zod → JSON)        | Эквивалентная JSON Schema (через `JSON.parse`)           |
| `execute`      | `resolveExecution(args).execute(ctx)`                         | `execute(input : JSON::Any) : ToolResult`                |

### 1.1. `name`

`"Agent"`.

### 1.2. `description`

JS собирает description динамически по формуле:

```
AGENT_DESCRIPTION_BASE
+ "\n\n"
+ (canRunInBackground ? AGENT_BACKGROUND_ENABLED : AGENT_BACKGROUND_DISABLED)
+ "\n\nAvailable agent types (pass via subagent_type):\n" + buildProfileDescriptions(catalog.list())
```

Где `buildProfileDescriptions` рендерит каждый profile строкой:

```
- <name>: <description> <whenToUse>
  Tools: <t1>, <t2>, ...
```

(части `description` / `whenToUse` / `Tools:` опускаются, когда пусты).

#### 1.2.1. `AGENT_DESCRIPTION_BASE` (verbatim)

```
Launch a subagent to handle a task. The subagent runs as a same-process loop instance with its own context and wire file. Delegating also keeps the bulk of intermediate file contents out of your own context — you get a conclusion back instead of a pile of dumps.

Writing the prompt:
- The subagent starts with zero context — it has not seen this conversation. Brief it like a colleague who just walked into the room: state the goal, list what you already know, hand over the specifics.
- Lookups (read this file, run that test): put the exact path or command in the prompt. The subagent should not have to search for things you already know.
- Investigations (figure out X, find why Y): give the question, not prescribed steps — fixed steps become dead weight when the premise is wrong.
- Do not delegate understanding. If the task hinges on a file path or line number, find it yourself first and write it into the prompt.

Usage notes:
- When the task continues earlier work a subagent already did, prefer resuming that agent (pass its `resume` id) over spawning a fresh instance — the resumed agent keeps its prior context.
- A subagent's result is only visible to you, not to the user. When the user needs to see what a subagent produced, summarize the relevant parts yourself in your own reply.
- Subagents use a fixed 2-hour timeout. If one times out, resume the same agent instead of starting over.

When NOT to use Agent: skip delegation for trivial work you can do directly — reading a file whose path you already know, searching a small known set of files, or any task that takes only a step or two. Delegation has a context-handoff cost; it pays off only when the task is substantial enough to outweigh it.

Once a subagent is running, leave that scope to it: do not redo its searches or reads in parallel, and do not abandon it midway and finish the job manually. Both undo the context savings the delegation was meant to buy.
```

#### 1.2.2. `AGENT_BACKGROUND_ENABLED` (verbatim)

```
When `run_in_background=true`, the subagent runs detached from this turn. The completion arrives in a later turn as a synthetic user-role message containing its result — you do not need to poll, sleep, or check on its progress. Continue with other work or respond to the user. Never fabricate or predict what the result will say.

Default to a foreground subagent (omit `run_in_background`) when your next step needs its result — foreground hands the result straight back. Reach for `run_in_background=true` only when you have other work to do while it runs and do not need its result to proceed. Never launch in the background and then immediately wait on it (with `TaskOutput block=true`, sleeping, or otherwise): that just blocks the turn for no benefit — run it in the foreground instead.
```

#### 1.2.3. `AGENT_BACKGROUND_DISABLED` (verbatim)

```
Background agent execution is disabled for this agent. Do not set `run_in_background=true` — any call that sets it is rejected before the subagent launches. Run every subagent in the foreground and wait for its result.
```

#### 1.2.4. Список встроенных профилей

| name     | description                                              | whenToUse                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | tools                                                                                                                                                                                                                                                                                                              |
|----------|----------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `agent`  | `Default Kimi Code agent`                                | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | `Read, Write, Edit, Grep, Glob, Bash, TaskList, TaskOutput, TaskStop, CronCreate, CronList, CronDelete, ReadMediaFile, TodoList, Skill, WebSearch, Agent, AgentSwarm, FetchURL, AskUserQuestion, EnterPlanMode, ExitPlanMode, CreateGoal, GetGoal, SetGoalBudget, UpdateGoal, mcp__*`                            |
| `coder`  | `General software engineering agent` (полный текст в JS) | `the only subagent type with file-editing tools; use it for any delegated task that must modify code. Use this agent for non-trivial software engineering work that may require reading files, editing code, running commands, and returning a compact but technically complete summary to the parent agent.`                                                                                                                                                                                                                                                                 | `Agent, AgentSwarm, Bash, CronCreate, CronDelete, CronList, Edit, EnterPlanMode, ExitPlanMode, Glob, Grep, Read, ReadMediaFile, Skill, TaskList, TaskOutput, TaskStop, TodoList, WebSearch, FetchURL, Write, mcp__*`                                                                                                |
| `explore`| —                                                        | `Fast codebase exploration with prompt-enforced read-only behavior. Fast agent specialized for exploring codebases. Use this when you need to quickly find files by patterns (e.g. "src/**/*.yaml"), search code for keywords (e.g. "database connection"), or answer questions about the codebase (e.g. "how does the auth module work?"). When calling this agent, specify the desired thoroughness level: "quick" for basic searches, "medium" for moderate exploration, or "thorough" for comprehensive analysis across multiple locations and naming conventions. Use this agent for any read-only exploration that will clearly require more than 3 search queries. Prefer launching multiple explore agents concurrently when investigating independent questions.` | `Bash, Read, ReadMediaFile, Glob, Grep, WebSearch, FetchURL`                                                                                                                                                                                                                                                       |
| `plan`   | —                                                        | `Read-only implementation planning and architecture design. Use this agent when the parent agent needs a step-by-step implementation plan, key file identification, and architectural trade-off analysis before code changes are made.`                                                                                                                                                                                                                                                                                                                                                                                                                | `Read, ReadMediaFile, Glob, Grep, WebSearch, FetchURL`                                                                                                                                                                                                                                                             |

Crystal-порт копирует блок дословно как константу `PROFILES_DESCRIPTION`.

### 1.3. `parameters` — JSON Schema

Поля (object, strict):

| Поле                | Тип       | Required | Default | Описание (verbatim)                                                                                                                                                                                                                                                                                                                                                                                                          |
|---------------------|-----------|----------|---------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `prompt`            | `string`  | ✅        | —       | `Full task prompt for the subagent`                                                                                                                                                                                                                                                                                                                                                                                                        |
| `description`       | `string`  | ✅        | —       | `Short task description (3-5 words) for UI display`                                                                                                                                                                                                                                                                                                                                                                                        |
| `subagent_type`     | `string`  | ❌        | `'coder'` (если и `subagent_type`, и `resume` пусты) | `One of the available agent types (see "Available agent types" in this tool description). Defaults to "coder" when omitted.`                                                                                                                                                                                                                                                                                            |
| `resume`            | `string`  | ❌        | —       | `Optional agent ID to resume instead of creating a new instance. When set, do not also pass subagent_type — the resumed agent keeps its own type, and supplying both is rejected.`                                                                                                                                                                                                                                                          |
| `run_in_background` | `boolean` | ❌        | —       | `If true, return immediately without waiting for completion. Prefer false unless the task can run independently and there is a clear benefit to not waiting.`                                                                                                                                                                                                                                                                                |

`additionalProperties: false`. Нет `minLength`/`maxLength`/`pattern` — все
ограничения императивные в коде.

### 1.4. Препроцессор входа (важно!)

Перед валидацией JS нормализует поля:

1. Если **и** `resume` (тримmed непустой), **и** `subagent_type` (непустой)
   отсутствуют → выставить `subagent_type = "coder"`.
2. Иначе если `subagent_type` пуст/отсутствует, а `resume` присутствует →
   **удалить** `subagent_type` (так `.optional()` схемы видит `undefined`).

В Crystal повторить то же в `execute` перед вызовом `runner`.

---

## 2. Константы (1:1 из `agent.ts` + `configSection.ts`)

| Имя                                       | Значение                                                                                         |
|-------------------------------------------|--------------------------------------------------------------------------------------------------|
| `DEFAULT_PROFILE_NAME`                    | `"coder"` (в отличие от `DEFAULT_AGENT_PROFILE_NAME = "agent"` в каталоге)                        |
| `RESUMED_LABEL`                           | `"subagent"`                                                                                      |
| `BACKGROUND_AGENT_UNAVAILABLE`            | `"Background agent execution is not available for this agent because TaskList, TaskOutput, and TaskStop are not enabled."` |
| `RESUME_WITH_TYPE_UNAVAILABLE`            | `"Cannot set subagent_type when resuming an existing agent. Resume by agent id only."`            |
| `USER_INTERRUPTED_SUBAGENT_MESSAGE`       | `"The subagent was stopped before it finished by user."`                                          |
| `SUBAGENT_STOPPED_MESSAGE`                | `"The subagent was stopped before it finished."`                                                  |
| `DEFAULT_SUBAGENT_TIMEOUT_MS`             | `7_200_000` (2 часа). Env: `KIMI_SUBAGENT_TIMEOUT_MS` (≥ 1).                                       |
| `TASK_ID_PREFIX`                          | `"agent"` (идёт в `AgentTask.idPrefix`)                                                           |
| `USER_CANCELLATION_MESSAGE`               | `"Aborted by the user"`                                                                          |

---

## 3. Валидация (порядок проверок)

Все ошибки возвращаются как `ToolResult.error(...)` (не throw). Порядок:

1. **`resume` + `subagent_type` одновременно** → `RESUME_WITH_TYPE_UNAVAILABLE`.
   (Дублируется внутри `launch` как defense-in-depth.)
2. **`run_in_background == true && !can_run_in_background?`** →
   `BACKGROUND_AGENT_UNAVAILABLE`.
3. (внутри runner) **caller agent handle missing** →
   `"Caller agent \"<callerAgentId>\" does not exist"`.
4. **resume target missing** → `"Agent instance \"<id>\" does not exist"`.
5. **resume target не субагент** → `"Agent instance \"<id>\" is not a subagent"`.
6. **resume target не от этого caller'а** →
   `"Agent instance \"<id>\" does not belong to this parent agent"`.
7. **resume target уже running** →
   `"Agent instance \"<id>\" is already running and cannot run concurrently"`.
8. **у caller'а нет `modelAlias`** → `"Caller agent has no model bound"`.
9. **unknown profile name** → `"Unknown agent type: \"<name>\""`.
10. **Too many detached tasks** → `"Too many background tasks are already running."`.

### 3.1. `can_run_in_background?`

В JS проверяет, что caller'у доступны все три тула:

```ts
profile.isToolActive('TaskList') &&
profile.isToolActive('TaskOutput') &&
profile.isToolActive('TaskStop');
```

В Crystal — флаг `@@background_enabled : Bool = false` (классовая переменная).
Session/Loop устанавливает его через `Tools::Agent.background_enabled = true`,
когда реестр содержит TaskList/TaskOutput/TaskStop. По умолчанию `false` —
тул честно отказывает в `run_in_background`.

### 3.2. `launchErrorMessage(error, signal)`

Приоритет:

1. `signal.reason` → `USER_INTERRUPTED_SUBAGENT_MESSAGE` если это user-cancel.
2. `error` это `AbortError` → `format_subagent_stopped_message(signal.reason)`.
3. иначе — `error.message || error.to_s`.

`format_subagent_stopped_message(reason)`:

- `reason` пуст/`nil` → `SUBAGENT_STOPPED_MESSAGE`.
- `reason` равен `USER_CANCELLATION_MESSAGE` → `USER_INTERRUPTED_SUBAGENT_MESSAGE`.
- иначе → `"#{SUBAGENT_STOPPED_MESSAGE} Reason: #{reason}"`.

---

## 4. Формат вывода — 4 ветки

### 4.1. Background-старт — `format_background_agent_result`

Возвращается немедленно при `run_in_background == true`:

```
task_id: <taskId>
status: running
agent_id: <agentId>
actual_subagent_type: <profileName>
automatic_notification: true

description: <args.description>

next_step: The completion arrives automatically in a later turn — do NOT wait, poll, or call TaskOutput on it; continue with other work or hand back to the user. (If you have nothing to do until it finishes, run such tasks in the foreground next time.)
resume_hint: To continue or recover this same subagent later, call Agent(resume="<agentId>", prompt="..."). The parameter is agent_id ("<agentId>"), NOT task_id ("<taskId>") or source_id from a later <notification>. Recovery cases: a later <notification type="task.lost" | "task.failed" | "task.killed"> for this subagent — its conversation history is preserved across session restarts and resume will pick it up.
```

`is_error` не выставляется.

### 4.2. Foreground-успех — `format_foreground_agent_success`

```
agent_id: <agentId>
actual_subagent_type: <profileName>
status: completed

[summary]
<distilled summary text>
```

`<distilled summary text>` — это `result.result` (финальный ассистент-текст
дочернего агента, пропущенный через summary-distillation).

### 4.3. Foreground-провал — `format_foreground_agent_failure`

```
agent_id: <agentId>
actual_subagent_type: <profileName>
status: failed

subagent error: <message>
[resume_hint: Continue with Agent(resume="<agentId>", prompt="continue"). Use agent_id only; do not set subagent_type. The subagent retains its prior context; redo any unfinished tool call if its result was lost.]
```

`resume_hint` добавляется только если `timed_out == true`.

`<message>` для таймаута: `"Agent timed out after #{format_subagent_timeout_description(timeoutMs)}."`
(по умолчанию `"Agent timed out after 2 hours."`).

`is_error: true`.

### 4.4. `format_subagent_timeout_description(ms)`

- `ms % 3_600_000 == 0` → `"#{h} hour#{h == 1 ? "" : "s"}"`
- иначе `ms % 60_000 == 0` → `"#{m} minute#{m == 1 ? "" : "s"}"`
- иначе `ms % 1000 == 0` → `"#{s} second#{s == 1 ? "" : "s"}"`
- иначе `"#{ms} ms"`.

---

## 5. Опциональный `AgentRunner` — точка интеграции

Тулу достаточно зарегистрировать глобальный `@@runner : AgentRunner?`. Если
`@@runner.nil?`, `execute` возвращает `ToolResult.error("Agent is not available: no subagent runtime is registered in this build.")`.

```crystal
alias AgentLaunchSpec = NamedTuple(
  prompt: String,
  description: String,
  subagent_type: String?,     # nil при resume
  resume_agent_id: String?,
  run_in_background: Bool,
)

alias AgentRunOutcome = NamedTuple(
  agent_id: String,
  profile_name: String,
  status: Symbol,             # :completed | :failed | :aborted | :detached
  summary: String?,           # для :completed
  error: String?,             # для :failed
  timed_out: Bool,            # для :failed
  task_id: String?,           # для :detached
)

abstract class AgentRunner
  abstract def launch(spec : AgentLaunchSpec, signal : AbortController?) : AgentRunOutcome
end

class Agent < Tool
  @@runner : AgentRunner?
  def self.runner=(r) @@runner = r end
  def self.runner; @@runner end
  def self.background_enabled=(v : Bool) @@background_enabled = v end
end
```

Этого достаточно, чтобы позже подключить `Loop::Agent` как subagent runtime,
не меняя контракт тула.

---

## 6. План реализации (чек-лист)

- [ ] Прочитать JS: `agent.ts`, `subagent-task.ts`, `subagent.ts`,
      `subagentService.ts`, `runAgentTurn.ts`, `mirrorAgentRun.ts`,
      `agentProfileCatalog/*`, `agent.md`, `agent-background-enabled.md`,
      `agent-background-disabled.md`, `agentLifecycle/subagentMetadata.ts`.
- [x] Описать контракт в `md-tools/agent.md`.
- [ ] Реализовать `Tools::Agent < Tool` в `src/tools/agent.cr`:
  - [ ] Константы из §2.
  - [ ] `name`, `description` (см. §1.2), `parameters`.
  - [ ] `execute(input)`:
    1. Препроцессор (§1.4): нормализация `subagent_type` / `resume`.
    2. Валидация RESUME_WITH_TYPE (§3.1).
    3. Валидация background (§3.1 + §3.2).
    4. Если `@@runner.nil?` → `ToolResult.error(NO_RUNNER_ERROR)`.
    5. Иначе — `runner.launch(spec, abort_controller)`:
       - `status == :detached` → `format_background_agent_result`.
       - `status == :completed` → `format_foreground_agent_success`.
       - `status == :failed` → `format_foreground_agent_failure`.
    6. Обернуть всё в `rescue ex` → `ToolResult.error("subagent error: #{launch_error_message(ex, nil)}")`.
  - [ ] Хелперы: `format_background_agent_result`, `format_foreground_agent_success`,
        `format_foreground_agent_failure`, `format_subagent_timeout_description`,
        `launch_error_message`, `format_subagent_stopped_message`.
- [ ] Зарегистрировать тул в `Tools::Registry` (`src/kimi.cr`).
- [ ] Тесты в `spec/tools/agent_spec.cr`:
  - [ ] Без runner'а — `NO_RUNNER_ERROR`.
  - [ ] `resume + subagent_type` → `RESUME_WITH_TYPE_UNAVAILABLE`.
  - [ ] `run_in_background=true` без `background_enabled` → `BACKGROUND_AGENT_UNAVAILABLE`.
  - [ ] Foreground success → формат §4.2.
  - [ ] Foreground timeout → формат §4.3 с `resume_hint`.
  - [ ] Detach → формат §4.1.
  - [ ] Препроцессор: ни `resume`, ни `subagent_type` → default `coder`.
- [ ] Обновить `FIX-TOOLS.md`: отметить строку #1 выполненной.

---

## 7. Расхождения / допущения

- В JS `execute` оборачивается в try/catch — Crystal делает то же через
  `rescue ex`.
- `display.kind: 'agent_call'`, `approvalRule: this.name`, `accesses` —
  Crystal `Permission::Manager` использует `tool.name` как правило по
  умолчанию, отдельной настройки не нужно. `display` пока опущен (UI-метаданные).
- `signal: AbortSignal` — в Crystal прокидываем `AbortController` через
  контекст (`ToolBatch`). Runner получает к нему доступ.
- Background-доставка через `<notification>` XML: см. `md-tools/task.md`.
  Сам тул `Agent` только возвращает task_id; последующее уведомление кладёт
  `Loop::Event.notification_xml` в `Context::Memory` как новую user-role
  запись. Реализация этого — часть `md-tools/task.md`, не этого плана.
- В JS `subagent_type` принимает любой профиль из `IAgentProfileCatalogService`.
  В Crystal пока захардкодить список 4 профилей (`agent`/`coder`/`explore`/`plan`)
  в константе; подключить настраиваемый каталог можно позже, не меняя контракт.
- `runAgentTurn.distillSummary` (краткое резюме ответа субагента) — опущен в
  первом приближении. Runner возвращает полный финальный assistant-text;
  summarization можно добавить позже отдельным проходом.
