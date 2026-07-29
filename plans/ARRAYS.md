# Растущие структуры данных (выжимка из PROFILED-MEMORY.md)

Здесь оставлены **только** те in-memory структуры, объём которых **может
расти** во время работы приложения — неограниченно или до какого-то cap.
Transient-значения (живущие один вызов), статичные константы и
фиксированные скалярные поля исключены.

Рост классифицирован по трём категориям:
- **🔴 Неограниченный** — нет внутреннего cap; единственная защита — внешняя
  логика (compaction, завершение процесса).
- **🟡 Ограниченный** — растёт до известного предела (FIFO, hard cap, ручное
  очищение).
- **🟠 Потенциально большой** — размер одного экземпляра зависит от объёма
  данных (содержимое файла, тело ответа), накапливается внутри других коллекций.

---

## 1. Контекст и история диалога

| Файл | Тип | Рост | Что растёт |
|---|---|---|---|
| `src/context/memory.cr` | `Memory` (class) | 🔴 Неограниченный | `@history : Array(ContextMessage)` — основной кандидат на утечку; растёт до compaction |
| `src/context/memory.cr` | `ContextMessage` (struct) | 🔴 Неограниченный | число экземпляров пропорционально длине истории |
| `src/llm/types.cr` | `Message` (struct) | 🔴 Неограниченный | `content : String?`, `tool_calls : Array(ToolCall)?` — накапливаются в истории |
| `src/llm/types.cr` | `ToolCall` (struct) | 🔴 Неограниченный | число растёт с историей tool-call |
| `src/llm/types.cr` | `ToolCallFunction` (struct) | 🟠 Потенциально большой | `arguments : String` — у Write/Edit может быть мегабайтным |
| `src/llm/types.cr` | `ChatRequest` (struct) | 🔴 Неограниченный | `messages : Array(Message)` ссылается на всю историю при каждом шаге |

## 2. LLM-провайдеры (аккумуляторы стрима)

| Файл | Тип | Рост | Что растёт |
|---|---|---|---|
| `src/llm/openai_chat_provider.cr` | `OpenAIChatProvider` (class) | 🟡 В пределах шага | `accumulated_text` / `accumulated_tool_calls` во время стриминга; сбрасывается между шагами |
| `src/llm/moonshot_provider.cr` | `MoonshotProvider` (class) | 🟡 В пределах шага | как OpenAIChatProvider + OAuth |
| `src/llm/zai_provider.cr` | `ZaiProvider` (class) | 🟡 В пределах шага | как OpenAIChatProvider |

## 3. Loop (агентский цикл)

| Файл | Тип | Рост | Что растёт |
|---|---|---|---|
| `src/loop/dedup.cr` | `DedupTracker` (class) | 🟡 Ограниченный | `@call_history : Hash(String, Array(String))` — SHA-256-дайджесты, FIFO cap `MAX_HISTORY=24` per tool |

## 4. Tools — долгоживущее состояние

| Файл | Тип | Рост | Что растёт |
|---|---|---|---|
| `src/tools/todo_list.cr` | `TodoList` (class) | 🟡 Ограниченный пользователем | `@todos : Array(TodoItem)` |
| `src/tools/task.cr` | `AgentTaskInfo` (class) | 🔴 Неограниченный | число экземпляров растёт с числом фоновых задач |
| `src/tools/task.cr` | `AgentTaskOutputSnapshot` (struct) | 🟠 Потенциально большой | `preview : String` до 32 КБ |
| `src/tools/task.cr` | `InMemoryTaskService` (class) | 🔴 Неограниченный | `@tasks : Hash(String, AgentTaskInfo)`, `@outputs : Hash(String, AgentTaskOutputSnapshot)` — нет eviction |
| `src/tools/cron.cr` | `InMemoryCronService` (class) | 🟡 Ограниченный (cap 50) | `@tasks : Array(CronTask)`, `@next_fires : Hash(String, Int64)` |
| `src/tools/cron.cr` | `CronTask` (struct) | 🟠 Потенциально большой | `prompt : String` до 8 КБ |
| `src/tools/cron.cr` | `ParsedCronExpression` (class) | 🟡 Ограниченный | 5 `Set(Int32)` на инстанс; число инстансов ≤ число cron-задач |
| `src/tools/skill.cr` | `InMemorySkillCatalog` (class) | 🟡 Ограниченный числом файлов | `@skills : Hash(String, SkillDefinition)` |
| `src/tools/skill.cr` | `SkillDefinition` (struct) | 🟠 Потенциально большой | `content : String` — весь текст skill-файла |
| `src/tools/web_search.cr` | `WebSearchResult` (struct) | 🟡 Ограниченный числом результатов | `title`, `url`, `snippet` на результат |
| `src/tools/fetch_url.cr` | `UrlFetchResult` (struct) | 🟠 Потенциально большой | `body` — может быть мегабайтным |
| `src/tools/bash.cr` | `Bash` (class) | 🟡 В пределах вызова | буфер вывода процесса растёт во время выполнения команды |
| `src/tools/grep.cr` | `Grep` (class) | 🟠 Потенциально большой | результат (`RgRunResult`) — может быть большим при широком паттерне |

