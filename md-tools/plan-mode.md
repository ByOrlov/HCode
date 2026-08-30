# EnterPlanMode + ExitPlanMode — план портирования из JS в Crystal

> Источник: `packages/agent-core-v2/src/agent/plan/tools/enter-plan-mode.ts`
> + `enter-plan-mode.md`, `exit-plan-mode.ts`, `exit-plan-mode.md`,
>   `plan.ts` (interface), `planService.ts`, `planOps.ts`,
>   `configSection.ts`, `profile/plan.ts`, `injection/planModeInjection.ts`,
>   `injection/*.md` (6 reminder variants).

Цель — два тула в `h2code.cr/src/tools/plan_mode.cr` (`Tools::EnterPlanMode` и
`Tools::ExitPlanMode`) с идентичным LLM-контрактом. Состояние plan mode —
в `Context::Memory`/`Loop::Agent` через `PlanService`.

---

## 1. `EnterPlanMode` — контракт

| Поле           | JS (`EnterPlanModeTool`)                              | Crystal (`Tools::EnterPlanMode`)                       |
|----------------|-------------------------------------------------------|---------------------------------------------------------|
| `name`         | `'EnterPlanMode' as const`                            | `"EnterPlanMode"`                                       |
| `description`  | импорт из `enter-plan-mode.md?raw`                    | Константа `DESCRIPTION` (verbatim §1.2)                 |
| `parameters`   | `toInputJsonSchema(z.object({}).strict())`            | `{"type":"object","properties":{},"additionalProperties":false}` |
| `execute`      | `resolveExecution.execute()`                          | `execute(input : JSON::Any) : ToolResult`               |

### 1.1. `description` (verbatim)

```
Use this tool proactively when you're about to start a non-trivial implementation task.
Getting user sign-off on your approach via ExitPlanMode before writing code prevents wasted effort.

Use it when ANY of these conditions apply:

1. New Feature Implementation - e.g. "Add a caching layer to the API"
2. Multiple Valid Approaches - e.g. "Optimize database queries" (indexing vs rewrite vs caching)
3. Code Modifications - e.g. "Refactor auth module to support OAuth"
4. Architectural Decisions - e.g. "Add WebSocket support"
5. Multi-File Changes - involves more than 2-3 files
6. Unclear Requirements - need exploration to understand scope
7. User Preferences Matter - if user input would materially change the implementation approach, use EnterPlanMode to structure the decision

Permission mode notes:
- EnterPlanMode enters plan mode automatically without an approval prompt in all permission modes.
- In yolo and manual modes, ExitPlanMode still presents the plan to the user for approval.
- In auto permission mode, do not use AskUserQuestion; make the best decision from available context.
- In auto permission mode, ExitPlanMode exits plan mode without asking the user.
- Use EnterPlanMode only when planning itself adds value.

When NOT to use:
- Single-line or few-line fixes (typos, obvious bugs, small tweaks)
- User gave very specific, detailed instructions
- Pure research/exploration tasks

Once you are in plan mode, a reminder walks you through the workflow (explore → design → write the plan file → `ExitPlanMode`) and enforces read-only access. For non-trivial tasks where you are unsure of the codebase structure or relevant code paths, use `Agent(subagent_type="explore")` to investigate first when the `Agent` tool is available.
```

### 1.2. `parameters`

Пустой strict-объект. Любое свойство → ошибка schema-validation.

### 1.3. Approval

- `approvalRule: 'EnterPlanMode'` — без subject.
- В JS есть `plan-mode-tool-approve` policy, которая безусловно approve'ит
  EnterPlanMode → никогда не запрашивает подтверждение.
- В Crystal — добавить `when "EnterPlanMode"` в `auto_approve?`.

### 1.4. Execute — все ветки

```crystal
def execute(input : JSON::Any) : ToolResult
  before = plan_service.status
  if before
    return ToolResult.error("Plan mode is already active. Use ExitPlanMode when the plan is ready.")
  end
  begin
    plan_service.enter
  rescue ex
    return ToolResult.error("Failed to enter plan mode: #{ex.message || "Failed to enter plan mode."}")
  end
  after = plan_service.status
  ToolResult.success(entered_plan_mode_message(after.try(&.path)))
end
```

### 1.5. `entered_plan_mode_message(plan_path)`

Если `plan_path.nil?`:

