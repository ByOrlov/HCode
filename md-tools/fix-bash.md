# Fix Bash — план доработки до паритета с JS

> Источник: `packages/agent-core-v2/src/os/backends/node-local/tools/bash.ts`
> + `bash.md`, `process-task.ts`.
> Текущий Crystal: `h2code.cr/src/tools/bash.cr`.

## Текущее состояние

Crystal `Tools::Bash` — foreground-only:

- `run_in_background=true` отклоняется с ошибкой
  `"Background execution is not available for this agent. Do not set run_in_background=true."`.
- `MAX_TIMEOUT_S = 300`, `DEFAULT_TIMEOUT_S = 60`.
- Timeout → SIGTERM → grace 2s → SIGKILL.
- Нет `disable_timeout`.
- Нет auto-background-on-timeout.
- Нет background-task lifecycle (`TaskService.register_task`).

## Целевой паритет (JS `BashTool`)

### 1. `parameters` — расширить

Добавить:

```json
"description": {
  "type": "string",
  "description": "A short description for the background task. Required when run_in_background is true."
},
"run_in_background": {
  "type": "boolean",
  "description": "Whether to run the command as a background task."
},
"disable_timeout": {
  "type": "boolean",
  "description": "If true, do not apply a timeout to the command. Only applies when run_in_background is true."
}
```

`timeout` — обновить description:

```
Optional timeout in seconds for the command to execute. Foreground default 60s, max 300s. Background default 600s, max 86400s. Ignored for background commands when disable_timeout=true.
```

### 2. Константы

| Имя                                | Значение      |
|------------------------------------|---------------|
| `DEFAULT_TIMEOUT_S`                | `60`          |
| `MAX_TIMEOUT_S`                    | `5 * 60`      |
| `DEFAULT_BACKGROUND_TIMEOUT_S`     | `10 * 60`     |
| `MAX_BACKGROUND_TIMEOUT_S`         | `24 * 60 * 60` |

### 3. Description (dynamic, profile-dependent)

JS `BashTool` рендерит три варианта description:

- Полный (`allow_background && auto_background_on_timeout`).
- Без auto-background (`allow_background && !auto_background_on_timeout`).
- Без background (`!allow_background`) — текущее Crystal-поведение.

`allow_background = profile.is_tool_active("TaskList") && profile.is_tool_active("TaskOutput") && profile.is_tool_active("TaskStop")`.

`auto_background_on_timeout = config.bashAutoBackgroundOnTimeout ?? true`.

В Crystal: добавить флаги в `Tools::Bash.new(...)`:

```crystal
def initialize(@work_dir : String = Dir.current,
               @allow_background : Bool = false,
               @auto_background_on_timeout : Bool = true)
end
```

После регистрации тулов TaskList/TaskOutput/TaskStop — `allow_background=true`.

### 4. `validate_run_request`

```crystal
private def validate_run_request(args, signal) : ToolResult?
  return ToolResult.error("Aborted before command started") if signal.aborted?
  return ToolResult.error("Command cannot be empty.") if args.command.empty?
  return nil unless args.run_in_background == true
  return ToolResult.error("Background execution is not available for this agent because TaskOutput and TaskStop are not enabled.") unless @allow_background
  if args.description?.try(&.strip).presence.nil?
    return ToolResult.error("description is required when run_in_background is true.")
  end
  nil
end
```

### 5. `normalize_timeout_ms(timeout, is_background)`

```crystal
private def normalize_timeout_ms(timeout : Int32?, is_background : Bool) : Int32
  default = is_background ? DEFAULT_BACKGROUND_TIMEOUT_S : DEFAULT_TIMEOUT_S
  value = timeout || default
  cap = is_background ? MAX_BACKGROUND_TIMEOUT_S : MAX_TIMEOUT_S
  {value, cap}.min * 1000
end
```

### 6. execute — новая структура

