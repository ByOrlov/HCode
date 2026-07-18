# Task tools — план портирования из JS в Crystal

> Источник: `packages/agent-core-v2/src/agent/task/`:
> `tools/task-list.ts` + `.md`, `tools/task-output.ts` + `.md`,
> `tools/task-stop.ts` + `.md`, `tools/format.ts`,
> `types.ts`, `task.ts` (contract), `taskService.ts` (impl),
> `notificationXml.ts`, `taskOps.ts`, `persist.ts`, `errors.ts`,
> `configSection.ts`.

Цель — 3 тула в `kimi.cr/src/tools/task.cr` (`Tools::TaskList`,
`Tools::TaskOutput`, `Tools::TaskStop`), плюс минимальная `TaskService`
абстракция и `render_notification_xml`. Все 3 тула регистрируются только
для main agent (как и goal-тулы).

---

## 1. Общая модель

```crystal
enum AgentTaskStatus
  Running
  Completed
  Failed
  TimedOut
  Killed
  Lost
end

TERMINAL_STATUSES = Set{
  AgentTaskStatus::Completed,
  AgentTaskStatus::Failed,
  AgentTaskStatus::TimedOut,
  AgentTaskStatus::Killed,
  AgentTaskStatus::Lost,
}

struct AgentTaskInfo
  property task_id : String
  property description : String
  property status : AgentTaskStatus
  property detached : Bool?
  property started_at : Int64
  property ended_at : Int64?
  property stop_reason : String?
  property terminal_notification_suppressed : Bool?
  property timeout_ms : Int64?
  # shell-task specific (kind = "bash"):
  property command : String?
  property pid : Int64?
  property exit_code : Int32?
end

struct AgentTaskOutputSnapshot
  property output_path : String?
  property output_size_bytes : Int32
  property preview_bytes : Int32
  property truncated : Bool
  property full_output_available : Bool
  property preview : String
end
```

### Status → string

`Running → "running"`, `Completed → "completed"`, `Failed → "failed"`,
`TimedOut → "timed_out"`, `Killed → "killed"`, `Lost → "lost"` —
**snake_case** на проводе.

---

## 2. `TaskList` — контракт

### 2.1. `name`

`"TaskList"`.

### 2.2. `description` (verbatim, `task-list.md`)

```
List background tasks and their current status.

Use this tool to discover which background tasks exist and where each one
stands. It is the entry point for inspecting background work: it returns a
task ID, status, and description for every task it reports, plus the command,
PID, and (once finished) exit code for shell tasks, and a stop reason for any
task that ended early.

Guidelines:

- After a context compaction, or whenever you are unsure which background
  tasks are running or what their task IDs are, call this tool to
  re-enumerate them instead of guessing a task ID.
- Prefer the default `active_only=true`, which lists only non-terminal tasks.
  Pass `active_only=false` only when you specifically need to see tasks that
  have already finished. With `active_only=false` the result may also include
  `lost` tasks — tasks left over from a previous process that can no longer be
  inspected or controlled; treat them as already terminated.
- `limit` caps how many tasks are returned. It accepts a value between 1 and
  100 and defaults to 20 when omitted.
- This tool only lists tasks; it does not return their output. Use it first
  to locate the task ID you need, then call `TaskOutput` with that ID to read
  the task's output and details.
- This tool is read-only and does not change any state, so it is always safe
  to call, including in plan mode.
```

### 2.3. `parameters`

```json
{
  "type": "object",
  "properties": {
    "active_only": {
      "type": "boolean",
      "default": true,
      "description": "Whether to list only non-terminal background tasks."
    },
    "limit": {
      "type": "integer",
      "minimum": 1,
      "maximum": 100,
      "default": 20,
      "description": "Maximum number of tasks to return."
    }
  },
  "additionalProperties": false
}
```

Defaults applied by schema (zod `.default()`): `active_only=true`,
`limit=20`.

### 2.4. `format_task_list(tasks, active_only) : String`

```
active_background_tasks: 2
task_id: bash-1
description: npm run build
status: running
started_at: 1700000000
command: npm run build
pid: 12345
---
task_id: bash-2
...
```