## 5. Permission

| Файл | Тип | Рост | Что растёт |
|---|---|---|---|
| `src/permission/manager.cr` | `Manager` (class) | 🔴 Неограниченный | `@session_approvals : Set(String)` — растёт с числом уникальных approve-session (SHA-256 ключи); нет eviction |
| `src/permission/policies.cr` | `RuleSet` (class) | 🟡 Конфиг-управляемый | `@rules : Array(Rule)` — ограничен содержимым конфига |

## 6. Prompt

| Файл | Тип | Рост | Что растёт |
|---|---|---|---|
| `src/prompt/system_prompt.cr` | `SystemPrompt` (class) | 🟠 Потенциально большой | собранный системный промпт — десятки КБ, долгоживущий |
| `src/prompt/agents_md.cr` | `AgentsMd` (class) | 🟡 Ограниченный числом файлов | загруженное содержимое вложенных `AGENTS.md` (`Hash(String, String)`) |

## 7. TUI (интерфейс)

| Файл | Тип | Рост | Что растёт |
|---|---|---|---|
| `src/tui/app.cr` | `App` (class) | 🔴 Неограниченный → cap | `@messages : Array(Message)` — крупнейший TUI-потребитель; растёт линейно (мягкий cap `keep_recent_turns=50`, после которого старые turn-ы коллапсируются в `step_summary`) |
| `src/tui/app.cr` | `App` (class) | 🟡 В пределах фрейма | `@previous_lines : Array(String)` — весь отрендеренный фрейм; пересоздаётся каждый render |
| `src/tui/app.cr` | `App` (class) | 🟡 Ограниченный (FIFO) | `@queue : Array(QueuedMessage)` — очередь отложенных сообщений; сбрасывается на turn-end |
| `src/tui/app.cr` | `App` (class) | 🟡 В пределах листинга | `@session_entries : Array(Session::SessionEntry)` — десятки–сотни на вызов пикера |
| `src/tui/app.cr` | `Message` (struct) | 🟠 Потенциально большой | `content`, `tool_result`, `tool_args` — основной объём; `read_group : Array(ReadGroupEntry)?` — массив параллельных Read |
| `src/tui/markdown.cr` | `Markdown` (class) | 🟡 Может расти | кэш рендеринга markdown — растёт с числом уникальных сообщений |

## 8. Session (листинги)

| Файл | Тип | Рост | Что растёт |
|---|---|---|---|
| `src/session/index.cr` | `SessionEntry` (struct) | 🟡 В пределах листинга | число экземпляров — десятки–сотни при каждом вызове `Index#list`; transient между вызовами, но может быть большим за один scan |

---

## Сводка по приоритету профилирования

Приоритет для внедрения `ProfiledArray` / `memsize` — по убыванию
максимально достижимого объёма:

1. **`Context::Memory` (`@history`)** — 🔴 неограниченный, главный потребитель.
2. **`TUI::App` (`@messages`)** — 🔴 растёт линейно, дублирует часть истории в TUI.
3. **`LLM::Message` / `ToolCall` / `ToolCallFunction`** — 🔴 накапливаются внутри истории; `arguments` и `content` дают основной bytesize.
4. **`InMemoryTaskService`** (`@tasks`, `@outputs`) — 🔴 нет eviction.
5. **`Permission::Manager` (`@session_approvals`)** — 🔴 нет eviction.
6. **`OpenAIChatProvider` и наследники** — 🟡 аккумуляторы в пределах шага (пик при больших ответах).
7. **`Prompt::SystemPrompt` / `AgentsMd`** — 🟠 большие долгоживущие строки.
8. **`DedupTracker`, `InMemoryCronService`, `InMemorySkillCatalog`, `TodoList`** — 🟡 ограниченные, низкий риск.
9. **`Markdown` (кэш), `SessionEntry` (листинги)** — 🟡 episodic, самый низкий приоритет.
