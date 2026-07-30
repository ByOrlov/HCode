# План: реализация subagent runtime для Crystal-версии

Цель: подключить `Tools::Agent.runner` и `Tools::AgentSwarm.runner` реальными
реализациями, аналогичными JS-движку, чтобы тулы `Agent`/`AgentSwarm` запускали
дочерние агенты (foreground + background + resume + swarm) вместо ошибки
"no subagent runtime is registered".

## Контекст (что уже есть)

- `src/tools/agent.cr` — тул `Agent`, контракт `AgentRunner#launch`, 4 ветки
  результата. Готов, `@@runner = nil`.
- `src/tools/agent_swarm.cr` — тул `AgentSwarm`, контракт `SwarmRunner#call`.
  Готов, `@@runner = nil`.
- `src/loop/agent.cr` — `Loop::Agent`: `run_turn`, `ToolBatch`, compaction,
  abort, provider swap. Полноценный движок.
- `src/context/memory.cr` — `Context::Memory`: история, injection, token count.
- `src/tools/task.cr` — `TaskService` + `InMemoryTaskService`, тулы
  TaskList/TaskOutput/TaskStop, `render_notification_xml`.
- `src/loop/abort.cr` — `AbortController`, `UserCancellationError`.
- `src/loop/tool_batch.cr` — параллельный запуск тулов в fiber'ах.

## Что нужно добавить

### 1. `src/loop/subagent_registry.cr` — реестр дочерних агентов

Аналог `IAgentLifecycleService` + `subagentMetadata` из JS. Хранит
`agent_id → SubagentEntry`.

```crystal
class SubagentEntry
  getter agent : Loop::Agent
  getter context : Context::Memory
  getter profile_name : String
  getter parent_agent_id : String
  property? running : Bool = false
  property swarm_item : String?  # для swarm resume lookup
end

class SubagentRegistry
  @entries = {} of String => SubagentEntry
  @counter = 0

  def create(parent_agent_id, profile_name, provider, tools, permission, system_prompt, work_dir, swarm_item = nil) : SubagentEntry
    # генерит agent_id, создаёт дочерний Loop::Agent + Context::Memory
    # с профилем (subset of tools по profile.tools строке)
  end

  def get(agent_id) : SubagentEntry?
  def running?(agent_id) : Bool
  def owned_by?(agent_id, parent_agent_id) : Bool
  def swarm_item(agent_id) : String?
end
```

Регистр global (один на процесс) — достаточно для single-session CLI/TUI.

### 2. `src/loop/profile_registry.cr` — построитель Tools::Registry по профилю

Парсит строку `"Read, Write, Edit, Grep, ..."` из `Tools::Agent::PROFILES` и
собирает дочерний `Tools::Registry` с нужным подмножеством тулов + те же
work_dir-sensitive тулы (Bash, Read, Write, Edit, Glob, Grep).

```crystal
module Hcode::Loop
  class ProfileRegistry
    def self.build(profile_name : String, work_dir : String) : Tools::Registry
      # найти Profile по имени в Tools::Agent::PROFILES
      # распарсить tools-строку
      # создать инстансы тулов, зарегистрировать только разрешённые
    end
  end
end
```

Профиль `coder` → полный набор file-editing тулов + Agent/AgentSwarm (для
вложенных субагентов). Профиль `explore`/`plan` → read-only.

### 3. `src/loop/subagent_runner.cr` — реализация `Tools::AgentRunner`

Главный класс. Привязывается к главному `Loop::Agent` (родителю), его
`TaskService`, `system_prompt`, `work_dir`, `permission_mode`.

```crystal
class SubagentAgentRunner < Tools::AgentRunner
  def initialize(@parent_agent : Loop::Agent,
                 @registry : SubagentRegistry,
                 @task_service : Tools::TaskService,
                 @system_prompt : String,
                 @work_dir : String,
                 @permission_mode : Permission::Mode)

  def launch(spec : AgentLaunchSpec, signal : AbortController?) : AgentRunOutcome
    if resume_id = spec[:resume_agent_id]
      launch_resume(resume_id, spec, signal)
    else
      launch_spawn(spec, signal)
    end
  end
```

#### Foreground spawn
1. `@registry.create(...)` → дочерний `Loop::Agent` + изолированный `Context::Memory`
2. `child_agent.run_turn(prompt, system_prompt_for_profile)` — синхронно в текущем fiber
3. Извлечь `summary` = последний assistant-text из `child.context`
4. Вернуть `AgentRunOutcome.new(status: Completed, summary: summary)`
5. При `UserCancellationError` → `Aborted`; при др. ошибке → `Failed`

#### Background spawn
1. Создать entry, зарегистрировать task `agent-N` в `@task_service`
2. `spawn` fiber: run_turn, при завершении:
   - обновить task status (Completed/Failed/Killed)
   - записать output snapshot (summary)
   - inject `<notification>` XML в `@parent_agent.context`