- Header: `"<label>: <count>"`, где `label = active_only ? "active_background_tasks" : "background_tasks"`.
- Empty: `"<label>: 0\nNo background tasks found."`.
- Records join with `"\n---\n"`.
- `format_plain_object(record)` — `key: value` per line, опускает `nil`,
  конвертирует `CamelCase` → `snake_case` (`replaceAll(/[A-Z]/g, "_$&".toLowerCase())`).

### 2.5. `matchesRule` / approval

- `approvalRule: "TaskList"`.
- `matchesRule: matchesGlobRuleSubject(ruleArgs, listScope)`, где
  `listScope = active_only ? "active" : "all"`.
- `description: "Listing background tasks"`.

### 2.6. execute

```crystal
def execute(args) : ToolResult
  active_only = args.active_only || true
  limit       = args.limit || 20
  tasks = @tasks.list(active_only, limit)
  ToolResult.ok(format_task_list(tasks, active_only))
end
```

---

## 3. `TaskOutput` — контракт

### 3.1. `name`

`"TaskOutput"`.

### 3.2. `description` (verbatim, `task-output.md`)

```
Retrieve a snapshot of a running or completed background task.

Use this after `Bash(run_in_background=true)` or `Agent(run_in_background=true)` to check progress, or to read the output of a task that has already completed.

Guidelines:
- Prefer relying on automatic completion notifications. Use this tool only when you need task output before the automatic notification arrives.
- By default this tool is non-blocking and returns a current status/output snapshot — that is the normal way to use it.
- Do not use TaskOutput to wait for a result you need before continuing — if your next step depends on the task's result, run that task in the foreground instead. TaskOutput is for a deliberate progress check you will act on without blocking, not a way to sit and wait for a background task you just launched.
- Use block=true only when the user explicitly asked you to wait for the task. Never block on a task you launched in the current turn — if you need its result right away, it should have been a foreground call.
- If a block=true call returns `retrieval_status: timeout` (the task is still running), do not block on the same task again. Continue with other work or hand back to the user — the completion notification arrives on its own.
- This tool returns structured task metadata, a fixed-size output preview, and an output_path for the full log.
- For a terminal task, the metadata also explains why it ended. A shell command that runs to completion reports `status: completed` on a zero exit, or `status: failed` with its non-zero `exit_code` — judge that failure from the `exit_code`, because a plain command failure carries no `stop_reason` and no `terminal_reason`. `terminal_reason` is a categorical label emitted only when the end is not an ordinary exit: `timed_out` when the deadline aborted it, `stopped` when it was explicitly stopped, or `failed` when it errored without producing an exit code; the `stopped` and `failed` cases also carry a human-readable `stop_reason`. A task that finished on its own with a clean exit carries neither `stop_reason` nor `terminal_reason`.
- The full, never-truncated log is always available at output_path; use the `Read` tool with that path to page through it, whether or not the preview was truncated.
- This tool works with the generic background task system and should remain the primary read path for future task types, not just bash.
```

### 3.3. `parameters`

```json
{
  "type": "object",
  "properties": {
    "task_id": {
      "type": "string",
      "description": "The background task ID to inspect."
    },
    "block": {
      "type": "boolean",
      "default": false,
      "description": "Whether to wait for the task to finish before returning. Discouraged — background tasks notify automatically on completion; use only when the user explicitly asked you to wait."
    },
    "timeout": {
      "type": "integer",
      "minimum": 0,
      "maximum": 3600,
      "default": 30,
      "description": "Maximum number of seconds to wait when block=true."
    }
  },
  "required": ["task_id"],
  "additionalProperties": false
}
```

### 3.4. Константы

| Имя                    | Значение       |
|------------------------|----------------|
| `OUTPUT_PREVIEW_BYTES` | `32 * 1024`    |
| `PAGING_HINT_LINES`    | `300`          |

### 3.5. `retrieval_status(status, block)`

- terminal → `"success"`.
- non-terminal + `block == true` → `"timeout"`.
- non-terminal + `block != true` → `"not_ready"`.

### 3.6. `terminal_reason(info)`

