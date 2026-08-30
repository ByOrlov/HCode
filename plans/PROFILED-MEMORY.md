# План: ProfiledStruct / ProfiledArray — профилирование памяти в Crystal-версии

Цель: унаследовать все структуры и коллекции данных, которые приложение
удерживает в памяти, от новых базовых классов `ProfiledStruct` /
`ProfiledArray`, дающих метод `.memsize`. Каждая такая структура автоматически
регистрируется в едином реестре по идентификатору `FILE+StructName`, так что в
любой момент можно вызвать `.memsize` на реестре и получить актуальную картину
потребления памяти — с разбивкой по файлам и типам.

---

## 1. Полная таблица данных, хранящихся в памяти

В таблице перечислены **только** данные, которые удерживаются дольше одного
вызова функции (поля классов, глобальные/классовые переменные, долгоживущие
сервисы). Transient локальные переменные внутри методов (буферы `IO::Memory`,
промежуточные `Array`, JSON-парсинг на один вызов) сюда не входят — они
освобождаются GC и не являются предметом профилирования.

### 1.1. Контекст и история диалога (крупнейший потребитель)

| Файл | Тип | Вид | Поля / размеры | Поведение роста |
|---|---|---|---|---|
| `src/context/memory.cr` | `ContextMessage` | struct | `message : LLM::Message`, `origin : MessageOrigin` | растёт пропорц. числу сообщений |
| `src/context/memory.cr` | `Memory` | class | `@history : Array(ContextMessage)`, `@token_count : Int32`, `@max_context_tokens : Int32` | **неограниченно растёт** до compaction; основной кандидат на утечку |
| `src/context/undo.cr` | `UndoResult` | struct | `removed_count : Int32`, `truncated : Bool` | transient |
| `src/context/overflow.cr` | `Overflow::Recovery` | class | состояние projection/action внутри одного turn (проекции/compaction) | сбрасывается каждый turn |
| `src/context/budget.cr` | `Budget` | class | бюджетные лимиты turn/tokens | маленький |

### 1.2. LLM-уровень (сообщения, запросы, стрим)

| Файл | Тип | Вид | Поля / размеры | Поведение роста |
|---|---|---|---|---|
| `src/llm/types.cr` | `Usage` | struct | `prompt_tokens`, `completion_tokens`, `total_tokens` (Int32) | маленький; аккумулируется в `total_usage` |
| `src/llm/types.cr` | `ToolCall` | struct | `id`, `type`, `function : ToolCallFunction` | растёт с числом tool-call в истории |
| `src/llm/types.cr` | `ToolCallFunction` | struct | `name`, `arguments : String` | `arguments` может быть мегабайтным (Write/Edit) |
| `src/llm/types.cr` | `ToolDefinition` | struct | `type`, `function : ToolFunction` | ~27 на инстанс (по числу тулов) |
| `src/llm/types.cr` | `ToolFunction` | struct | `name`, `description`, `parameters : JSON::Any` | статично |
| `src/llm/types.cr` | `Message` | struct | `role`, `content : String?`, `tool_calls : Array(ToolCall)?`, `tool_call_id : String?` | растёт с историей; `content` — основной объём |
| `src/llm/types.cr` | `ThinkingConfig` | struct | `type`, `effort` | маленький |
| `src/llm/types.cr` | `ChatRequest` | struct | `model`, `messages : Array(Message)`, `tools : Array(ToolDefinition)?`, ~10 scalar полей | **ссылается на всю историю** при каждом шаге |
| `src/llm/types.cr` | `StreamChunk` | struct | `choices : Array(StreamChoice)`, `usage : Usage?` | transient per-chunk |
| `src/llm/types.cr` | `StreamChoice` | struct | `index`, `delta : Delta?`, `finish_reason`, `usage` | transient |
| `src/llm/types.cr` | `Delta` | struct | `role`, `content`, `reasoning_content`, `tool_calls : Array(DeltaToolCall)?` | transient |
| `src/llm/types.cr` | `DeltaToolCall` / `DeltaToolCallFunction` | struct | скаляры | transient |
| `src/llm/types.cr` | `TextPart` / `ThinkPart` / `ToolCallPart` / `UsagePart` / `FinishPart` | class (наследники `MessagePart`) | текст/id/аргументы | transient в стрим-колбэке |
| `src/llm/types.cr` | `StepResult` | struct | `stop_reason`, `text`, `tool_calls : Array(ToolCall)`, `usage` | один на шаг |
| `src/llm/types.cr` | `TurnResult` | struct | `stop_reason`, `steps`, `usage` | один на turn |
| `src/llm/provider.cr` | `ProviderInfo` | struct | `name`, `display_name`, ... | статичный список (`KNOWN_PROVIDERS`) |
| `src/llm/provider.cr` | `Provider` (abstract) | class | `@model_name`, `@thinking_effort`, `@max_context_tokens`, `@used_context_tokens`, `@prompt_cache_key` | долгоживущий |
| `src/llm/openai_chat_provider.cr` | `OpenAIChatProvider < Provider` | class | HTTP-клиент, аккумуляторы `accumulated_text`/`accumulated_tool_calls` во время стрима | растёт во время одного шага |
| `src/llm/moonshot_provider.cr` | `OAuthCredentials` | class | токены из `~/.kimi-code/credentials` | статично |
| `src/llm/moonshot_provider.cr` | `MoonshotProvider` | class | как OpenAIChatProvider + OAuth | долгоживущий |
| `src/llm/zai_provider.cr` | `ZaiProvider` | class | как OpenAIChatProvider | долгоживущий |
| `src/llm/mock_provider.cr` | `MockStep` | struct | `responses : Array(String)`, `usage` | — |
| `src/llm/mock_provider.cr` | `MockProvider` | class | `@script : Array(MockStep)`, счётчик шагов | долгоживущий |
| `src/llm/token_counter.cr` | — | module | без состояния | — |

