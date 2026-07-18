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
- [ ] `plan_box` (plan mode)
- [ ] `goal_panel`
- [ ] `usage_panel` (tokens / context / quotas)
- [ ] `tasks_browser` + `task_output_viewer`
- [ ] `todo_panel` (тулза есть, UI нет)
- [ ] `cron_message` рендер
- [ ] `skill_activation` рендер
- [ ] `agent_group` / `agent_swarm_progress` / `background_agent_status`
- [ ] `mcp_status_panel`, `plugins_status_panel`
- [ ] `compaction` диалог
- [ ] `undo_selector` (preview turns)
- [ ] `question_dialog` (reverse-rpc для AskUserQuestion)
- [ ] `session_picker` как интерактивный SelectList
- [ ] `thinking` / `step_summary` рендер
- [ ] SelectList-диалоги: model / permission / effort / theme / experiments

## 4. Слэш-команды (TS-only, отсутствуют в Crystal)

Из ~38 команд TS не реализованы:
- [ ] `/plan` — plan mode toggle
- [ ] `/goal` — autonomous goals (status/pause/resume/cancel/replace/next)
- [ ] `/swarm` — swarm mode
- [ ] `/tasks` (`/task`) — background tasks browser
- [ ] `/init` — сгенерировать AGENTS.md
- [ ] `/editor` — выбор $EDITOR для Ctrl-G
- [ ] `/effort` (`/thinking`) — selector low/medium/high
- [ ] `/usage` — tokens + context window + plan quotas
- [ ] `/permission` — selector manual/auto/yolo
- [ ] `/settings` (`/config`) — TUI settings
- [ ] `/mcp` — MCP server status
- [ ] `/plugins` — plugin management
- [ ] `/experiments` (`/experimental`) — feature flags
- [ ] `/reload`, `/reload-tui` — reload config / tui.toml
- [ ] `/btw` — forked side-agent question
- [ ] `/feedback` — send feedback
- [ ] `/login`, `/logout` — auth
- [ ] `/web` — открыть в Web UI
- [ ] `/version` — version info
- [ ] `/copy` — copy last message
- [ ] `/export-debug-zip` — debug ZIP

## 5. Рендеринг / полировка

- [ ] Syntax highlighting (TS/JS/Python/bash/go/rust/json) — в TS через `cli-highlight`
- [ ] Word-level intra-line diff highlighting (сейчас line-level +/-)
- [ ] Slash autocomplete (имя + описание + arg hints, сейчас простой список)
- [ ] Paste markers `[paste #N +48 lines]` (сейчас raw paste в буфер)
- [ ] Footer badges: git / goal / tips rotation (сейчас model+context%)
- [ ] Light theme + кастомные темы через `tui.toml`
- [ ] Inline images (Kitty graphics protocol)
- [ ] External editor (Ctrl+G — open `$EDITOR`)

## 6. Поддерживающая инфраструктура

- [ ] **Прокси**: поле есть (`config.cr:18`), читается из env, но в `HTTP::Client`
      провайдеров не пробрасывается
- [ ] **Компакция**: алгоритм есть, но `/compact` в TUI только печатает
      сообщение, реально не запускает `trigger_compaction_tui`
- [ ] **Сессии**: JSONL write/replay работают, но `/sessions` печатает список,
      а не интерактивный SelectList
- [ ] **Danger detection**: код есть, но не интегрирован в approval panel
      (сейчас y/n без меток опасности)
- [ ] `Context::Compaction` — LLM-based summarization как отдельный модуль
- [ ] `Loop::Retry` — rate-limit / error retry (429, 500s)
- [ ] `Config::Paths` — XDG-aware path resolution
- [ ] `Config::ProviderConfig` — отдельный конфиг per-provider
- [ ] `Permission::Policies` — полноценное rule matching
- [ ] `Prompt::Workspace` — cwd file tree (2 levels) в system prompt

## Приоритет починки

1. Очередь сообщений + steer (§1) — ломает интерактив
2. Provider-свитчер довести (§1)
3. `/compact` реальный + компакция UI
4. Danger labels в approval
5. `/sessions` как SelectList
6. Прокси в HTTP::Client
7. Дальше — панели/команды по скоупу фаз
