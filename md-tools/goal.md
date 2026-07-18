# Goal tools — план портирования из JS в Crystal

> Источник: `packages/agent-core-v2/src/agent/goal/tools/`:
> `create-goal.ts` + `create-goal.md`, `get-goal.ts` + `get-goal.md`,
> `update-goal.ts` + `update-goal.md`, `set-goal-budget.ts` + `set-goal-budget.md`,
> `serialize.ts`, `outcome-prompts.ts`, `goal.ts`, `goalService.ts`,
> `types.ts`, `goalOps.ts`, `errors.ts`.

Цель — 4 тула в `hcode.cr/src/tools/goal.cr` (`Tools::CreateGoal`,
`Tools::GetGoal`, `Tools::UpdateGoal`, `Tools::SetGoalBudget`) с
идентичными контрактами. Состояние цели — в `GoalService`.

**Все 4 тула регистрируются только для main agent** (`agentId == "main"`).

---

## 1. Состояние цели (общая модель)

```crystal
enum GoalStatus
  Active
  Paused
  Blocked
  Complete
end

struct GoalSnapshot
  property goal_id : String
  property objective : String
  property completion_criterion : String?
  property status : GoalStatus
  property turns_used : Int32
  property tokens_used : Int32
  property wall_clock_ms : Int64
  property budget : GoalBudgetReport
  property terminal_reason : String?
end

struct GoalBudgetReport
  property token_budget : Int32?
  property turn_budget : Int32?
  property wall_clock_budget_ms : Int64?
  property remaining_tokens : Int32?
  property remaining_turns : Int32?
  property remaining_wall_clock_ms : Int64?
  property token_budget_reached : Bool
  property turn_budget_reached : Bool
  property wall_clock_budget_reached : Bool
  property over_budget : Bool
end

struct GoalBudgetLimits
  property token_budget : Int32?
  property turn_budget : Int32?
  property wall_clock_budget_ms : Int64?
end
```

`remaining_X = max(0, budget - used)`. `X_budget_reached = !budget.nil? && used >= budget`. `over_budget = OR всех трёх.

`goalForModel(snapshot)` — убирает `goal_id` (модель его не видит).

---

## 2. `CreateGoal` — контракт

### 2.1. `name`

`"CreateGoal"`.

### 2.2. `description` (verbatim, `create-goal.md`)

```
Create a durable, structured goal that the runtime will pursue across multiple turns.

Call `CreateGoal` only when:

- the user explicitly asks you to start a goal or work autonomously toward an outcome, or
- a host goal-intake prompt asks you to create one.

Do NOT create a goal for greetings, ordinary questions, or vague requests that lack a
verifiable completion condition. A goal needs a checkable end state.

When the request is vague, ask the user for the missing completion criterion before creating
the goal. If the user clearly insists after you warn them that the wording is vague or risky,
respect that and create the goal.

Include a `completionCriterion` when the user provides one, or when it can be stated without
inventing new requirements. Keep `objective` concise; reference long task descriptions by file
path rather than pasting them.