### 1.3. Loop (агентский цикл)

| Файл | Тип | Вид | Поля / размеры | Поведение роста |
|---|---|---|---|---|
| `src/loop/agent.cr` | `Agent` | class | `@provider`, `@context : Context::Memory`, `@tools : Tools::Registry`, `@permission`, `@abort_controller`, `@dedup : DedupTracker`, `@overflow_recovery`, `@max_steps` | долгоживущий; ссылается на Memory (крупный) |
| `src/loop/dedup.cr` | `DedupTracker` | class | `@call_history : Hash(String, Array(String))` — SHA-256-дайджесты, capped `MAX_HISTORY=24` per tool | **ограничен**, FIFO |
| `src/loop/tool_batch.cr` | `ToolBatchResult` | struct | скаляры | transient |
| `src/loop/tool_batch.cr` | `PlannedCall` | struct | `id`, `name`, `args`, `status` | transient per-batch |
| `src/loop/tool_batch.cr` | `ToolBatch` | class | реестр+permission+dedup+abort+context (ссылки) | transient per-batch |
| `src/loop/abort.cr` | `AbortController` | class | флаг abort + reason | маленький |
| `src/loop/events.cr` | `Event` | class | `type : EventType`, текст/step/usage поля | один экземпляр переиспользуется в колбэке |

### 1.4. Tools (тулы и их состояние)