- `TimedOut` → `"timed_out"`.
- `Killed` и `stop_reason` не nil → `"stopped"`.
- `Failed` и `stop_reason` не nil → `"failed"`.
- иначе → `nil` (в выводе не появляется — `format_plain_object` опускает).

### 3.7. `full_output_hint(output)`

- `!output.full_output_available || output.output_path.nil?` → `nil`.
- `output.truncated` →
  `"Only the last #{OUTPUT_PREVIEW_BYTES} bytes are shown above. Use the Read tool with the output_path to page through the full log (parameters: path, line_offset, n_lines; read about #{PAGING_HINT_LINES} lines per page)."`.
- иначе →
  `"The preview above is the complete output. Use the Read tool with the output_path if you need to re-read the full log later (parameters: path, line_offset, n_lines; read about #{PAGING_HINT_LINES} lines per page)."`.

### 3.8. `next_step`

`block == true && !terminal` →
`"The task is still running after waiting. Do not block on it again — continue with other work or hand back to the user; you will be notified automatically when it completes."`.

иначе — `nil`.

### 3.9. `execute` — алгоритм

1. `info = @tasks.get_task(task_id)`.
   - `nil` → `ToolResult.error("Task not found: #{task_id}")`.
2. Если `block == true && !terminal(info.status)`:
   `@tasks.wait(task_id, (timeout || 30) * 1000, signal)`.
3. `current = @tasks.get_task(task_id)`. Если `nil` → `ToolResult.error("Task not found: #{task_id}")`.
4. `output = @tasks.get_output_snapshot(task_id, OUTPUT_PREVIEW_BYTES)`.
5. Сборка record (все поля через `format_plain_object`, опуская `nil`):

```
retrieval_status: success
task_id: bash-1
description: npm run build
status: running
started_at: 1700000000
command: npm run build
pid: 12345
output_path: /tmp/.../task-1.log
terminal_reason: timed_out       # только если есть
output_size_bytes: 102400
output_preview_bytes: 32768
output_truncated: true
full_output_available: true
full_output_tool: Read
full_output_hint: Only the last 32768 bytes are shown above. Use ...
next_step: ...                    # только если есть
```

Затем пустая строка, затем truncation banner (если truncated):
- если `full_output_available && output_path` → `[Truncated. Full output: #{path}]`
- иначе → `[Truncated. No persisted full log is available for this task.]`

Затем `[output]` и `output.preview || "[no output available]"`.

### 3.10. Approval / display

- `approvalRule: "TaskOutput"`.
- `matchesRule: matchesGlobRuleSubject(ruleArgs, task_id)`.
- `description: "Reading output of task #{task_id}"`.

---

## 4. `TaskStop` — контракт

### 4.1. `name`

`"TaskStop"`.

### 4.2. `description` (verbatim, `task-stop.md`)

```
Stop a running background task.

Only use this when a task must genuinely be cancelled — for a task that is
finishing normally, wait for its completion notification or inspect it with
`TaskOutput` instead of stopping it.

Guidelines:
- This is a general-purpose stop capability for any background task. It is not
  a bash-specific kill.
- Stopping a task is destructive: it may leave partial side effects behind.
  Use it with care.
- If the task has already finished, this tool simply returns its current
  status.
```

### 4.3. `parameters`

```json
{
  "type": "object",
  "properties": {
    "task_id": {
      "type": "string",
      "description": "The background task ID to stop."
    },
    "reason": {
      "type": "string",
      "default": "Stopped by TaskStop",
      "description": "Short reason recorded when the task is stopped."
    }
  },
  "required": ["task_id"],
  "additionalProperties": false
}
```

### 4.4. `execute` — алгоритм

1. `info = @tasks.get_task(task_id)`.
   - `nil` → `ToolResult.error("Task not found: #{task_id}")`.
2. `reason = (args.reason?.try(&.strip).presence) || "Stopped by TaskStop"`.
3. Если `TERMINAL_STATUSES.includes?(info.status)`:
   ```
   task_id: #{info.task_id}
   status: #{info.status}
   reason: #{terminal_stop_reason(info.stop_reason)}
   ```
   где `terminal_stop_reason(r) = r.try(&.strip).presence || "Task already in terminal state"`.