```crystal
def execute(args, signal, on_update, on_foreground_task_start) : ToolResult
  err = validate_run_request(args, signal)
  return err if err

  starts_in_background = args.run_in_background == true
  foreground_timeout_ms = normalize_timeout_ms(args.timeout, false)
  command = args.command
  effective_cwd = args.cwd || @work_dir
  description = starts_in_background ? args.description.strip : foreground_description(args)
  timeout_ms = if starts_in_background
                 args.disable_timeout ? nil : normalize_timeout_ms(args.timeout, true)
               else
                 foreground_timeout_ms
               end

  proc = spawn(effective_cwd, command)   # существующий spawn
  close_process_stdin(proc)

  builder = ToolResultBuilder.new
  collect_foreground = !starts_in_background
  foreground_task_id : String? = nil

  task_id = @tasks.register_task(ProcessTask.new(proc, command, description,
    on_output: starts_in_background ? nil : ->(kind : String, text : String) {
      return unless collect_foreground
      on_update.try(&.call(kind, text))
      builder.write(text)
      # ... persist on truncation
    }
  ),
    detached: starts_in_background,
    timeout_ms: timeout_ms,
    detach_timeout_ms: DEFAULT_BACKGROUND_TIMEOUT_S * 1000,
    auto_background_on_timeout: @allow_background && @auto_background_on_timeout,
    signal: starts_in_background ? nil : signal,
  )
  foreground_task_id = starts_in_background ? nil : task_id
  on_foreground_task_start.try(&.call(task_id)) unless starts_in_background

  return background_started_result(task_id, proc, description, ...) if starts_in_background

  release = @tasks.wait_for_foreground_release(task_id)
  case release
  when .detached?, .timeout_detached?
    collect_foreground = false
    return background_started_result(task_id, proc, description, ...,
                                     builder, scenario: :foreground_detached)
  end

  foreground_completion_result(task_id, proc, builder, foreground_timeout_ms)
ensure
  collect_foreground = false
end
```

### 7. `background_started_result`

Вывод (key-value):

```
task_id: bash-1
pid: 12345
description: npm run build
status: running
automatic_notification: true
next_step: The completion arrives automatically in a later turn — do NOT wait, poll, or call TaskOutput on it; continue with your current work.
next_step: Use TaskStop only if the task must be cancelled.
human_shell_hint: Tell the human to run /tasks to open the interactive background-task panel.
```

При `scenario: :foreground_detached` первая `next_step` отличается:
`"The task now runs in the background. You will be automatically notified when it completes — do NOT wait, poll, or call TaskOutput on it; continue with your current work."`

Если у тулов TaskList/TaskOutput/TaskStop нет (`!@allow_background`):
`"next_step: You will be automatically notified when it completes."`

Если был собран foreground output перед detach — добавляется блок
`foreground_output:\n<...>`.

### 8. `foreground_completion_result`

```crystal
current = @tasks.get_task(task_id)
exit_code = current.try(&.process?).try(&.exit_code) || proc.exit_code

result =
  case
  when current.try(&.timed_out?)        then builder.error("Command killed by timeout (#{format_timeout_label(timeout_ms)})")
  when current.try(&.killed_by_user?)    then builder.error("Interrupted by user")
  when current.try(&.stop_reason.presence)
    builder.error(current.stop_reason)
  when exit_code == 0                   then builder.ok("Command executed successfully.")
  else
    builder.write("Process exited with code #{exit_code}") if builder.n_chars == 0
    builder.error("Command failed with exit code: #{exit_code}.")
  end

add_foreground_output_reference(task_id, result)
```

### 9. `add_foreground_output_reference`

Если `result.truncated?`:
- `output = @tasks.get_output_snapshot(task_id, 0)`.
- Если `output.full_output_available && output.output_path`:
  ```
  <existing_output>

  [Full output saved]
  task_id: bash-1
  output_path: /tmp/.../task-1.log
  output_size_bytes: 102400
  next_step: Use Read with output_path to page through the full log, or TaskOutput(task_id="bash-1", block=false).
  ```
  (без `, or TaskOutput(...)` если `!@allow_background`)