| Файл | Тип | Вид | Поля / размеры | Поведение роста |
|---|---|---|---|---|
| `src/tools/tool.cr` | `Tool` (abstract) | class | имя/description/parameters (JSON::Any) | ~27 инстансов, статично |
| `src/tools/tool.cr` | `ToolDisplay` | struct | `kind`, `operation`, `path`, `before`, `after` (String?) | `before`/`after` могут быть большими (diff) |
| `src/tools/tool.cr` | `ToolResult` | struct | `content : String`, `is_error`, `truncated`, `display` | `content` — основной объём tool-результата |
| `src/tools/tool.cr` | `ToolContext` | class | `work_dir`, `timeout_seconds` | маленький |
| `src/tools/registry.cr` | `Registry` | class | `@tools : Hash(String, Tool)` — 27 тулов | статично |
| `src/tools/todo_list.cr` | `TodoList < Tool` | class | `@todos : Array(TodoItem)` | ограничен пользователем |
| `src/tools/todo_list.cr` | `TodoItem` | struct | `title : String`, `status : TodoStatus` | маленький |
| `src/tools/task.cr` | `Task` (module) | — | `@@service : TaskService?` (class var) | долгоживущий синглтон |
| `src/tools/task.cr` | `AgentTaskInfo` | class | 12 полей (id, description, status, pid, command, ...) | растёт с числом фоновых задач |
| `src/tools/task.cr` | `AgentTaskOutputSnapshot` | struct | `preview : String` (до 32 КБ), пути | preview ограничен |
| `src/tools/task.cr` | `InMemoryTaskService` | class | `@tasks : Hash(String, AgentTaskInfo)`, `@outputs : Hash(String, AgentTaskOutputSnapshot)` | растёт с числом задач |
| `src/tools/cron.cr` | `Cron` (module) | — | `@@service : SessionCronService?` | долгоживущий синглтон |
| `src/tools/cron.cr` | `ParsedCronExpression` | class | `@minute/@hour/@dom/@month/@dow : Set(Int32)` (5 сетов) | маленький |
| `src/tools/cron.cr` | `CronTask` | struct | `id`, `cron`, `prompt` (до 8 КБ), `recurring`, timestamps | ограничен 50 на сессию |
| `src/tools/cron.cr` | `InMemoryCronService` | class | `@tasks : Array(CronTask)`, `@next_fires : Hash(String, Int64)` | capped 50 |
| `src/tools/skill.cr` | `Skill` (tool) | class | каталог через `SkillCatalog` | — |
| `src/tools/skill.cr` | `SkillMetadata` | struct | `type`, `arguments`, `disable_model_invocation` | маленький |
| `src/tools/skill.cr` | `SkillDefinition` | struct | `name`, `content : String` (может быть большим), `metadata`, `path`, `source` | `content` — основной объём |
| `src/tools/skill.cr` | `InMemorySkillCatalog` | class | `@skills : Hash(String, SkillDefinition)` | растёт с числом загруженных skill |
| `src/tools/agent.cr` | `Agent < Tool` | class | `@@service`/singeleton patterns, `AgentLaunchSpec` | — |
| `src/tools/agent.cr` | `AgentInput` | struct | поля ввода | transient |
| `src/tools/agent.cr` | `Profile` | struct | профиль subagent | маленький |
| `src/tools/agent.cr` | `AbortController` | class | флаг + reason | маленький |
| `src/tools/agent.cr` | `AgentRunOutcome` | struct | результат запуска | transient |
| `src/tools/agent_swarm.cr` | `AgentSwarm < Tool` | class | состояние swarm | — |
| `src/tools/agent_swarm.cr` | `SpawnSpec` / `ResumeSpec` / `SwarmRunResult` / `SwarmRunContext` | struct | ввод/вывод swarm | transient |
| `src/tools/goal.cr` | `Goal*` structs | struct | `GoalSnapshot`, `CreateGoalInput`, `GoalBudgetLimits`, ... | цель + бюджет |
| `src/tools/goal.cr` | `AgentGoalService` | class | состояние текущей цели | долгоживущий |
| `src/tools/goal.cr` | `CreateGoal`/`GetGoal`/`UpdateGoal`/`SetGoalBudget` | class (Tool) | статичные описания | — |
| `src/tools/plan_mode.cr` | `PlanData` / `PlanOption` / `PermissionModeRef` | struct | данные плана | transient |
| `src/tools/plan_mode.cr` | `AgentPlanService` | class | состояние plan mode | долгоживущий |
| `src/tools/ask_user_question.cr` | `AskUserQuestion < Tool` | class | статичное описание | — |
| `src/tools/ask_user_question.cr` | `QuestionItem` / `QuestionOption` / `QuestionRequest` | struct | ввод диалога | transient |
| `src/tools/web_search.cr` | `WebSearch < Tool` | class | описание | — |
| `src/tools/web_search.cr` | `WebSearchResult` | struct | `title`, `url`, `snippet`, ... | растёт с числом результатов |
| `src/tools/web_search.cr` | `MoonshotWebSearchProvider` / `ConfigWebSearchService` | class | клиент | долгоживущий |
| `src/tools/fetch_url.cr` | `FetchURL < Tool` | class | описание | — |
| `src/tools/fetch_url.cr` | `UrlFetchResult` | struct | `body`, `kind`, ... | `body` может быть мегабайтным |
| `src/tools/fetch_url.cr` | `LocalFetcher` / `LocalWebFetchService` | class | клиент | — |
| `src/tools/read_media.cr` | `DetectedFileType`/`ImageDimensions`/`ModelCapabilities`/`ImageRegion`/`Delivery`/`ImageProcessOutcome` | struct | метаданные медиа | transient |
| `src/tools/read_media.cr` | `LocalMediaFileSystem` / `PassThroughImageProcessor` / `ReadMediaFile` | class | клиенты/тул | — |
| `src/tools/bash.cr` | `Bash < Tool` | class | `@work_dir`, буфер процесса | `@work_dir` статично; буфер вывода процесса растёт во время вызова |
| `src/tools/read.cr` | `Read < Tool` | class | `@work_dir` | маленький |
| `src/tools/write.cr` | `Write < Tool` | class | `@work_dir` | маленький |
| `src/tools/edit.cr` | `Edit < Tool` | class | `@work_dir` | маленький |
| `src/tools/glob.cr` | `Glob < Tool` | class | `@work_dir` | маленький |
| `src/tools/grep.cr` | `Grep < Tool` | class | `@work_dir`, `RgRunResult`/`ParsedLine` (transient) | результат может быть большим |
| `src/tools/run_rg.cr` | `Result` (record) | record | stdout/stderr/exit | transient |
| `src/tools/path_access.cr` | `AccessError` | class | exception | transient |
| `src/tools/sensitive.cr` | — | module | паттерны (константы Regex) | статично |
| `src/tools/line_endings.cr` | `LineEndingStyle` (enum), `ModelTextView` (record) | — | — | transient |