```
Plan mode is now active. Your workflow:

1. Use read-only tools (Read, Grep, Glob) to investigate the codebase. Use Bash only when needed.
2. Design a concrete, step-by-step plan.
3. Wait for the host to provide a plan file path before calling ExitPlanMode.

Do NOT use Write or Edit while plan mode is active in this host; no plan file path is available.
Use Bash only when needed; Bash follows the normal permission mode and rules.
```

Если `plan_path` строка:

```
Plan mode is now active. Your workflow:

Plan file: <plan_path>

1. Use read-only tools (Read, Grep, Glob) to investigate the codebase. Use Bash only when needed.
2. Design a concrete, step-by-step plan.
3. Write the plan to the plan file with Write or Edit.
4. When the plan is ready, call ExitPlanMode for user approval.

Do NOT edit files other than the plan file while plan mode is active.
Use Bash only when needed; Bash follows the normal permission mode and rules.
```

---

## 2. `ExitPlanMode` — контракт

| Поле           | JS (`ExitPlanModeTool`)                                   | Crystal (`Tools::ExitPlanMode`)                    |
|----------------|-----------------------------------------------------------|-----------------------------------------------------|
| `name`         | `'ExitPlanMode' as const`                                 | `"ExitPlanMode"`                                    |
| `description`  | импорт из `exit-plan-mode.md?raw`                         | Константа `DESCRIPTION` (verbatim §2.2)             |
| `parameters`   | `toInputJsonSchema(ExitPlanModeInputSchema)`              | Эквивалентная JSON Schema                           |
| `execute`      | `resolveExecution.execute()`                              | `execute(input : JSON::Any) : ToolResult`           |

### 2.1. `name`

`"ExitPlanMode"`.

### 2.2. `description` (verbatim)

```
Use this tool when you are in plan mode and have finished writing your plan to the plan file and are ready for user approval.

## How This Tool Works
- You should have already written your plan to the plan file specified in the plan mode reminder.
- This tool does NOT take the plan content as a parameter - it reads the plan from the file you wrote.
- The user will see the contents of your plan file when they review it. In auto permission mode, the tool reads the file and exits plan mode without asking the user.

## When to Use
Only use this tool for tasks that require planning implementation steps. For research tasks (searching files, reading code, understanding the codebase), do NOT use this tool.

## What a good plan contains
List specific, verifiable steps grounded in the actual codebase — real files, functions, and commands, in a sensible order. Each step should be concrete enough to act on and to check. Avoid vague filler like "improve performance" or "add tests"; say what to change and where.

## Multiple Approaches
If your plan offers multiple alternative approaches, pass them via the `options` parameter so the user can choose which one to execute — see the `options` parameter for the format, count, and reserved labels. In yolo and manual modes the user sees all options alongside the host's Reject and Revise controls.

## Before Using
- In auto permission mode, do NOT use AskUserQuestion; make the best decision from available context.
- In auto permission mode, this tool exits plan mode without asking the user.
- In yolo and manual modes, this tool still presents the plan to the user for approval.
- If auto permission mode is not active and you have unresolved questions, use AskUserQuestion first.
- If auto permission mode is not active and you have multiple approaches and haven't narrowed down yet, consider using AskUserQuestion first to let the user choose, then write a plan for the chosen approach only.
- Once your plan is finalized, use THIS tool to request approval.
- Do NOT use AskUserQuestion to ask "Is this plan OK?" or "Should I proceed?" - that is exactly what ExitPlanMode does.
- If rejected, revise based on feedback and call ExitPlanMode again.
```

### 2.3. `parameters` — JSON Schema

```json
{
  "type": "object",
  "properties": {
    "options": {
      "type": "array",
      "description": "When the plan contains multiple alternative approaches, list them here so the user can choose which one to execute. Provide up to 3 options; 2-3 distinct approaches work best when the plan offers a real choice. Passing a single option is allowed and is equivalent to a plain plan approval. Each option represents a distinct approach from the plan. Do not use \"Reject\", \"Revise\", \"Approve\", or \"Reject and Exit\" as labels.",
      "minItems": 1,
      "maxItems": 3,
      "items": {
        "type": "object",
        "properties": {
          "label": {
            "type": "string",
            "minLength": 1,
            "maxLength": 80,
            "description": "Short name for this option (1-8 words). Append \"(Recommended)\" if you recommend this option."
          },
          "description": {
            "type": "string",
            "default": "",
            "description": "Brief summary of this approach and its trade-offs."
          }
        },
        "required": ["label"],
        "additionalProperties": false
      }
    }
  },
  "additionalProperties": false
}
```