4. Иначе:
   - `@tasks.suppress_terminal_notification(task_id)` — чтобы не
     дублировать уведомление после ручного стопа.
   - `result = @tasks.stop(task_id, reason)`.
   - `result.nil?` → `ToolResult.error("Failed to stop task: #{task_id}")`.
   - иначе:
     ```
     task_id: #{result.task_id}
     status: #{result.status}
     reason: #{result.stop_reason || reason}
     ```

### 4.5. Approval / display

- `approvalRule: "TaskStop"`.
- `matchesRule: matchesGlobRuleSubject(ruleArgs, task_id)`.
- `description: "Stopping task #{task_id}"`.

---

## 5. `render_notification_xml` (для terminal-notification delivery)

Файл `notificationXml.ts` — рендерит XML-блок, который инъектируется в
context при завершении detached-задачи.

```crystal
def render_notification_xml(data : Hash(String, JSON::Type)) : String
  id          = string_attr(data["id"]?, "unknown")
  category    = string_attr(data["category"]?, "unknown")
  type        = string_attr(data["type"]?, "unknown")
  source_kind = string_attr(data["source_kind"]?, "unknown")
  source_id   = string_attr(data["source_id"]?, "unknown")
  agent_id    = optional_string_attr(data["agent_id"]?)
  title       = data["title"]?.as?(String) || ""
  severity    = data["severity"]?.as?(String) || ""
  body        = data["body"]?.as?(String) || ""
  children    = child_blocks(data["children"]? || data["extraBlocks"]?)

  agent_attr = agent_id ? %( agent_id="#{agent_id}") : ""
  lines = [%(<notification id="#{id}" category="#{category}" type="#{type}" source_kind="#{source_kind}" source_id="#{source_id}"#{agent_attr}>)]
  lines << "Title: #{title}" unless title.empty?
  lines << "Severity: #{severity}" unless severity.empty?
  lines << body unless body.empty?
  lines.concat(children)
  lines << "</notification>"
  lines.join('\n')
end
```

- `string_attr(v, fallback)` — если `String` и непустой, то
  `escape_xml_attr(v)`, иначе `fallback`.
- `optional_string_attr(v)` — nil для не-String/пустой, иначе escaped.
- `child_blocks(v)` — массив строк; `"string"` → `[v]`,
  `Array(String)` → отфильтрованный по непустым, иначе `[]`.
- `escape_xml_attr` — экранирует `"`, `&`, `<`, `>`, `\n`, `\r`, `\t` в
  XML-attribute-форме (как `xml-escape.ts`).

### Использование

В `taskService.ts` при settle detached-задачи:

```crystal
context_memory.add_injection(render_notification_xml({
  "id"          => notification_id,
  "category"    => "task_completion",
  "type"        => ctx.notification_type,
  "source_kind" => ctx.source_kind,
  "source_id"   => ctx.source_id,
  "agent_id"    => ctx.agent_id,
  "title"       => ctx.title,
  "severity"    => ctx.severity.to_s,
  "body"        => ctx.body,
}))
```

---

## 6. `TaskService` — абстракция

```crystal
abstract class TaskService
  abstract def list(active_only : Bool = true, limit : Int32 = 20) : Array(AgentTaskInfo)
  abstract def get_task(task_id : String) : AgentTaskInfo?
  abstract def get_output_snapshot(task_id : String, max_preview_bytes : Int32) : AgentTaskOutputSnapshot
  abstract def suppress_terminal_notification(task_id : String) : Nil
  abstract def stop(task_id : String, reason : String? = nil) : AgentTaskInfo?
  abstract def stop_by_user(task_id : String) : AgentTaskInfo?
  abstract def stop_all(reason : String? = nil) : Array(AgentTaskInfo)
  abstract def stop_all_on_exit(reason : String) : Array(AgentTaskInfo)
  abstract def wait(task_id : String, timeout_ms : Int64? = nil, signal : AbortSignal? = nil) : AgentTaskInfo?
  abstract def detach(task_id : String) : AgentTaskInfo?
end
```