### 10. `format_timeout_label(ms)`

```crystal
ms % 1000 == 0 ? "#{ms / 1000}s" : "#{ms}ms"
```

### 11. Зависимости от `TaskService`

Bash теперь зависит от `TaskService` (см. `md-tools/task.md`):

```crystal
def initialize(@work_dir : String = Dir.current,
               @tasks : TaskService? = nil,
               @allow_background : Bool = false,
               @auto_background_on_timeout : Bool = true)
end
```

Если `@tasks.nil?` — старое foreground-only поведение (для тестов).

### 12. `ProcessTask` adapter

```crystal
class ProcessTask < AgentTask
  property command : String
  property description : String
  property exit_code : Int32?
  @on_output : ((String, String) -> Nil)?

  def start(sink) : Nil
    spawn { capture_output(sink) }
    spawn { wait_for_exit(sink) }
  end

  def force_stop : Nil
    @proc.terminate rescue nil
  end

  def to_info(base : AgentTaskInfoBase) : AgentTaskInfo
    base.merge({command: command, pid: @proc.pid, exit_code: exit_code})
  end
end
```

---

## План реализации (чек-лист)

- [ ] Прочитать JS: `bash.ts` (полностью), `bash.md`, `process-task.ts`,
      `agent/task/configSection.ts`.
- [x] Описать фикс-план в `md-tools/fix-bash.md`.
- [ ] Реализовать `TaskService` (см. `md-tools/task.md`).
- [ ] Реализовать `ProcessTask` adapter (`src/tools/process_task.cr`).
- [ ] Расширить `Tools::Bash#parameters` (§1).
- [ ] Добавить dynamic description (§3).
- [ ] Реализовать `validate_run_request` (§4).
- [ ] Реализовать `normalize_timeout_ms` (§5).
- [ ] Реализовать новый `execute` flow (§6) с background/auto-background.
- [ ] Реализовать `background_started_result` (§7).
- [ ] Реализовать `foreground_completion_result` (§8) +
      `add_foreground_output_reference` (§9).
- [ ] Реализовать `format_timeout_label` (§10).
- [ ] Обновить constructor — принимать `TaskService` + flags.
- [ ] Регистрация: после создания TaskList/TaskOutput/TaskStop —
      пересоздать Bash с `allow_background: true` (или передать через
      config).
- [ ] Тесты в `spec/tools/bash_spec.cr`:
  - [ ] Foreground success/error/timeout/signal — без регрессий.
  - [ ] `run_in_background=true` без TaskService → reject.
  - [ ] `run_in_background=true` без description → reject.
  - [ ] Background start → metadata output format.
  - [ ] Auto-background-on-timeout → foreground_detached output.
  - [ ] `disable_timeout=true` + background → timeout_ms=nil.
  - [ ] Truncated output → `[Full output saved]` reference.
- [ ] Обновить `FIX-TOOLS.md`: отметить Bash-строку выполненной.

---

## Расхождения / допущения

- Windows bash path rewriting — `windows_path_to_posix_path` +
  `rewrite_windows_null_redirect`. В Crystal — опустить (Linux-only
  MVP), либо добавить через `Crystal::Platform.windows?`.
- `ISessionProcessRunner` — в Crystal прямое `Process.new`, нет
  отдельной abstraction.
- `ToolResultBuilder` — добавить класс в Crystal с `.write`, `.ok`,
  `.error`, `.truncated?`, `.n_chars` для инкрементальной сборки output.
- `ToolUpdate` callback (`on_update`) — для streaming-display в TUI.
  В Crystal — через `proc` или `Channel`.
- `on_foreground_task_start` — позволяет TUI зарегистрировать
  interrupt-handler на foreground task (Ctrl-C → TaskStop).
- `userCancellationReason` — константная reason-строка `"Interrupted by user"`,
  по которой `foreground_completion_result` отличает user-kill от
  других killed-случаев.