### 1.5. Permission

| Файл | Тип | Вид | Поля / размеры | Поведение роста |
|---|---|---|---|---|
| `src/permission/manager.cr` | `Manager` | class | `@mode`, `@approval_callback`, `@rules : Policies::RuleSet`, `@session_approvals : Set(String)` | `@session_approvals` растёт с числом уникальных approve-session (SHA-256 ключи) |
| `src/permission/policies.cr` | `RuleSet` | class | `@rules : Array(Rule)` | конфиг-управляемый, ограничен |
| `src/permission/policies.cr` | `Rule` | struct | `pattern`, `decision`, `scope` | маленький |
| `src/permission/danger.cr` | `Pattern` | struct | regex-паттерны опасных команд | статичный массив констант |

### 1.6. Config

| Файл | Тип | Вид | Поля / размеры | Поведение роста |
|---|---|---|---|---|
| `src/config/config.cr` | `Config` | class | ~15 `property` строк/чисел (model, endpoints, api_keys, max_steps, ...) | статично, маленький |

### 1.7. Session (персистентность сессий)

| Файл | Тип | Вид | Поля / размеры | Поведение роста |
|---|---|---|---|---|
| `src/session/index.cr` | `StateMeta` | struct | `id`, `title`, `cwd`, `archived`, `created_at`, `updated_at`, `workspace_id` | маленький; persisted |
| `src/session/index.cr` | `SessionEntry` | struct | `id`, `path`, `wire_path`, `title`, `cwd`, `archived`, `created_at`, `updated_at`, `preview`, `workspace_id`, `legacy` | ~десятки–сотни на листинг |
| `src/session/index.cr` | `Index` | class | `@home : String` (без in-memory кэша — скан FS каждый вызов) | нет долгоживущего состояния |
| `src/session/store.cr` | `Store` | class | `@session_dir`, `@wire_path`, `@state_path` (строки) | маленький; данные на диске |
| `src/session/store.cr` | `SessionInfo` | struct | `id`, `path`, `preview`, `created_at` | листинг, transient |
| `src/session/lifecycle.cr` | `Lifecycle` | class | `@home`, `@index : Index` | долгоживущий, без накопления |

### 1.8. Prompt