### Хранение

- `Hash(String, AgentTaskState)` — task_id → state (task info + output
  buffer + IO pipe + stop flag).
- Output retention: in-memory ring buffer + persisted file under
  session scratch (`{session_dir}/tasks/{task_id}.log`). Полный лог
  пишется в файл, preview возвращается из tail-of-file.
- Detach: состояние остаётся; `AgentTaskInfo.detached = true`;
  notify-on-settle (если не suppressed).

### Agent scope

- `TaskService` инстанцируется **per agent** (agent-scope). Main agent
  имеет свой; subagents — свои.

---

## 7. План реализации (чек-лист)

- [ ] Прочитать JS: `tools/*.ts` + `.md`, `format.ts`, `types.ts`,
      `task.ts`, `taskService.ts`, `notificationXml.ts`, `taskOps.ts`,
      `persist.ts`, `errors.ts`, `configSection.ts`.
- [x] Описать контракт в `md-tools/task.md`.
- [ ] Реализовать `AgentTaskStatus` + `TERMINAL_STATUSES` enum/Set.
- [ ] Реализовать `format_plain_object(record)` утилиту в
      `src/tools/task.cr` (или `src/utils/format.cr`):
  - опускает `nil`,
  - `CamelCase` → `snake_case`,
  - `String` → как есть; остальные — `to_s`.
- [ ] Реализовать `Tools::TaskList` (§2) — минимальный, без blocking.
- [ ] Реализовать `Tools::TaskOutput` (§3) со всеми ветками:
  - [ ] `retrieval_status`, `terminal_reason`, `full_output_hint`,
        `next_step`.
  - [ ] Read из output snapshot (tail preview).
- [ ] Реализовать `Tools::TaskStop` (§4):
  - [ ] `terminal_stop_reason`.
  - [ ] suppressTerminalNotification перед `stop`.
- [ ] Реализовать `render_notification_xml` + `escape_xml_attr`.
- [ ] Реализовать `TaskService` (abstract) + простую in-memory
      реализацию для background bash.
- [ ] Подключить к bash-инструменту: при `run_in_background=true`
      запускать процесс через `TaskService.register_task`, а не
      синхронно. Это потребует фикс-плана для Bash.
- [ ] Регистрация тулов в `src/kimi.cr:166` для main agent.
- [ ] Тесты в `spec/tools/task_spec.cr`:
  - [ ] TaskList — empty/non-empty; `active_only` filter; `limit` cap;
        `lost`-задачи при `active_only=false`.
  - [ ] TaskOutput — terminal/non-terminal; `block=false` returns
        snapshot; `block=true` → `timeout` на running; truncation
        banner; `output_path` absent hint; `next_step`.
  - [ ] TaskStop — already-terminal возвращает status; running → stop;
        `Failed to stop`; `Task not found`.
- [ ] Обновить `FIX-TOOLS.md`: отметить строки #13–#15 выполненными.

---

## 8. Расхождения / допущения

- `task_id` нейминг для bash-tasks — `bash-N` (incrementing). Subagent
  tasks — `agent-N`. На уровне TaskService — prefix-registered через
  `AgentTaskTrackOptions#idPrefix`.
- `block=true` на running задаче: Crystal не имеет `AbortSignal`
  встроенного; вводим свой lightweight `class AbortSignal` с
  `#cancelled?`/`#cancel` (или используем `Channel(Nil)`).
- `output_path` — может быть `nil`, если persisted-файл не создан
  (короткая задача, не успела флашить). В этом случае
  `fullOutputAvailable=false`, banner предупреждает.
- Notification XML — добавляется в `Context::Memory#add_injection` (как
  skill/plan-mode reminders).
- `lost`-задачи — появляются только если state persisted и процесс
  умер. В простейшей in-memory реализации их не будет; пометить как
  future work.
- `taskService.stop_all_on_exit` — hook на session-close. Crystal-стор
  — в `Session#close` вызывать `TaskService#stop_all_on_exit`.
- `terminal_notification_suppressed` хранится per-task, чтобы избежать
  дубликата после `TaskStop`. Достаточно флага в `AgentTaskState`.