| Поле                | Тип            | Required | Default | Ограничения                                              |
|---------------------|----------------|----------|---------|----------------------------------------------------------|
| `options`           | `array<option>`| ❌        | —       | `minItems: 1`, `maxItems: 3`; labels уникальны; не из reserved |
| `options[].label`   | `string`       | да       | —       | `minLength: 1`, `maxLength: 80`                          |
| `options[].description` | `string`   | ❌        | `""`    | —                                                        |

### 2.4. Reserved labels

```crystal
RESERVED_OPTION_LABELS = Set{"approve", "reject", "reject and exit", "revise"}
# normalize: trim + downcase
```

### 2.5. Константы валидации

- `hasUniqueOptionLabels` — после `normalize_option_label` (trim + downcase)
  все labels должны быть уникальны. Error: `"Option labels must be unique."`.
- `hasNoReservedOptionLabels` — ни один label не должен быть в
  `RESERVED_OPTION_LABELS`. Error: `"Option labels must not use reserved approval labels."`.

---

## 3. `IAgentPlanService` — абстракция

```crystal
struct PlanData
  property id : String
  property content : String
  property path : String
end

abstract class PlanService
  abstract def status : PlanData?      # nil = не в plan mode
  abstract def enter(id : String? = nil, create_file : Bool = false) : Nil
  abstract def cancel(id : String? = nil) : Nil
  abstract def clear : Nil
  abstract def exit(id : String? = nil) : Nil
end
```

Путь файла плана: `<sessionDir>/agents/<agentId>/plans/<id>.md`. `enter`
создаёт директории при необходимости; **не** создаёт сам файл (create_file
по умолчанию false).

Реализация:

```crystal
class AgentPlanService < PlanService
  def initialize(@session_dir : String, @agent_id : String, @work_dir : String)
    @active = false
    @plan_id : String?
  end

  def status : PlanData?
    return nil unless @active && (id = @plan_id)
    path = plan_path(id)
    content = File.exists?(path) ? File.read(path) : ""
    PlanData.new(id: id, content: content, path: path)
  end

  def enter(id : String? = nil, create_file : Bool = false) : Nil
    raise "Already in plan mode" if @active
    @plan_id = id || generate_id
    Dir.mkdir_p(File.dirname(plan_path(@plan_id.not_nil!)))
    @active = true
    File.write(plan_path(@plan_id.not_nil!), "") if create_file
  end

  def exit(id : String? = nil) : Nil
    @active = false
    @plan_id = nil
  end

  private def plan_path(id) : String
    File.join(@session_dir, "agents", @agent_id, "plans", "#{id}.md")
  end

  private def generate_id : String
    # hero-slug of UUID — упрощённо, UUID без дефисов.
    UUID.random.to_s.gsub("-", "")
  end
end
```

---

## 4. `ExitPlanMode.execute` — все ветки

```crystal
def execute(input : JSON::Any) : ToolResult
  service = plan_service
  return ToolResult.error("Plan service is not initialized.") if service.nil?

  status = service.status
  if status.nil?
    # Принудительно входим в plan mode, если агент не вызвал EnterPlanMode.
    begin
      service.enter
    rescue ex
      return ToolResult.error("Failed to enter plan mode: #{ex.message || "Failed to enter plan mode."}")
    end
    status = service.status
    return ToolResult.error("Failed to activate plan mode. Use EnterPlanMode (or /plan) first.") if status.nil?
  end

  resolved = resolve_plan(status)
  return resolved if resolved.is_error  # пустой/отсутствующий план

  plan_service.exit

  if permission_mode.auto?
    ToolResult.success(format_auto_approved(plan, path))
  else
    ToolResult.success(format_user_approved(plan, path))
  end
end
```

### 4.1. `resolve_plan(status)` — ветки

- `status.content.strip.empty?`:
  - `status.path.nil?` →
    `ToolResult.error("No plan file found. Write the plan to the current plan file first, then call ExitPlanMode.")`.
  - иначе →
    `ToolResult.error("No plan file found. Write your plan to #{path} first, then call ExitPlanMode.")`.
- иначе → успех с `{ plan: content, path: path }`.

### 4.2. Branch AUTO