3. Вернуть `AgentRunOutcome.new(status: Detached, task_id: task_id)`

#### Resume
1. `@registry.get(agent_id)` — проверить exists, owned, not running
2. Повторно использовать существующий `Loop::Agent` + его `Context::Memory`
3. run_turn на существующем контексте

#### Timeout
`DEFAULT_SUBAGENT_TIMEOUT_MS = 7_200_000` (2 часа), env `HCODE_SUBAGENT_TIMEOUT_MS`.
Для background — через `select` с timeout в fiber; для foreground —
`Loop.execute_tool` уже умеет abort-grace (можно переиспользовать).

### 4. `src/loop/swarm_runner.cr` — реализация `Tools::SwarmRunner`

Привязывается к тому же `SubagentRegistry`. Тул `AgentSwarm` уже спавнит
fiber'ы сам (`run_specs` в `agent_swarm.cr:254`), вызывая `runner.call(spec, ctx)`
для каждого. Поэтому `SwarmRunner#call` — синхронный запуск одного субагента:

```crystal
class SubagentSwarmRunner
  include Tools::SwarmRunner

  def call(spec, ctx) : SwarmRunResult
    # spawn или resume дочернего агента через @registry
    # run_turn синхронно
    # извлечь summary
    # SwarmRunResult(completed/failed, agent_id, result/error)
  end
```

Swarm всегда foreground (тул сам управляет параллельностью через fiber'ы).

### 5. Конфиг: `HCODE_SUBAGENT_TIMEOUT_MS`

В `SubagentAgentRunner`/`SwarmRunner`:
```crystal
def timeout_ms : Int32?
  env = ENV["HCODE_SUBAGENT_TIMEOUT_MS"]?
  return nil unless env
  v = env.to_i?
  (v && v >= 1) ? v : nil
end
```

### 6. Подключение в `src/hcode.cr`

В `run_interactive` и `run_headless`, после создания главного `Loop::Agent`:

```crystal
registry = Loop::SubagentRegistry.new
agent_runner = Loop::SubagentAgentRunner.new(
  parent_agent: agent,
  registry: registry,
  task_service: task_service,
  system_prompt: system_prompt,
  work_dir: work_dir,
  permission_mode: Permission::Mode.parse(config.permission_mode),
)
swarm_runner = Loop::SubagentSwarmRunner.new(
  registry: registry,
  system_prompt: system_prompt,
  work_dir: work_dir,
  permission_mode: Permission::Mode.parse(config.permission_mode),
)
Tools::Agent.runner = agent_runner
Tools::AgentSwarm.runner = swarm_runner
Tools::Agent.background_enabled = true  # TaskList/TaskOutput/TaskStop включены
```

`run_headless` тоже нужно (для `-p` режима).

## Порядок реализации

1. **`SubagentRegistry`** — реестр, create/get/running?/owned_by?
2. **`ProfileRegistry.build`** — построение Tools::Registry по профилю
3. **`SubagentAgentRunner`** — foreground spawn + resume (без background)
4. **Спеки**: foreground spawn completed/failed, resume, abort
5. **Background**: task registration + notification injection
6. **Спеки**: background detach, notification XML, timeout
7. **`SubagentSwarmRunner`** — call, spawn/resume
8. **Спеки**: swarm 2 спека, 1 failed, resume
9. **Подключение** в `hcode.cr` (run_interactive + run_headless)
10. **Smoke-тест**: реальный запуск через mock provider

## Расхождения с JS (намеренные упрощения)

- **DI/Scope**: Crystal не имеет DI-контейнера; registry — простой класс с
  global state (один на процесс). Достаточно для single-session CLI.
- **`mirrorAgentRun` / event bus**: опускаем (нет UI-транскрипта с nested
  записями; нет external hooks; нет telemetry). Subagent работает тихо, результат
  возвращается через `AgentRunOutcome`.
- **`distillSummary`** (retry при коротком ответе): опускаем в первом проходе.
  Runner возвращает полный финальный assistant-text. Можно добавить позже.
- **Persistance across restarts**: subagent-реестр in-memory, не переживает
  перезапуск процесса. JS-версия персистит через session metadata. Отложим.
- **Rate-limit retry для swarm** (`AgentRunBatch`): опускаем; swarm в Crystal
  использует простой `spawn` per spec (как уже сделано в `agent_swarm.cr`).
- **`autoBackgroundOnTimeout`**: опускаем; foreground-субагент по таймауту
  просто failed с resume_hint (как уже реализовано в тулу `Agent`).

## Что НЕ меняется

- Контракт тулов `Agent`/`AgentSwarm` (name, description, parameters, execute,
  формат вывода) — полностью сохраняется.
- `TaskService` абстракция и `InMemoryTaskService` — только дополняем
  использованием, не меняем интерфейс.
- `Loop::Agent`, `Context::Memory`, `ToolBatch` — используем как есть.