Creating a goal fails if one already exists, so use `replace: true` only when the user explicitly
wants to abandon the current goal and start a new one.
```

### 2.3. `parameters`

```json
{
  "type": "object",
  "properties": {
    "objective": {
      "type": "string",
      "minLength": 1,
      "description": "The objective to pursue. Must have a verifiable end state."
    },
    "completionCriterion": {
      "type": "string",
      "description": "How to verify the goal is complete. Include when the user provides one."
    },
    "replace": {
      "type": "boolean",
      "description": "Replace an existing active, paused, or blocked goal instead of failing."
    }
  },
  "required": ["objective"],
  "additionalProperties": false
}
```

### 2.4. Константы

| Имя                                    | Значение  |
|----------------------------------------|-----------|
| `MAX_GOAL_OBJECTIVE_LENGTH`            | `4000`    |
| `MAX_GOAL_COMPLETION_CRITERION_LENGTH` | `4000`    |

`normalize_completion_criterion` — трим + обрезка до 4000 символов.

### 2.5. Validation / ветки

- `resolveExecution`: захват `goal_at_resolution`.
- `execute`:
  - Перечитать `current`. Если `current.goal_id != goal_at_resolution.goal_id`
    и `!is_goal_tool_target(turn_id, current.goal_id)` →
    `{ output: "Goal not created: the current goal changed." }`.
- Service-thrown errors:
  - `goal.unsupported_agent` (`agentId != "main"`).
  - `goal.objective_empty` (тримmed пустой).
  - `goal.objective_too_long` (> 4000).
  - `goal.already_exists` (цель уже есть и `replace != true`).

### 2.6. Вывод

- Stale short-circuit: `"Goal not created: the current goal changed."`.
- Успех: pretty-printed JSON:
  ```json
  {
    "goal": {
      "objective": "...",
      "completionCriterion": "...",
      "status": "active",
      "turnsUsed": 0,
      "tokensUsed": 0,
      "wallClockMs": 0,
      "budget": { ... },
      "terminalReason": null
    }
  }
  ```
  (`goal_id` убран). 2-space indent.

### 2.7. Approval / display

- `approvalRule: "CreateGoal"`. Без subject.
- `description: "Creating a goal"`.
- `display: { kind: "goal_start", objective, completionCriterion, mode }` —
  для TUI hint. `nil` в auto mode.
- Нет `accesses`.

---

## 3. `GetGoal` — контракт

### 3.1. `name`

`"GetGoal"`.

### 3.2. `description` (verbatim, `get-goal.md`)

```
Read the current goal: its objective, completion criterion, status, and budgets (turns, tokens,
time, and how much of each remains). When the goal has stopped, it also reports the terminal reason.

Use `GetGoal` before deciding whether to continue working, report completion, report a blocker,
or respect a pause. It returns `{ "goal": null }` when there is no current goal.
```

### 3.3. `parameters`

Пустой strict-объект.

### 3.4. Вывод

`JSON.stringify({ goal: snapshot || null }, null, 2)` — при отсутствии цели:

```json
{
  "goal": null
}
```

### 3.5. Service

`goal.get_goal`.

---

## 4. `UpdateGoal` — контракт

### 4.1. `name`

`"UpdateGoal"`.

### 4.2. `description` (verbatim, `update-goal.md`)

Подробный текст про `active` / `complete` / `blocked` — см. JS-файл.
Summary:

- `active` — resume при паузе/блоке.
- `complete` — завершение с self-summmary.
- `blocked` — genuine impasse; правило 3-х последовательных ходов для
  non-terminal; немедленный `blocked` для impossible/unsafe/contradictory.

### 4.3. `parameters`

```json
{
  "type": "object",
  "properties": {
    "status": {
      "type": "string",
      "enum": ["active", "complete", "blocked"],
      "description": "The lifecycle status to set for the current goal. Use `blocked` for impossible, unsafe, or contradictory objectives, or after the same non-terminal blocking condition repeats for at least 3 consecutive goal turns."
    }
  },
  "required": ["status"],
  "additionalProperties": false
}
```

### 4.4. Validation / ветки

1. `is_update_goal_status(args.status)` — defense-in-depth. Иначе →
   `ToolResult.error("Invalid goal status. Use `active`, `complete`, or `blocked`.")`.
2. Захват `current_goal`, `goal_was_active = current.status == :active`.
3. `stop_batch_after_this = status != :active && goal_was_active`.
4. `execute`:
   - Re-read `goal_at_execution`.
   - `nil` ИЛИ (`current.nil? && status == :active`) → `missing_goal_output(status)`:
     - `:active` → `"Goal not resumed: no current goal."`
     - `:complete` → `"Goal not completed: no active goal."`
     - `:blocked` → `"Goal not blocked: no active goal."`
   - `goal_at_execution.goal_id != current.goal_id` и не tool-target →
     `changed_goal_output(status)`:
     - `:active` → `"Goal not resumed: the current goal changed."`
     - `:complete` → `"Goal not completed: the current goal changed."`
     - `:blocked` → `"Goal not blocked: the current goal changed."`
   - `:active` → `goal.resume_goal({}, "model")` →
     `{ output: "Goal resumed." }`.
   - `:complete` → `goal.mark_complete({}, "model")`:
     - returns nil → `"Goal not completed: no active goal."`
     - else → `build_goal_completion_summary_prompt(snapshot)` с `stop_turn: true`.
   - `:blocked` → `goal.mark_blocked({}, "model")`:
     - returns nil → `"Goal not blocked: no active goal."`
     - else → `build_goal_blocked_reason_prompt(snapshot)` с `stop_turn: true`.

### 4.5. Completion prompt template

```
Goal completed successfully[: <terminalReason>].
Worked <N> turn[s] over <elapsed>, using <tokens> tokens.