```crystal
def format_auto_approved(plan : String, path : String?) : String
  saved_to = path ? "Plan saved to: #{path}\n\n" : ""
  <<-TEXT
  Exited plan mode. Plan mode deactivated. All tools are now available.
  Note: this plan was auto-approved without user review — the user has NOT explicitly approved it. Follow the user's original instructions on whether to proceed with execution; if they asked you to stop, wait, or only summarize after planning, do not start executing.
  #{saved_to}## Plan (auto-approved, not user-reviewed):
  #{plan}
  TEXT
end
```

### 4.3. Branch MANUAL/YOLO

В реальности в manual/yolo срабатывает interactive policy, которая
перехватывает вызов. Для Crystal (пока без policy-chain) упрощаем — рендерим
как approved (как в auto), с пометкой `## Approved Plan:`:

```crystal
def format_user_approved(plan : String, path : String?) : String
  saved_to = path ? "Plan saved to: #{path}\n\n" : ""
  <<-TEXT
  Exited plan mode. Plan mode deactivated. All tools are now available.
  #{saved_to}## Approved Plan:
  #{plan}
  TEXT
end
```

Опционально: при `permission_mode` != auto делегировать в
`Permission::Manager` с callback'ом, который спросит пользователя
approve/reject/revise, и при revise вернуть `ToolResult.error("Plan rejected: revise and call ExitPlanMode again.")`.

### 4.4. Options в approval UI

Если `options` предоставлены (≥ 2) — UI показывает список выбора. Selected
option добавляется в ответ:

```
Selected approach: <selected.label>
Execute ONLY the selected approach. Do not execute any unselected alternatives.

Plan mode deactivated. All tools are now available.
[Plan saved to: <path>]

## Approved Plan:
<plan>
```

---

## 5. Семантика plan mode — состояние, инъекции, разрешения

### 5.1. State changes on enter

1. Новый plan id (hero slug of UUID).
2. Plan directory `<sessionDir>/agents/<agentId>/plans/` создаётся (mkdir_p).
3. `plan_mode.enter { id }` op → состояние `active: true, id: id`.
4. Plan file **не** создаётся заранее (модель сама пишет через Write/Edit).

### 5.2. Injection — напоминания

`PlanModeInjection` в JS регистрируется как `ContextInjector`, который:

- На каждом шаге проверяет `status = plan_service.status`.
- Свежий переход (false → true) инжекчит `full-reminder` (если план уже
  есть — `reentry-reminder`).
- При `wasActive == true && status.nil?` инжекчит `exit-reminder`.
- Поддерживает `full` (≥5 assistant turns since last), `sparse` (≥2),
  `null` (<2 — подавить). Управляется `injectedAt` и историей сообщений.

В Crystal упрощаем: после `enter` всегда инжектим `PLAN_MODE_FULL_REMINDER`
через `Context::Memory#add_injection`. Перед каждым новым шагом Loop::Agent
вызывает `inject_plan_reminder(memory, plan_service)` — выбирает вариант по
тем же правилам. На `exit` инжектим `PLAN_MODE_EXIT_REMINDER`.

### 5.3. Reminder тексты (verbatim см. JS `.md` файлы)

6 вариантов:

- `PLAN_MODE_FULL_REMINDER` (`plan-mode-full-reminder.md`) — полный workflow.
- `PLAN_MODE_SPARSE_REMINDER` (`plan-mode-sparse-reminder.md`) — сокращённый.
- `PLAN_MODE_REENTRY_REMINDER` (`plan-mode-reentry-reminder.md`) — есть
  предыдущий план.
- `PLAN_MODE_EXIT_REMINDER` (`plan-mode-exit-reminder.md`) — выход.
- `PLAN_MODE_INLINE_FULL_REMINDER` (`plan-mode-inline-full-reminder.md`) —
  для хостов без файла плана.
- `PLAN_MODE_INLINE_SPARSE_REMINDER` / `PLAN_MODE_INLINE_REENTRY_REMINDER`.

С суффиксом `"\n\nPlan file: #{path}"` при наличии пути.

### 5.4. Разрешения в plan mode

JS использует три политики (`plan-mode-guard-deny`, `plan-mode-tool-approve`,
`exit-plan-mode-review-ask`). В Crystal упрощаем через проверки в
`Permission::Manager#check`:

- В plan mode:
  - `Write`/`Edit` разрешены **только** если path == plan_file.
    Иначе deny: `"Plan mode is active. You may only write to the current plan file: #{path || "(no plan file selected yet)"}. Call ExitPlanMode to exit plan mode before editing other files."`.
  - `TaskStop` deny: `"TaskStop is not available in plan mode. Call ExitPlanMode to exit plan mode before stopping a background task."`.
  - `CronCreate`/`CronDelete` deny: `"#{toolName} is not available in plan mode because it would mutate scheduled work that runs after plan exit. Call ExitPlanMode first."`.
- `EnterPlanMode` всегда approve (без запроса).
- `Write`/`Edit` в plan файл approve (без запроса).

### 5.5. `plan` task-agent profile

Отдельный read-only subagent для планирования. Tools whitelist:
`Read, ReadMediaFile, Glob, Grep, WebSearch, FetchURL`. System prompt
сообщает об отсутствии shell/edit tools.

---

## 6. Config

```crystal
DEFAULT_PLAN_MODE = false  # H2CODE_DEFAULT_PLAN_MODE env / [default_plan_mode] TOML
```

Когда `true` — каждая свежая сессия стартует в plan mode. Resume/fork
сессии игнорируют флаг.

---

## 7. План реализации (чек-лист)

- [ ] Прочитать JS: `enter-plan-mode.ts`, `enter-plan-mode.md`,
      `exit-plan-mode.ts`, `exit-plan-mode.md`, `plan.ts`, `planService.ts`,
      `planOps.ts`, `configSection.ts`, `profile/plan.ts`,
      `injection/planModeInjection.ts`, все 8 `.md` reminder'ов.
- [x] Описать контракт в `md-tools/plan-mode.md`.
- [ ] Реализовать `PlanData`, `PlanService`, `AgentPlanService`.
- [ ] Реализовать `Tools::EnterPlanMode < Tool` в `src/tools/plan_mode.cr`:
  - [ ] `name`, `description` (§1.2), `parameters` (§1.2 — пустой strict).
  - [ ] `execute` (§1.4).
  - [ ] `entered_plan_mode_message(path)` (§1.5).
- [ ] Реализовать `Tools::ExitPlanMode < Tool` в том же файле:
  - [ ] `name`, `description` (§2.2), `parameters` (§2.3).
  - [ ] Валидация `options` (уникальность, reserved labels).
  - [ ] `execute` (§4) + `resolve_plan` + `format_auto_approved` /
        `format_user_approved`.
- [ ] Реализовать `inject_plan_reminder(memory, plan_service)` — вызывается
      из `Loop::Agent` перед каждым шагом.
- [ ] В `Permission::Manager#check` добавить plan-mode ветки (§5.4).
- [ ] Зарегистрировать оба тула в `Tools::Registry`.
- [ ] Тесты в `spec/tools/plan_mode_spec.cr`:
  - [ ] EnterPlanMode когда уже активно → ошибка.
  - [ ] EnterPlanMode успех → формат §1.5 (с/без path).
  - [ ] ExitPlanMode без plan mode → ошибка.
  - [ ] ExitPlanMode с пустым plan файлом → ошибка.
  - [ ] ExitPlanMode auto-mode → формат §4.2.
  - [ ] ExitPlanMode manual/yolo → формат §4.3.
  - [ ] Options: дубликат label / reserved label → ошибка валидации.
  - [ ] Permission: Write вне plan файла в plan mode → deny.
- [ ] Обновить `FIX-TOOLS.md`: отметить строки #7 и #8 выполненными.

---

## 8. Расхождения / допущения

- `plan-mode-tool-approve` / `plan-mode-guard-deny` / `exit-plan-mode-review-ask`
  политики свернуты в `Permission::Manager#check` напрямую. Это упрощение;
  в Crystal пока нет цепочки политик.
- Interactive review (manual/yolo с options) — упрощён: тул выходит из
  plan mode сразу, без отдельного ask. Полноценный review можно добавить
  через approval callback позже.
- `IAgentContextInjectorService` — упрощён до прямого вызова
  `Context::Memory#add_injection` из `Loop::Agent`.
- `agent.status.updated { planMode: true }` event — опущен (Crystal TUI
  может читать состояние plan_service напрямую).
- `wire.hooks.onDidRestore` (replay path) — опущен в первом приближении.
- Reminder variant logic (full/sparse/null) — упрощён: всегда full на
  первом шаге входа, на каждом 5-м assistant turn — повторно full.
