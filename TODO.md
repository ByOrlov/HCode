# hcode — TODO (сравнение с kimi-code TS)

Состояние на 2026-07-18. Источник: прямое сравнение `src/` (Crystal) с `kimi-code/` (TS).
Билд собирается, спеки зелёные. Ядро агента ≈80% готово.

## 1. Критическое (ломает базовый UX)

- [x] **Очередь сообщений + steer** — ГОТОВО
  - `QueuedMessage` struct (text + mode), `@queue : Array(QueuedMessage)`
  - Drain-loop через `TurnEnd` event: каждое завершение turn-а шарит следующее
    сообщение, рекурсивно пока очередь не опустеет (раньше шарился только 1)
  - `Agent#steer(text)` — инжект в текущий turn (mirrors `session.steer`)
  - `EventType::TurnEnd` + `Event.turn_end(cancelled)` эмитится всегда
    (через `ensure`), флаг `cancelled` отличает cancel от нормального конца
  - 3-флаговый gate как в TS: `@agent_busy || @is_compacting || @defer_user_messages`
  - Ctrl+S: compacting/deferred → enqueue, idle → send, busy → steer
  - Persistence: `on_persist_queued` колбэк пишет `turn.prompt` / `turn.steer`
    в JSONL (привязан в `hcode.cr`) — очередь переживает resume
  - Cleanup при cancel: очередь чистится в обработчике `turn_end` (`is_error`)
  - `render_queue_pane` компонент: показывает размер, превью, контекстный hint
  - Команда `/queue` (просмотр) и `/queue clear` (очистка)
  - `@dispatch_pending` guard от race между shift и start_turn
  - Тесты: TurnEnd эмитится 1 раз (нормально + cancel), `Agent#steer` инжектит

- [x] **Provider-свитчер** — РАБОТАЕТ (`hcode.cr:523-539`):
  `on_provider_change` привязан → `build_named_provider` → `agent.swap_provider!`
  → `config.save`. То же для `on_model_change`. Список рендерится через SelectList.

## 2. Отсутствующие подсистемы (нет директорий)

- [ ] `src/auth/` — OAuth/device-code flow (сейчас только чтение готовых токенов)
- [ ] `src/hooks/` — PreToolUse/PostToolUse/UserPromptSubmit/Stop hooks
- [ ] `src/notify/` — status tracker + sound + webhook + OSC-9 (net-new фича)

## 3. TUI панели/диалоги (есть в TS, нет в Crystal)

В TS ~30 (`tui/components/dialogs/` + `messages/`), в Crystal только `help_panel`.
- [x] `plan_box` — РАБОТАЕТ: `render_plan_box` (бокс `┌── plan: ... ──┐`)
      + детект ExitPlanMode результата (approved/auto_approved/rejected) +
      путь файла плана + markdown body через `@markdown.render`
- [ ] `goal_panel`
- [ ] `usage_panel` (tokens / context / quotas) — есть команда `/usage`,
      нет отдельной панели
- [x] `tasks_browser` + `task_output_viewer` — РАБОТАЕТ: полный порт
      `TasksBrowser` (3 панели, рамки, scroll, filter, stop-confirm, vim)
      + `/tasks` команда + привязка к `InMemoryTaskService`
- [x] `todo_panel` (тулза есть, UI нет) — РЕАБОТАЕТ: `render_todo_panel` +
      `on_fetch_todos`/`on_clear_todos` колбэки + `/todos` команда
- [ ] `cron_message` рендер
- [ ] `skill_activation` рендер
- [ ] `agent_group` / `agent_swarm_progress` / `background_agent_status`
- [ ] `mcp_status_panel`, `plugins_status_panel`
- [ ] `compaction` диалог
- [x] `undo_selector` (preview turns) — РАБОТАЕТ: `UndoDialog` с choices из
      `agent.context.history`, навигация ↑↓, выбор Enter, cancel Esc,
      `/undo` без аргумента открывает селектор
- [x] `question_dialog` (reverse-rpc для AskUserQuestion) — полный порт
      TS `QuestionDialogComponent`: табы, single/multi-select, Other free-text,
      auto-advance, submit review, `AppQuestionService` биндит тулзу к диалогу
- [x] `session_picker` как интерактивный SelectList — `/sessions` и `/restore`
- [x] `thinking` / `step_summary` рендер — уже работает (`render_thinking_block`,
      `render_step_summary`, live streaming preview, ctrl+o expand)
- [x] SelectList-диалоги permission / effort / theme (model уже был);
      experiments — будущая работа (нет флаг-системы)

## 4. Слэш-команды (TS-only, отсутствуют в Crystal)