Write a concise final message for the user. State that the goal is complete, summarize the main work completed, and mention any validation you ran. Do not call more goal tools.
```

Где:

- `<terminalReason>` добавляется как `: <reason>` только если есть.
- Turns pluralization: `1 turn` / `N turns`.
- `format_elapsed(ms)`:
  - `<60s` → `"#{s}s"`
  - `<60m` → `"#{m}m#{ss}s"` (zero-padded до 2 цифр, например `5m03s`)
  - иначе → `"#{h}h#{mm}m"`
- `format_tokens(n)`:
  - `<1000` → raw
  - `<1e6` → `(n/1000).round(1).to_s + "k"`
  - иначе → `(n/1e6).round(1).to_s + "M"`

### 4.6. Blocked prompt template

```
Goal blocked.
Worked <N> turn[s] over <elapsed>, using <tokens> tokens.

Write a concise final message for the user. State that the goal is blocked, explain the concrete blocker, and say what input or change is needed before work can continue. Do not call more goal tools.
```

### 4.7. Service

- `goal.get_goal` (несколько раз).
- `goal.is_goal_tool_target(turn_id, goal_id)`.
- `goal.resume_goal({}, "model")`.
- `goal.mark_complete({}, "model")`.
- `goal.mark_blocked({}, "model")`.

---

## 5. `SetGoalBudget` — контракт

### 5.1. `name`

`"SetGoalBudget"`.

### 5.2. `description` (verbatim, `set-goal-budget.md`)

```
Set a hard budget limit for the current goal.

Use this only when the user clearly gives a runtime limit, such as:

- "stop after 20 turns"
- "use no more than 500k tokens"
- "finish within 30 minutes"

Do not invent limits. Do not call this for vague wording such as "spend some time" or
"try to be quick".

If the user gives a compound time, convert it to one supported unit before calling this tool.
For example, "2 hours and 3 minutes" can be set as `value: 123, unit: "minutes"`.

A time budget must be between 1 second and 24 hours — the tool rejects anything shorter or
longer, telling the user it is not a reasonable goal budget. Turn and token budgets are not
bounded this way; they must be positive and are rounded to the nearest whole number (minimum 1).

Supported units:

- `turns`
- `tokens`
- `milliseconds`
- `seconds`
- `minutes`
- `hours`
```

### 5.3. `parameters`

```json
{
  "type": "object",
  "properties": {
    "value": {
      "type": "number",
      "exclusiveMinimum": 0,
      "description": "The positive numeric budget value."
    },
    "unit": {
      "type": "string",
      "enum": ["turns", "tokens", "milliseconds", "seconds", "minutes", "hours"]
    }
  },
  "required": ["value", "unit"],
  "additionalProperties": false
}
```

### 5.4. Константы

| Имя                                | Значение                              |
|------------------------------------|---------------------------------------|
| `MIN_REASONABLE_TIME_BUDGET_MS`    | `1_000` (1 second)                    |
| `MAX_REASONABLE_TIME_BUDGET_MS`    | `86_400_000` (24 hours)               |
| `BUDGET_UNITS`                     | `["turns", "tokens", "milliseconds", "seconds", "minutes", "hours"]` |

### 5.5. `normalize_budget_input(value, unit)`

- `turns`/`tokens`: `[1, value.round].max`.
- time units: pass-through.

### 5.6. `budget_limits_from_input(value, unit) : GoalBudgetLimits?`

- `turns` → `{ turn_budget: value }`.
- `tokens` → `{ token_budget: value }`.
- `milliseconds`/`seconds`/`minutes`/`hours` →
  `wall_clock_budget_ms = to_milliseconds(value, unit).round`.
  - conversions: ms→×1, s→×1000, min→×60_000, h→×3_600_000.
  - Если `< 1000 || > 86_400_000` → **`nil`** (signal "not reasonable").

### 5.7. `would_exceed_budget(goal, new_limits) : Bool`

Мержит `new_limits ?? current`. True если хотя бы один:

- `turns_used >= turn_budget` (если turn_budget не nil)
- `tokens_used >= token_budget` (если token_budget не nil)
- `wall_clock_ms >= wall_clock_budget_ms` (если wall_clock_budget_ms не nil)

### 5.8. `execute` — ветки

1. Re-read `current`. `nil` → `"Goal budget not set: no current goal."`.
2. Stale (goal_id diff, not tool-target) →
   `"Goal budget not set: the current goal changed."`.
3. `budget.nil?` → `"Goal budget not set: #{format_budget(value, unit)} is not a reasonable goal budget."`.
4. `goal.set_budget_limits({ budget_limits: budget }, "model")`:
   - Если `snapshot.budget.over_budget` →
     `"Goal budget set: #{format_budget(value, unit)}. The goal has already reached this budget and will stop now."` с `stop_turn: true`.
   - Иначе → `"Goal budget set: #{format_budget(value, unit)}."`.

### 5.9. `format_budget(value, unit)` — грамматика

singular когда value == 1: `1 turn`, `2 turns`, `1 token`, `1 millisecond`,
`1 second`, `1 minute`, `1 hour`.

```crystal
def format_budget(value : Number, unit : String) : String
  singular = unit.ends_with?('s') ? unit[0...-1] : unit
  "#{value} #{value == 1 ? singular : unit}"
end
```

---

## 6. `IAgentGoalService` — абстракция

```crystal
abstract class GoalService
  abstract def get_goal : { goal: GoalSnapshot? }
  abstract def is_goal_tool_target(turn_id : Int32, goal_id : String) : Bool
  abstract def create_goal(input : CreateGoalInput, actor : String = "model") : GoalSnapshot
  abstract def pause_goal(input : GoalReasonInput? = nil, actor : String = "model") : GoalSnapshot
  abstract def resume_goal(input : ResumeGoalInput? = nil, actor : String = "model") : GoalSnapshot
  abstract def cancel_goal(input : GoalReasonInput? = nil, actor : String = "model") : GoalSnapshot
  abstract def set_budget_limits(input : BudgetInput, actor : String = "model") : GoalSnapshot
  abstract def mark_complete(input : GoalReasonInput? = nil, actor : String = "model") : GoalSnapshot?
  abstract def mark_blocked(input : GoalReasonInput? = nil, actor : String = "model") : GoalSnapshot?
end

struct CreateGoalInput
  property objective : String
  property completion_criterion : String?
  property replace : Bool = false
end

struct GoalReasonInput
  property reason : String?
end

struct ResumeGoalInput < GoalReasonInput
  property continue_if_paused : Bool = false
  property continue_if_blocked : Bool = false
end

struct BudgetInput
  property budget_limits : GoalBudgetLimits
