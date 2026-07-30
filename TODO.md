# hcode — TODO (сравнение с kimi-code TS)

Состояние на 2026-07-30. Источник: прямая проверка `src/` (Crystal) + билд.
Билд собирается (`crystal build` зелёный). Ядро агента готово.

## Фактическая проверка переписала картину

Многое из того, что числилось отсутствующим, УЖЕ реализовано:

- **Workspace file tree** (2 уровня) — есть, `directory_listing` в
  `prompt/system_prompt.cr:188`, подставляется в `{{HCODE_WORK_DIR_LS}}`.
- **Syntax highlighting** (8 языков: crystal/ruby/python/js/ts/go/rust/bash/json)
  — есть, `highlight_code` в `tui/markdown.cr:721`.
- **Paste markers** `[paste #N ...]` — есть, `tui/editor.cr:4` + `@pastes`.
- **Ctrl+G / external editor** — есть, `handle_external_editor` (`app.cr:1234`).
- **Light theme** — есть, `Theme.light` (`theme.cr:79`).
- **Runtime selectors** `/provider` `/model` `/theme` `/permission` `/effort`
  через `SelectList` — есть, `open_*_selector` (`app.cr:1801+`), привязаны к
  колбэкам `on_provider_change`/`on_model_change`/... в `hcode.cr`.
- **`/add-dir`** — частично: только пишет "Added directory: X", НЕ хранит
  список и НЕ инжектит в system prompt (см. §3).
- **`Setup::Wizard`** — есть (148 строк), onboarding-флоу для первого запуска.

## 1. Отсутствующие подсистемы (нет директорий/файлов)

- [x] **`src/hooks/`** — РАБОТАЕТ. Движок shell-command hooks:
      `Hooks::Engine` (`hooks/engine.cr`): `HookDef`/`HookResult`/`BlockDecision`,
      регистрация по event, matcher через regex, запуск через `Process` (shell,
      JSON stdin, timeout 30s). Block-семантика: exit code 2 = block,
      `{"hookSpecificOutput":{"permissionDecision":"deny"}}` = block.
  - События: PreToolUse (block в `plan_calls`), PostToolUse/PostToolUseFailure
    (fire-and-forget в `execute_approved`), UserPromptSubmit (block в run_turn),
    Stop (block в run_turn)
  - Конфиг: `[[hooks]]` array-of-tables в config.toml (event/matcher/command/
    timeout), парсится в `Config.parse_hooks_array`
  - Wire-up: `Agent.hooks`, `ToolBatch` принимает `hooks:`; `hcode.cr` строит
    Engine из config.hooks
  - Тесты (12): empty/registration/matcher/exit-code/trigger_block/
    structured-JSON-deny/structured-JSON-allow/stdin-payload
- [ ] `src/auth/` OAuth — device-code flow (сейчас только чтение готовых токенов)
- [ ] `Config::Paths` — нет отдельного XDG-aware path resolver (сейчас пути
      резолвятся inline в `config.cr:89` и `session/`). Вынести в модуль.
- [ ] `Config::ProviderConfig` — нет отдельного per-provider конфиг-объекта.
      Сейчас provider-поля разбросаны по `Config`. Нужен структурированный
      `[provider.<name>]`.
- [ ] MCP-клиент — нет; `/mcp` заглушка.
- [ ] Plugins runtime — нет; `/plugins` заглушка.
- [ ] `/btw` — forked side-agent — нет.

## 2. Инфраструктура: реализована inline, не вынесена в модули

- [x] **`Context::Compaction`** — ВЫНЕСЕН. Логика суммаризации из
      `Agent#trigger_compaction` в `Context::Compaction` класс (`context/compaction.cr`).
      `Agent` делегирует; 3 теста (summarize/failure/token-reduction).
- [x] **`Loop::Retry`** — ВЫНЕСЕН. `RetryPolicy` класс (`loop/retry.cr`):
      delay-расчёт (экспоненциальный backoff 2^n, cap 30s), retryable?
      (ApiError flag, UserCancellationError→false, network→true).
      `execute_step` делегирует; 6 тестов.

## 3. `/add-dir` — не доведён (real storage)

✅ **ГОТОВО** — `/add-dir` теперь real storage:
- `@additional_dirs : Array(String)` в `App` + property + колбэк
  `on_additional_dirs_change`
- `/add-dir <path>`: `File.expand_path`, проверка `Dir.exists?`, дедуп,
  добавление, вызов колбэка