- [ ] `/goal` — autonomous goals (status/pause/resume/cancel/replace/next)
- [ ] `/swarm` — swarm mode
- [x] `/tasks` (`/task`) — РАБОТАЕТ: открывает `TasksBrowser`, привязан к
      `InMemoryTaskService` (list/stop/open output)
- [ ] `/reload-tui` — reload tui.toml (`/reload` уже работает)
- [ ] `/btw` — forked side-agent question
- [x] `/init` — шлёт init-промпт как turn (AGENTS.md генерация через агент)
- [x] `/mcp` — заглушка: нет MCP-клиента, явное сообщение
- [x] `/plugins` — заглушка: нет plugin runtime, явное сообщение
- [x] `/experiments` — env-driven (HCODE_EXPERIMENTAL_*) flags, master switch
- [x] `/login` — инструкция по ручной настройке api_key/OAuth
- [x] `/logout` — очистка api_key в config через `on_logout`
- [x] `/export-debug-zip` — tar.gz: manifest + wire.jsonl + state.json + hcode.log
- [x] `/plan` — toggle через `on_plan_mode` колбэк
- [x] `/effort` (`/thinking`) — SelectList selector через `on_get_effort`/`on_set_effort`
- [x] `/permission` — SelectList selector manual/auto/yolo
- [x] `/editor` — открытие `$EDITOR`
- [x] `/usage` — tokens + context window
- [x] `/version` — version info (Hcode::VERSION + build_date)
- [x] `/copy` — copy last assistant message (pbcopy/wl-copy/xclip/xsel)
- [x] `/reload` — колбэк `on_reload`
- [x] `/settings` — show provider/model/permission/theme/effort/home/work
- [x] `/feedback` — лог в `~/.hcode/feedback.log` (или через `on_feedback` колбэк)
- [x] `/web` — session URL для Web UI

## 5. Рендеринг / полировка

- [ ] Syntax highlighting (TS/JS/Python/bash/go/rust/json) — в TS через `cli-highlight`
- [ ] Word-level intra-line diff highlighting (сейчас line-level +/-)
- [x] Slash autocomplete (имя + описание + arg hints, сейчас простой список) —
      `usage` поле в CommandInfo, рендерится с описанием и `<args>` хинтом
- [ ] Paste markers `[paste #N +48 lines]` (сейчас raw paste в буфер)
- [x] Footer badges: git / goal / tips rotation (сейчас model+context%) —
      git branch уже был; добавлены rotating tips (5 шт, цикл по 5с)
- [ ] Light theme + кастомные темы через `tui.toml`
- [ ] Inline images (Kitty graphics protocol)
- [ ] External editor (Ctrl+G — open `$EDITOR`)

## 6. Поддерживающая инфраструктура

- [x] **Прокси**: HTTPS-туннель через `CONNECT` реализован в `make_client`
      (HTTP-прокси для HTTPS-endpoints), `NO_PROXY` и loopback bypass. HTTP
      endpoints используют absolute-URI через прокси-хост. OAuth refresh
      без прокси (см. комментарий в moonshot_provider.cr)
- [x] **Сессии**: `/sessions` и `/restore` открывают интерактивный `SelectList`
      с навигацией и resume/restore, `handle_session_key` обрабатывает выбор
- [x] **Danger detection** — РАБОТАЕТ: `Danger.detect` → `approval_callback`
      → `ApprovalRequest.danger` → `! DANGER:` в approval panel
- [x] **`/compact`** — привязан к `trigger_compaction_tui` через `on_compact`,
      блокирует при busy, ставит `@is_compacting`, сбрасывается при info-event
      "compacted"
- [ ] `Context::Compaction` — LLM-based summarization как отдельный модуль
      (сейчас встроен в `Agent#trigger_compaction`)
- [ ] `Loop::Retry` — rate-limit / error retry (429, 500s) — частично в
      `execute_step` (3 retries с backoff), но без отдельных классов
- [ ] `Config::Paths` — XDG-aware path resolution
- [ ] `Config::ProviderConfig` — отдельный конфиг per-provider
- [x] `Permission::Policies` — полноценный: Rule/RuleSet/glob_match/parse_pattern,
      4 scope (User/Project/SessionRuntime/TurnOverride), integrated в Manager
      (deny/allow/ask evaluated до approval prompt)
- [ ] `Prompt::Workspace` — cwd file tree (2 levels) в system prompt

## Приоритет починки

1. Очередь сообщений + steer (§1) — ломает интерактив
2. Provider-свитчер довести (§1)
3. `/compact` реальный + компакция UI
4. Danger labels в approval
5. `/sessions` как SelectList
6. Прокси в HTTP::Client
7. Дальше — панели/команды по скоупу фаз