end
```

Реализация `AgentGoalService` хранит состояние цели в памяти + опционально
persistит в session store. Методы возвращают `GoalSnapshot` (или nil для
mark_complete/mark_blocked при неправильном статусе).

### 6.1. Status transitions enforced

- `create_goal` → `:active` (с опциональной очисткой существующей при `replace`).
- `pause_goal` → `:paused`; требует `:active`.
- `resume_goal` → `:active`; требует `:paused` или `:blocked`.
- `mark_blocked` → `:blocked`; действует только при `:active`.
- `mark_complete` → `:complete` (then clear); действует только при `:active`.

### 6.2. Wire Model (`goalOps.ts`)

```crystal
struct GoalState
  property goal_id : String
  property objective : String
  property completion_criterion : String?
  property status : GoalStatus
  property turns_used : Int32
  property tokens_used : Int32
  property wall_clock_ms : Int64
  property wall_clock_resumed_at : Int64?
  property budget_limits : GoalBudgetLimits
  property terminal_reason : String?
end
```

`budget_limits` стартует как `{}` при create. Op `goal.update` field-by-field
merged.

---

## 7. План реализации (чек-лист)

- [ ] Прочитать JS: `create-goal.ts`, `get-goal.ts`, `update-goal.ts`,
      `set-goal-budget.ts` (+ соотв. `.md`), `serialize.ts`,
      `outcome-prompts.ts`, `goal.ts`, `goalService.ts`, `types.ts`,
      `goalOps.ts`, `errors.ts`.
- [x] Описать контракт в `md-tools/goal.md`.
- [ ] Реализовать `GoalStatus`, `GoalSnapshot`, `GoalBudgetReport`,
      `GoalBudgetLimits`, `GoalState`, `GoalService` (abstract),
      `AgentGoalService` (impl).
- [ ] Реализовать 4 тула в `src/tools/goal.cr`:
  - [ ] `Tools::CreateGoal` (§2).
  - [ ] `Tools::GetGoal` (§3).
  - [ ] `Tools::UpdateGoal` (§4) с `build_goal_completion_summary_prompt` /
        `build_goal_blocked_reason_prompt` / `format_elapsed` / `format_tokens`.
  - [ ] `Tools::SetGoalBudget` (§5) с `normalize_budget_input` /
        `budget_limits_from_input` / `would_exceed_budget` / `format_budget`.
- [ ] `GoalService` инжекченный в тулы через `@@service : GoalService?`.
- [ ] Регистрация только для main agent (в `src/hcode.cr` — main-агент
      инициализация).
- [ ] Тесты в `spec/tools/goal_spec.cr`:
  - [ ] CreateGoal — создание с заменой / без; objective_empty /
        objective_too_long; already_exists; stale-goal short-circuit.
  - [ ] GetGoal — `{ goal: null }` при отсутствии / полный JSON при наличии.
  - [ ] UpdateGoal — `:active`/`:complete`/`:blocked`; missingGoal;
        changedGoal; invalid_status; prompts.
  - [ ] SetGoalBudget — turns/tokens/ms/sec/min/hours; unreasonable;
        already-over; format_budget singular/plural.
- [ ] Обновить `FIX-TOOLS.md`: отметить строки #9–#12 выполненными.

---

## 8. Расхождения / допущения

- `agentId != "main"` проверка: в Crystal пока нет multi-agent
      infrastructure. Все 4 тула доступны только main agent'у через условную
      регистрацию.
- `IGoalDeadlineScheduler` (wall-clock timeout): в Crystal — `Fiber` +
      `sleep` + flag.
- `wire.hooks.onDidRestore` (replay восстановление `:active` → `:paused`) —
      опущен; в простейшей реализации goal-state в памяти.
- `IAgentSystemReminderService` / `IAgentContextInjectorService` для goal
      напоминаний — упрощены до `Context::Memory#add_injection` из Loop.
- `stop_batch_after_this` / `stop_turn` — флаги, которые Crystal `ToolResult`
      пока не имеет. Добавить как поля `ToolResult` (опциональные), либо
      обрабатывать через return-значение runner'а.
- JSON-формат pretty-printed (2-space) — критичен для контракта; в Crystal
      `JSON.stringify` через `JSON::Builder#indent = 2`.