| Файл | Тип | Вид | Поля / размеры | Поведение роста |
|---|---|---|---|---|
| `src/prompt/template.cr` | `Template` | class | шаблоны строк | статично |
| `src/prompt/system_prompt.cr` | `SystemPrompt` | class | собранный системный промпт (`String`) | **крупный** (десятки КБ), долгоживущий |
| `src/prompt/agents_md.cr` | `AgentsMd` | class | загруженное содержимое `AGENTS.md` (Hash String→String) | растёт с числом вложенных AGENTS.md |

### 1.9. TUI (интерфейс) — крупные потребители

| Файл | Тип | Вид | Поля / размеры | Поведение роста |
|---|---|---|---|---|
| `src/tui/app.cr` | `App` | class | `@messages : Array(Message)` — **крупнейший TUI-потребитель**; `@previous_lines : Array(String)`; `@queue : Array(QueuedMessage)`; `@session_entries : Array(SessionEntry)`; ~30 скаляров; ~25 callback-проц | `@messages` растёт линейно (cap `keep_recent_turns=50`); `@previous_lines` — весь отрендеренный фрейм |
| `src/tui/app.cr` | `Message` | struct | `role`, `content`, `tool_call_id`, `tool_name`, `tool_args`, `tool_result`, `tool_display`, `read_group : Array(ReadGroupEntry)?`, `summary`, `tip`, `ram_line`, ... | `content`/`tool_result` — основной объём; `read_group` — массив параллельных Read |
| `src/tui/app.cr` | `ReadGroupEntry` | struct | `tool_call_id`, `tool_args`, `tool_result`, `is_error` | маленький |
| `src/tui/app.cr` | `ApprovalRequest` | struct | `tool_name`, `args`, `danger` | transient |
| `src/tui/app.cr` | `QueuedMessage` | struct | `text`, `mode` | маленький, FIFO |
| `src/tui/editor.cr` | `Editor < Component` | class | текст буфера ввода, курсор | маленький |
| `src/tui/markdown.cr` | `Markdown` | class | кэш рендеринга markdown | может расти с числом сообщений |
| `src/tui/text.cr` | `Text < Component`, `Style`, `StyledSegment` | struct/class | стилизованные сегменты | transient per-render |
| `src/tui/select_list.cr` | `SelectList` | class | `@items : Array(String)`, курсор | маленький |
| `src/tui/spinner.cr` | `Spinner` | class | фаза анимации | крошечный |
| `src/tui/commands.cr` | `CommandInfo` | struct | `name`, `description`, ... | статичный список слэш-команд |
| `src/tui/commands.cr` | `CommandRegistry` | class | реестр команд | статично |
| `src/tui/theme.cr` | `Theme`, `Colors` | struct | палитра цветов | статично |
| `src/tui/terminal.cr` | `Terminal` | class | `@rows`, `@cols`, raw-режим | маленький |
| `src/tui/input.cr` | `Input` | class | буфер ввода; `KeyEvent`, `Key` (enum) | маленький |
| `src/tui/component.cr` | `Component` (abstract) | class | база для виджетов | — |
| `src/tui/char_width.cr` | `AnsiCode`/`SliceResult` (record) | record | width-кэш | статично |
| `src/tui/question_dialog.cr` | `QuestionDialog` | class | текущие вопросы | transient |
| `src/tui/undo_dialog.cr` | `UndoDialog`, `Choice` | class/struct | варианты undo | transient |
| `src/tui/tasks_browser.cr` | `TasksBrowser`, `Filter` (enum) | class | строки таблицы задач | transient |
| `src/tui/help_panel.cr` | `HelpPanel`, `Shortcut` | class/struct | список шорткатов | статично |

### 1.10. Точка входа (`src/h2code.cr`)

| Файл | Тип | Вид | Поля / размеры | Поведение роста |
|---|---|---|---|---|
| `src/h2code.cr` | `CLI` | class | class_property `@@ram_tracing`, `@@ram_start_rss`, `@@ram_initialised`; локальные коллекции в `run_*` | класс-уровень статичен; `pending_calls`/`pending_tool_names` — transient per-turn |
| `src/h2code.cr` | `ProviderConfigError` | class | exception | transient |
| `src/h2code.cr` | `AppQuestionService` | class | `@app : TUI::App` | долгоживущий в TUI-режиме |
| константы | `C_SUCCESS`, `C_ERROR`, ... | `Colorize::ColorRGB` | 6 RGB-констант | статично |