- `SystemPrompt.build(work_dir, additional_dirs)` — рендерит listing
  каждого каталога в `HCODE_ADDITIONAL_DIRS_INFO` → блок
  `## Additional Directories` в system prompt
- `hcode.cr` привязывает колбэк: ре-билд `system_prompt` при изменении
  (замкнутая переменная обновляется → следующий turn видит новый prompt)
- Тесты: 2 новых (omits section / includes listing)
- Note: permission-scope уже не нужен — `PathAccess` разрешает абсолютные
  пути вне work_dir для Read/Search/Write

## 4. TUI панели/диалоги (есть в TS, нет в Crystal)

Есть: thinking/step_summary, plan_box, todo_panel, tasks_browser,
undo_dialog, question_dialog, session_picker, help_panel, SelectList-диалоги.

Не хватает:
- [ ] `goal_panel` (команды `/goal` нет)
- [ ] `usage_panel` (команда `/usage` пишет в messages, отдельной панели нет)
- [ ] `compaction` диалог (сейчас info-event в transcript)
- [ ] `cron_message` рендер
- [ ] `skill_activation` рендер
- [ ] `agent_group` / `agent_swarm_progress` / `background_agent_status`
- [ ] `mcp_status_panel`, `plugins_status_panel`
- [ ] Searchable-list / paging для больших транскриптов

## 5. Слэш-команды (отсутствуют)

- [ ] `/goal` — autonomous goals (status/pause/resume/cancel/replace/next)
- [ ] `/swarm` — swarm mode
- [ ] `/reload-tui` — reload только `tui.toml` (`/reload` уже работает)

## 6. Рендеринг / полировка

- [x] **Word-level intra-line diff** — ГОТОВО. `DiffComputer` (`tui/diff.cr`):
      line-level LCS (как в TS), парные delete+ad получают word-level
      highlight span (changed middle между common prefix/suffix).
      `render_edit_diff` рендерит bold-подсветку изменённых слов внутри
      добавленной строки, header показывает +N/-M. 8 тестов.
- [ ] **Inline images** (Kitty graphics) — нет (намеренно отложено).
- [ ] **Image paste** (clipboard native bindings) — нет (отложено).
- [ ] **Custom themes через `tui.toml`** — только dark/light presets.

## 7. Skills — загрузка с диска отсутствует

✅ **ГОТОВО** — skills загружаются с диска:
- `SkillDiscovery.discover(home, work_dir)` — сканирует стандартные каталоги
  (`~/skills`, `~/.agents/skills`, `<project>/.hcode/skills`,
  `<project>/.agents/skills`), обходит подкаталоги с `SKILL.md`, дедуплит
- `Parser.parse` — парсит frontmatter (упрощённый YAML: name, description,
  type, when-to-use, arguments[], disable-model-invocation) + body
- `InMemorySkillCatalog#model_listing` — рендерит listing для system prompt
  (mirrors TS `getModelSkillListing`)
- `SkillMetadata` расширен: name, description, when_to_use
- `SkillDefinition#description` / `#when_to_use` getters
- `SystemPrompt.build(work_dir, additional_dirs, skills_listing)` — рендерит
  секцию `# Skills` в system prompt когда listing непустой
- Wire-up в `hcode.cr`: discover при старте → `Skill.catalog=` → listing
  в system prompt → пересборка при `/add-dir`
- Тесты: 7 новых (parser frontmatter/body/name-fallback/arguments-array,
  catalog listing skip-disabled/empty, discovery project/user/none)
- Багфикс: `find_project_root` возвращал `/` вместо `work_dir` при отсутствии
  `.git` (поднимался до корня ФС)

## Приоритет реализации

1. ✅ **`/add-dir` real storage** (§3) — ГОТОВО
2. ✅ **Skills loading** (§7) — ГОТОВО
3. ✅ **`Context::Compaction` extraction** (§2) — ГОТОВО
4. ✅ **`Loop::Retry` extraction** (§2) — ГОТОВО
5. ✅ **Word-level diff** (§6) — ГОТОВО
6. ✅ **`src/hooks/` engine** (§1) — ГОТОВО
7. **TUI панели** (§4) — goal/usage/compaction панели
8. **`src/auth/` OAuth** (§1) — device-code flow
9. **`Config::ProviderConfig`** (§1) — структурирует конфиг (отложено)
10. **`Config::Paths`** (§1) — XDG-aware вынос (отложено)
