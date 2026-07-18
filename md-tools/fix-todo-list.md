# Fix TodoList — план доработки до паритета с JS

> Источник: `packages/agent-core-v2/src/session/todo/tools/todo-list.ts` +
> `todo-list.md`, `todo-list-write-reminder.md`,
> `session/todo/todoItem.ts`, `sessionTodo.ts`, `sessionTodoService.ts`,
> `sessionTodo/todoOps.ts`, `todoListReminder.ts`.
> Текущий Crystal: `kimi.cr/src/tools/todo_list.cr`.

## Текущее состояние

- Схема **уже выровнена** с JS:
  - `todos` array (опциональный — query-mode).
  - Каждый item: `{ title: String, status: "pending"|"in_progress"|"done" }`.
  - Нет `priority`, нет `cancelled`, нет `content` (legacy Crystal-схема).
  - Backwards-compat: `parse_status` принимает `"completed"` → `Done`.
- Query-mode: `todos == nil` → возвращает текущий список без мутации.
- Clear-mode: `todos == []` → clear + сообщение `"Todo list cleared."`.
- Write-reminder: после mutation — appended.
- Render format: `"Current todo list:\n  [status] title"`.
- `pending_count` — для reminder hook.

## Чего не хватает

### 1. **Persistence** (главный gap)

В JS `ISessionTodoService` persist'ит каждое изменение как
`tools.update_store` (`key: 'todo'`) wire record на main agent.

Crystal — `@todos` в in-memory `Array(TodoItem)`. При перезапуске
сессии (`kimi resume`) список теряется.

Нужно:

```crystal
abstract class TodoService
  abstract def get_todos : Array(TodoItem)
  abstract def set_todos(todos : Array(TodoItem)) : Nil
  abstract def load_from_store : Nil
  abstract def flush_persist : Nil
end
```

Реализация `SessionTodoService`:

- In-memory `Array(TodoItem)`.
- Persist в `{session_dir}/todo.json`:
  ```json
  [
    { "title": "...", "status": "pending" },
    { "title": "...", "status": "in_progress" }
  ]
  ```
- Load при инициализации сессии.
- Save после каждого `set_todos`.
- Wire record `tools.update_store(key: "todo")` для replay.

### 2. **`description` verbatim из `todo-list.md`**

JS description — расширенный:

```
Use this tool to manage your todo list for the current task. Adding, updating, and clearing todos helps you track multi-step work and decide what to do next.

Guidelines:
- Use the todo list proactively when working on tasks with 3+ steps.
- Maintain at most one `in_progress` todo at a time.
- Mark a todo `done` immediately after finishing it.
- Omit `todos` to read the current list without changes.
- Pass `todos: []` to clear the list.

Each todo has:
- `title` — short, actionable description.
- `status` — `pending`, `in_progress`, or `done`.
```

Текущий Crystal description — короче, менее prescriptive.

### 3. **Write-reminder verbatim**

JS `todo-list-write-reminder.md`:

```
Ensure that you continue to use the todo list to track progress.
Mark items as completed as soon as they finish, and select the next
in_progress item before resuming work. Do not let the list go stale.
```

Текущий Crystal `TODO_LIST_WRITE_REMINDER`:

```
Ensure that you continue to use the todo list to track progress.
Mark tasks done immediately after finishing them, and keep exactly
one task in_progress when work is underway.
```

Похоже по смыслу, но не verbatim. Привести к verbatim.

### 4. **Stale-reminder** (опционально)

JS `todoListReminder.ts` — инъектирует напоминание в context, если
список не обновлялся N ходов и есть `pending`/`in_progress` items.

В Crystal — `pending_count` уже есть; нужно в Loop-runner'е проверять
"давность" последнего update и при превышении порога добавлять
reminder через `Context::Memory#add_injection`.

Reminder text (пример):

```
Your todo list has not been updated recently. If you are still
working on the current task, mark items as done as you complete
them, or update the list to reflect your current plan.
```

### 5. **`renderTodoList` title**

JS:

```crystal
def render_todos(todos, title = "Current todo list:") : String
```

Crystal — текущий `"Current todo list:"` заголовок совпадает.

### 6. **Multi-line titles**

JS `TodoItemSchema`:

```ts
title: z.string().min(1)
```

— любой непустой title, включая multi-line.

Crystal — `String` без ограничений. Совпадает.

---

## 7. План реализации (чек-лист)

- [ ] Прочитать JS: `todo-list.ts`, `todo-list.md`,
      `todo-list-write-reminder.md`, `todoItem.ts`, `sessionTodo.ts`,
      `sessionTodoService.ts`, `todoOps.ts`, `todoListReminder.ts`.
- [x] Описать фикс-план в `md-tools/fix-todo-list.md`.
- [ ] Схема уже соответствует JS — **без изменений**.
- [ ] Расширить `description` до verbatim `todo-list.md` (§2).
- [ ] Привести `TODO_LIST_WRITE_REMINDER` к verbatim (§3).
- [ ] Реализовать `TodoService` (abstract) + `SessionTodoService`:
  - [ ] In-memory state.
  - [ ] Persist в `{session_dir}/todo.json`.
  - [ ] Load на session-init.
  - [ ] Save после каждого `set_todos`.
- [ ] Реализовать stale-reminder (§4):
  - [ ] Hook в Loop-runner'е — проверять last-update timestamp.
  - [ ] Inject напоминания через `Context::Memory#add_injection`.
- [ ] `Tools::TodoList` — инжектить `TodoService` через constructor.
- [ ] Тесты в `spec/tools/todo_list_spec.cr`:
  - [ ] Query-mode (`todos == nil`) → без мутации.
  - [ ] Write-mode → обновление + reminder append.
  - [ ] Clear-mode (`todos == []`) → `"Todo list cleared."`.
  - [ ] Persistence — set → load → check.
  - [ ] Stale-reminder — после N idle turns.
  - [ ] Status parse — `"completed"` → `Done` (backwards-compat).
- [ ] Обновить `FIX-TOOLS.md`: отметить TodoList-строку выполненной.

---

## 8. Расхождения / дополнения

- Persistence layout — `{session_dir}/todo.json` или wire record.
  В JS — wire record (`tools.update_store`), что поддерживает replay.
  В Crystal MVP — JSON-файл; wire record можно добавить позже для
  replay.
- Stale-reminder threshold — JS default 3 turns без update.
  В Crystal — configurable; начать с 3.
- `extendWorkspaceWithSkillRoots` — N/A.
- Tool registration — через `IAgentBuiltinToolsRegistrar` per agent.
  В Crystal — простой `tools.register(TodoList.new(...))` per agent.
- В JS каждый agent имеет свой TodoList (Session-scope). В Crystal —
  туl регистрируется один раз на main agent; для subagents — отдельная
  instance.
- `Tools::TodoList` уже frozen в контракте — основные изменения
  касаются **storage** слоя (state migration из in-memory в
  persisted).