---

## 2. Дизайн `ProfiledStruct` / `ProfiledArray` / реестра

### 2.1. Базовые классы

Новый файл `src/profiled.cr`:

```crystal
module H2code
  module Profiled
    # Единый глобальный реестр всех profiled-объектов.
    # Ключ — идентификатор "FILE:TypeName" (см. §2.2).
    # Значение — слабая ссылка на объект (чтобы реестр не удерживал GC
    # и не самопорождал утечки). Crystal не имеет встроенных WeakRef для
    # произвольных объектов — используем обёртку-регистрацию: каждый
    # Profiled-объект при создании добавляет себя, финализатор удаляет.
    @@registry = {} of String => Array(Profiled::ProfiledRef)

    def self.register(id : String, obj)
      list = @@registry[id]? || [] of Profiled::ProfiledRef
      list << ProfiledRef.new(obj.object_id, obj)
      @@registry[id] = list
    end

    def self.registry
      @@registry
    end

    # Суммарный memsize по всему реестру, с разбивкой по id.
    # Возвращает Hash(String, Int64): id → сумма байт всех живых объектов.
    def self.memsize_all : Hash(String, Int64)
      totals = {} of String => Int64
      @@registry.each do |id, refs|
        total = 0_i64
        refs.reject! { |r| r.gc? } # вычистить мёртвые ссылки
        refs.each { |r| total += r.memsize }
        totals[id] = total
      end
      totals
    end

    # Суммарный memsize одним числом.
    def self.total_memsize : Int64
      memsize_all.values.sum
    end

    # Профильный объект: struct-подобный, держит id и реальный payload.
    struct ProfiledRef
      def initialize(@object_id : UInt64, @obj)
      end
      def memsize : Int64
        @obj.try(&.memsize.as(Int64)) || 0_i64
      end
      def gc? : Bool
        # Boehm GC: невозможно дёшево проверить liveness произвольного
        # указателя. Используем финализатор (см. ProfiledStruct) для удаления.
        false
      end
    end

    # Базовый класс для профилируемых структур-классов.
    abstract class ProfiledClass
      @profiled_id : String

      def initialize(profiled_id : String)
        @profiled_id = profiled_id
        Profiled.register(profiled_id, self)
      end

      # Подкласс переопределяет: сумма размеров своих полей-коллекций.
      abstract def memsize : Int64

      def to_s(io : IO) : Nil
        io << @profiled_id << " = " << memsize << " bytes"
      end
    end
  end
end
```

> **Примечание о WeakRef в Crystal.** Crystal `WeakRef(T)` существует, но
> работает только для ссылочных типов (class) и не для всех сборщиков.
> Альтернатива для Boehm GC — регистрация с финализатором
> (`finalize`), который удаляет запись из реестра при сборке объекта.
> В §2.3 показан вариант с `finalize`.

### 2.2. Идентификатор `FILE+StructName`

Формат идентификатора: `"<относительный путь файла>:<ИмяТипа>"`.

Примеры:
- `"src/context/memory.cr:Memory"`
- `"src/tui/app.cr:App"`
- `"src/llm/types.cr:Message"`
- `"src/tools/todo_list.cr:TodoList"`

Путь берётся **относительно корня проекта** (`/home/oleg/h2code`), чтобы
идентификатор был стабильным между машинами. Константа `PROFILED_FILE`
вычисляется один раз на файл.

### 2.3. `ProfiledStruct` (для value-типов)

Crystal `struct` — value type, не может удерживаться в реестре по ссылке
(копируется при передаче). Для структур регистрируется **не экземпляр**, а
владеющий их класс-контейнер (например, `Memory` владеет массивом
`ContextMessage`). Таким образом:

- **Классы (class)** наследуют `Profiled::ProfiledClass`, регистрируют себя.
- **Структуры (struct)** получают метод `memsize`, но не регистрируются
  сами — их размер учитывается через владеющий класс (например, `Memory#memsize`
  суммирует `@history`).
