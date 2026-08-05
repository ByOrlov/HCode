# Web Interface — план реализации для hcode

> **Статус: исследование.** Архитектурный анализ завершён, реализация не начата.

## Контекст

Цель — добавить к hcode веб-интерфейс по образцу Kimi Web: браузерный SPA,
который общается с локальным сервером по REST + WebSocket и получает
стриминг ответов агента в реальном времени.

В hcode ядро (`Loop::Agent`) уже отвязано от TUI через event-колбэк, что
делает задачу реализуемой без переписывания движка. Этот план фиксирует
разрыв между текущей архитектурой и тем, что нужно для web, и описывает
путь минимальными изменениями.

## Что уже есть (и почему это сложно)

### TUI — одна активная сессия на процесс

В TUI физически существует один `Loop::Agent` и один `Context::Memory`
(`src/hcode.cr:372`). «Новая сессия» и «resume» — это не открытие вкладки,
а переключение того самого единственного агента на другой session-store:

```crystal
# on_new_session (src/hcode.cr:863)
agent.context.clear
store.session_dir = new_store.session_dir   # перенаправили указатель
store.wire_path   = new_store.wire_path

# on_resume_session (src/hcode.cr:886)
agent.context.clear
resumed.replay(agent.context)               # перечитали историю в ту же Memory
store.session_dir = resumed.session_dir
```

Сессии хранятся на диске (`~/.hcode/sessions/<id>/wire.jsonl`), а в
оперативке живёт ровно одна. Переключение = очистить `Memory`, поменять
пути у `store`, перечитать `wire.jsonl` через `replay`. Никаких
параллельных вкладок.

### Сервисные синглтоны привязаны к процессу

Четыре инструмента достают свой сервис через class-переменные, а не через
инстанс агента:

```crystal
Tools::Goal.service     = goal_service        # src/hcode.cr:392
Tools::PlanMode.plan_service = plan_service   # src/hcode.cr:760
Tools::Task.service     = task_service        # src/hcode.cr:389
Tools::SwarmMode.service = ...                # src/hcode.cr:762
```

Инструменты обращаются к ним как `Tools::Goal.service.get_goal`
(`src/loop/agent.cr:485`). В одном процессе две сессии будут делить
один GoalService / PlanService / TaskService — один агент увидит цель,
план и задачи другого. Это сломается при in-process мультисессии.

### Event-стрим уже разделён на volatile / durable

`Loop::Event` / `EventType` (`src/loop/events.cr`) естественным образом
делится на два класса событий:

| Volatile (стриминг, можно потерять) | Durable (результаты, нужны для replay) |
|---|---|
| `TextDelta` | `AssistantText` |
| `ThinkingDelta` | `ToolCallStart` |
| `ToolCallDelta` | `ToolResult` |
| `SubagentProgress` | `StepBegin` / `StepEnd` |
| | `TurnEnd` |
| | `CompactionStarted/Completed/Cancelled` |

TUI и headless-mode — два равноправных потребителя одного и того же
event-стрима:

- TUI: `app.on_event(event)` (`src/tui/app.cr:678`)
- Headless: блок в `run_headless` печатает события в stdout
  (`src/hcode.cr:591-653`)

Поток стриминга от LLM уже разложен на дельты: провайдер
(`LLM::Provider#chat`) yields `TextPart` / `ThinkPart` / `ToolCallPart`,
агент оборачивает их в `Event` и делает `Fiber.yield`, чтобы UI успел
отрисовать (`src/loop/agent.cr:328-332`).

### Session::Store уже append-only journal

`Session::Store` (`src/session/store.cr`) пишет `wire.jsonl` — это уже
журнал событий. Сейчас он пишет «толстые» записи (`assistant.text`,
`tool.call`, `tool.result`), но не назначает им `seq`. Для replay-по-курсору
надо добавить seq в записи (или завести отдельный event-journal рядом).
Минорное изменение.

## Как устроен стриминг в Kimi Web (эталон)

### Серверная сторона

`packages/kap-server/.../sessionEventBroadcaster.ts`:

1. Движок кидает domain-события на per-agent `IEventBus`.
2. `SessionEventBroadcaster` подписывается, для каждого события решает
   durable или volatile:

   ```
   VOLATILE_SIGNAL_TYPES = [
     'assistant.delta', 'thinking.delta', 'tool.call.delta',
     'tool.progress', 'shell.output', 'agent.status.updated',
   ]
   ```