- **Массивы/хеши** — обёртка `ProfiledArray(T)` / `ProfiledHash(K,V)` поверх
  `Array(T)` / `Hash(K,V)`, переопределяющая `memsize` как сумму размеров
  элементов + базовый оверхед.

### 2.4. `ProfiledArray` / `ProfiledHash`

```crystal
class ProfiledArray(T) < Array(T)
  def memsize : Int64
    # Базовый оверхед Array (заголовок + capacity) + сумма размеров элементов.
    # Для String-элементов считаем bytesize; для Profiled — делегируем.
    total = sizeof(Pointer(Void)) * 2_i64  # грубый оверхед контейнера
    each do |el|
      case el
      when String   then total += el.bytesize.to_i64
      when Profiled then total += el.memsize
      else               total += sizeof(typeof(el)).to_i64
      end
    end
    total
  end
end
```

Аналогично `ProfiledHash(K, V)` суммирует `key.memsize + value.memsize`.

### 2.5. Метод `.memsize` — контракт

- `String` → `bytesize` (+ константный оверхед заголовка String).
- `Array(T)` / `Hash(K,V)` → сумма размеров элементов + оверхед контейнера.
- Произвольный `Profiled` объект → сумма `memsize` всех своих полей.
- Числа/bool → `sizeof`.

Точность — приблизительная (deep size без бесконечной рекурсии по
циклическим ссылкам; циклы разрываются хэш-множеством посещённых object_id).

---

## 3. Поэтапный план миграции

Миграция разбита на фазы по убыванию важности потребителей. Каждая фаза
оставляет приложение собираемым и работоспособным.

### Фаза 0 — Фундамент (1 файл)

1. Создать `src/profiled.cr` с модулем `Profiled`, `ProfiledClass`,
   `ProfiledArray(T)`, `ProfiledHash(K,V)`, реестром, `memsize_all`,
   `total_memsize`, `PROFILED_FILE`-хелпером.
2. Реализовать безопасное удаление из реестра через `finalize`:

```crystal
class ProfiledClass
  def finalize
    Profiled.unregister(@profiled_id, object_id)
  end
end
```

3. `Profiled.unregister(id, object_id)` — удаляет запись по object_id.
4. Добавить `require "./profiled"` в `src/h2code.cr`.

**Критерий готовности:** `crystal build` проходит; реестр пуст (ничего не
наследуется ещё).

### Фаза 1 — Крупнейшие потребители (контекст, история, TUI-транскрипт)

Самые большие объёмы — здесь профилирование даёт максимум пользы.

1. `Context::Memory` → наследует `ProfiledClass`, id
   `"src/context/memory.cr:Memory"`. `memsize` суммирует
   `@history` (через `ProfiledArray`).
2. `@history : Array(ContextMessage)` → `ProfiledArray(ContextMessage)`.
3. `ContextMessage#memsize` делегирует в `message.memsize`.
4. `LLM::Message#memsize` → `content.bytesize + tool_calls.sum(&.memsize)`.
5. `LLM::ToolCall#memsize`, `ToolCallFunction#memsize` (аргументы могут быть
   мегабайтными — ключевой источник).
6. `TUI::App` → `ProfiledClass`, id `"src/tui/app.cr:App"`.
7. `@messages : Array(Message)` → `ProfiledArray(TUI::Message)`.
8. `@previous_lines`, `@queue`, `@session_entries` → `ProfiledArray`.
9. `TUI::Message#memsize` → сумма content/tool_args/tool_result/read_group.
10. `Prompt::SystemPrompt` → `ProfiledClass` (системный промпт — десятки КБ).
11. `Prompt::AgentsMd` → `ProfiledClass` (`@cache : Hash(String, String)`).

**Критерий готовности:** `Profiled.memsize_all` возвращает ненулевые
значения для ключевых id; `--ram` выводит и RSS, и `total_memsize`.

### Фаза 2 — Провайдеры, loop, тул-стейт