3. **Durable**: назначает монотонный `seq`, пишет в `SessionEventJournal`
   (на диск), хранит в in-memory tail, fan-out всем подписчикам.
4. **Volatile**: fan-out с тем же `seq` + `volatile: true`, не
   журналируется, не реплеится.
5. Всё сериализуется через per-session очередь
   (`state.queue = state.queue.then(...)`) — гарантия порядка.

### Клиентская сторона

`apps/kimi-web/.../ws.ts`:

1. WebSocket с handshake `server_hello` / `client_hello`.
2. Subscribe на session с курсором `{seq, epoch}`.
3. Каждый durable-фрейм двигает курсор; volatile — нет.
4. На реконнекте — повторный subscribe с последним курсором → сервер
   досылает пропущенные durable-события из tail/journal; если gap >
   buffer → `resync_required` → клиент тянет полный snapshot по REST и
   перестраивается.

То есть **стриминг = volatile-дельты в реальном времени +
durable-водяной знак для надёжного реконнекта**. Дельты (текст, thinking)
можно потерять при обрыве — следующий durable `AssistantText` всё равно
даст финальный текст.

### Мультисессия в kap-server

Сервер держит **дерево скоупов** (App → Session → Agent), и каждая сессия
— это отдельный `SessionScopeHandle` со своими агентами, контекстом,
сервисами:

```
POST   /sessions                ← создать новую (живёт параллельно)
GET    /sessions                ← список всех активных
GET    /sessions/{id}/children  ← форки
```

Каждый WS-подписчик может фильтровать события по `agentId` — несколько
клиентов смотрят разные сессии одновременно, все события идут через один
`SessionEventBroadcaster` с per-session очередью. Это один процесс с N
сессиями внутри, благодаря DI-контейнеру VSCode-style, где каждый сервис
живёт в своём Scope.

## Архитектурный разрыв: TUI vs сервер

| Компонент | hcode сейчас | Kimi Web |
|---|---|---|
| HTTP/WS сервер | нет, один процесс = один агент | `kap-server` — отдельный daemon |
| Event-транспорт | синхронный колбэк в том же процессе | JSON-конверты по WS с `{seq, epoch}` watermark |
| Durable/volatile классификация | неявная (по типу Event) | явная: journal + replay для durable, fire-and-forget для volatile |
| Мультисессия | один агент на процесс | сервер держит N сессий, fan-out по подпискам |
| Approval/question round-trip | блокирует fiber, рисует TUI-диалог | REST/WS round-trip: «паркуем» запрос, клиент отвечает |
| Web-фронтенд | — | Vue 3 SPA |

## План реализации

### Фаза 1 — Process-per-session сервер (MVP)

**Цель:** рабочий web без изменений в ядре hcode.

Один `hcode --serve` как супервизор, который на `POST /sessions` запускает
child-процесс `hcode -s <new-id> --listen-unix <socket>` и пробрасывает
WS. Получаешь мультисессию из коробки, веб-клиент работает, а ядро не
трогаешь вообще.

Что нужно сделать:

1. **`run_server` режим** — новый файл `src/server/`, флаг `--serve` в
   `CLI.run`. HTTP+WS сервер на `HTTP::Server` + `HTTP::WebSocketHandler`
   (stdlib Crystal, новых зависимостей нет).

2. **Child-процесс на сессию:**
   - `POST /sessions` → `Process.new("hcode", ["-s", id, "--listen-unix",
     socket_path])`, supervisior держит `{session_id → Process}` map.
   - `POST /sessions/:id/prompt` → пишет в unix-socket child'а.
   - WS `/api/v1/ws` → proxy событий от child'а к браузеру.

3. **Event → wire-конверты.** Адаптер поверх `on_event`:
   - durable → назначить `seq`, дописать в `wire.jsonl` (он уже append-only
     journal!), отдать в WS-fanout;
   - volatile → отдать в WS с `volatile: true`, не журналировать.

   VOLATILE set (по `EventType`):
   ```
   TextDelta, ThinkingDelta, ToolCallDelta, SubagentProgress
   ```