1. `LLM::Provider` (abstract) → `ProfiledClass`; `OpenAIChatProvider`,
   `MoonshotProvider`, `ZaiProvider`, `MockProvider` — `memsize` учитывает
   накопленные в стриме буферы.
2. `Loop::Agent` → `ProfiledClass`.
3. `Loop::DedupTracker` → `ProfiledClass`, `@call_history` → `ProfiledHash`.
4. `Tools::Registry` → `ProfiledClass`, `@tools` → `ProfiledHash`.
5. `Permission::Manager` → `ProfiledClass`, `@session_approvals` → `ProfiledSet`.
6. `Tools::TodoList` → `ProfiledClass`, `@todos` → `ProfiledArray`.
7. `Tools::InMemoryTaskService` → `ProfiledClass`, `@tasks`/`@outputs` →
   `ProfiledHash`.
8. `Tools::InMemoryCronService` → `ProfiledClass`, `@tasks` → `ProfiledArray`.
9. `Tools::InMemorySkillCatalog` → `ProfiledClass`, `@skills` → `ProfiledHash`.

**Критерий готовности:** все долгоживущие сервисы видны в реестре.

### Фаза 3 — Session, Config, остальные структуры

1. `Session::Lifecycle`, `Session::Index` → `ProfiledClass`.
2. `Config::Config` → `ProfiledClass`.
3. `Session::Store` → `ProfiledClass`.
4. Все оставшиеся structs (`StateMeta`, `SessionEntry`, `Usage`, `ToolResult`,
   ...) получают `def memsize` (без саморегистрации).

### Фаза 4 — Интеграция в UI / CLI

1. Команда `/mem` (slash command) в TUI: выводит топ-N потребителей из
   `Profiled.memsize_all`, отсортированных по убыванию.
2. В `--ram`-режим (`CLI.ram_line`) добавить колонку `heap=` =
   `Profiled.total_memsize` рядом с RSS.
3. При `H2CODE_DEBUG` в конце turn выводить дельту `total_memsize` (до/после).

### Фаза 5 — Тесты и спецификации

1. `spec/profiled/profiled_spec.cr`: регистрация/unregister, `memsize` для
   String/Array/Hash, корректность суммы, отсутствие двойного учёта при
   циклах.
2. `spec/profiled/registry_spec.cr`: `memsize_all` возвращает ожидаемые id.
3. Smoke-тест: запуск mock-сессии, проверка что `total_memsize` растёт при
   добавлении сообщений и падает после `Context::Memory#clear`.

---

## 4. Риски и решения

| Риск | Решение |
|---|---|
| Crystal `struct` — value type, нельзя держать в реестре по ссылке | Регистрируем только владеющие `class`; `struct.memsize` вызывается из владельца |
| Boehm GC не поддерживает дешёвый `WeakRef` для liveness-проверки | Используем `finalize` для удаления из реестра; периодически `compact!` реестр |
| Циклические ссылки (Agent ↔ Memory ↔ Registry) дадут бесконечную рекурсию в `memsize` | В `memsize` передаём `visited : Set(UInt64)` object_id; повторно посещённые узлы считаем как 0 |
| `finalize` не гарантирует вызова (GC может не собирать) | Реестр периодически `compact!`-ится при вызове `memsize_all`; нерастущие id видны как «зомби» и чистятся |
| Оверхед `ProfiledArray` на каждый push | `memsize` считается лениво (только при вызове), push/pop не несут доп. стоимости |
| Большие `JSON::Any` параметры тулов (descriptions) считаются многократно | Кэшировать `memsize` на `ToolDefinition` (он иммутабелен после регистрации) |

---

## 5. Итоговый API (шпаргалка)

```crystal
# Регистрация (автоматически в initialize ProfiledClass)
Profiled.register("src/context/memory.cr:Memory", self)

# Снять со счёта (автоматически в finalize)
Profiled.unregister("src/context/memory.cr:Memory", object_id)

# Размер одного объекта
memory.memsize            # => Int64

# Полная картина: id → bytes
Profiled.memsize_all      # => {"src/context/memory.cr:Memory" => 1_234_567, ...}

# Одним числом
Profiled.total_memsize    # => Int64

# В TUI: /mem  → топ-N потребителей
```