4. **Approval / AskUserQuestion как reverse-RPC.** Теперь тот же механизм
   блокировки fiber, но sink — не TUI-диалог, а:
   - положить pending-запрос в Map,
   - отправить событие `approval.requested` по WS,
   - fiber ждёт на `Channel(Response).receive`,
   - REST `POST /approvals/:id/respond` кладёт ответ в канал → fiber
     просыпается → агент продолжает.

   hcode уже на Crystal-фиберах, `Channel(T).receive` блокирует корректно.
   Существующие интерфейсы (`approval_callback`,
   `AskUserQuestion.service`) не меняются — меняется только реализация.

5. **REST-эндпоинты:**
   ```
   POST   /api/v1/sessions              создать (spawn child)
   GET    /api/v1/sessions              список
   GET    /api/v1/sessions/:id          состояние / snapshot
   POST   /api/v1/sessions/:id/prompt   запустить turn
   POST   /api/v1/sessions/:id/abort    cancel
   POST   /api/v1/approvals/:id/respond ответ на permission-запрос
   POST   /api/v1/questions/:id/respond ответ на AskUserQuestion
   WS     /api/v1/ws                     event-стрим
   ```

6. **seq-watermark для replay.** Добавить `seq` в записи `wire.jsonl`
   (или отдельный event-journal рядом). На WS-reconnect — resubscribe с
   курсором, сервер досылает пропущенные durable-события.

**Плюсы:** ноль изменений в ядре, идеальная изоляция сессий, быстрый MVP.

**Минусы:** RAM-оверхед — один процесс hcode на сессию (~десятки MB RSS
каждый, Boehm GC). При 10 параллельных юзерах это 10 × RSS.

### Фаза 2 — In-process мультисессия

**Цель:** убрать process-per-session оверхед, держать N сессий в одном
процессе.

**Предварительное условие:** избавиться от четырёх class-property
синглтонов. Варианты (по возрастанию сложности):

#### Вариант 2a — Service registry per-agent

Перенести синглтоны на инстанс агента:

```crystal
class Loop::Agent
  property goal_service : Tools::GoalService?
  property plan_service : Tools::PlanService?
  property task_service : Tools::TaskService?
  property swarm_service : Tools::SwarmModeService?
end
```

Инструменты достают сервис через контекст вызова, а не через class-var.
Меньше изоляции, чем process-per-session, но все сервисы в одном процессе.

Проблема: инструменты (`Tools::Goal`, `Tools::PlanMode`, ...) —
stateless-объекты в реестре, у них нет ссылки на агент. Нужно либо
прокидывать agent-context в `Tool#call`, либо делать per-agent реестр
инструментов.

#### Вариант 2b — DI-контейнер

Полноценный VSCode-style `createDecorator` / `InstantiationService`, где
каждый сервис регается в Scope (Session/Agent). Это то, что у kimi-code
сделано в `packages/agent-core/src/services/`. Самый большой кусок работы
— фактически переписать слой сервисов. В Crystal реализуемо, но
не оправдано для MVP.

### Фаза 3 — Web-фронтенд

Отдельный SPA (Vue/React/Svelte — что ближе), который:
- REST для команд, WS для событий;
- держит cursor `{seq, epoch}`, на реконнекте resubscribe;
- рендерит transcript из durable-событий + live-дельты.

Можно писать с нуля или подсмотреть структуру у `apps/kimi-web` (там Vue 3
+ composables, без роутера/pinia).

## Что НЕ нужно менять

- `Loop::Agent` и весь `src/loop/` — уже правильная граница, работает
  одинаково для TUI, headless и server.
- `LLM::Provider` и стриминг дельт — уже разложен на `TextPart` /
  `ThinkPart` / `ToolCallPart`, `Fiber.yield` для отрисовки.
- `Tools::Registry`, `Permission::Manager`, `Context::Memory` — все
  per-instance, не глобальные.
- `Session::Store` / `wire.jsonl` — уже append-only journal, надо только
  добавить `seq`.

## Рекомендация

Стартовать с **Фазы 1** (process-per-session). Это даёт рабочий web-MVP
без касания ядра. Когда упрёшься в RAM — переходить на **Фазу 2a**
(per-agent сервисы). **Фазу 2b** (DI-контейнер) отложить до тех пор, пока
не станет ясно, что 2a недостаточно.
