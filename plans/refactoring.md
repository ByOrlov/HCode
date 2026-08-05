# Разбиение `src/tui/app.cr` на модули

## Контекст

`src/tui/app.cr` — 4628 строк, крупнейший файл проекта. Содержит один класс
`Hcode::TUI::App` плюс хелпер-структуры. Проект уже применяет паттерн:
связная группа методов выносится в модуль в отдельном файле и подключается
через `include` в `App`. Так сделаны `SetupController` (`setup_controller.cr`,
240 строк) и `CommandController` (`command_controller.cr`, 486 строк). Их
методы (даже `private`) свободно вызывают друг друга и обращаются к ivars
класса — эта видимость работает внутри одного включающего класса, чем и
воспользуемся.

Список загрузки файлов явный: `src/hcode.cr:117-144`. Новые файлы нужно
вставлять в этот список **до** строки `require "./tui/app"` (142), чтобы модули
были определены к моменту `include`.

Контракт спецификаций: `spec/tui/*` вызывают на экземпляре `App` методы
`render_message`, `build_rendered_lines`, `build_rendered_lines_split`,
`wrap_editor_line`, `render_to`, `render_plan_box`, `render_welcome_box` —
после разбиения (через `include`) они остаются callable. Менять сигнатуры/
видимость НЕ нужно.

Цель: **чисто механическое** разбиение без изменения поведения. Никаких правок
логики, переименований, рефакторинга — только перенос методов и констант в
модули + обновление `require`.

## Структура файлов (итог)

`app.cr` после разбиения должен содержать только:
- `module Hcode; module TUI` обёртку;
- хелпер-структуры, если не переедут в `app_models.cr` (см. ниже);
- объявление `class App` с `include`-списком всех контроллеров;
- все ivars/properties (`@...` и `property ...`);
- `initialize`, `stop`, `run`, `restore_terminal`, `move_cursor_to_bottom`;
- мелкие аксессоры профилировщика (`profiled_bytes`, `profiled_count`,
  `render_buffer_*`, `queue_*`, `dirty!`, `force_redraw!`, `add_message`).

### `src/tui/app_models.cr` (≈200 строк)
Структуры данных и константа, вынесенные из верха `app.cr`:
- `ReadGroupEntry` (строки 3-17)
- `SwarmMember` (22-52)
- `MCP_HELP_TEXT` (54-115)
- `Message` (117-179)
- `ApprovalRequest` (181-188)
- `QueuedMessage` (190-200)

Все они лежат в `module Hcode::TUI`, как и сейчас.

### `src/tui/event_controller.cr` — `module EventController`
«Вход со стороны агента»: обработка событий цикла и запросы одобрения.
- `on_event` (759-984)
- `find_swarm_message`, `recompute_swarm_active` (988-1007)
- `handle_subagent_started/progress/terminal` (1009-1058)
- `load_transcript_from_memory`, `attach_tool_result` (682-743)
- `show_interrupted` (745-757)
- `inject_plan_if_any`, `extract_plan_body`, `extract_plan_path` (3261-3295)
- `snapshot_todo_if_complete!` (3961-3973)
- Запросы одобрения (вызываются из loop/tools, ждут ввода по каналу):
  `request_approval`, `request_sudo_approval`, `request_questions`,
  `request_plan_review` (1060-1122), константа `SUDO_APPROVAL_OPTIONS`.

### `src/tui/input_controller.cr` — `module InputController`
«Ввод с клавиатуры»: диспетчер клавиш и все селекторы/диалоги.
- `handle_key` (1124-1347)
- `handle_approval_key`, `handle_sudo_approval_key` (1349-1363, 2305-2321)
- Командные подсказки: `update_command_hints`, `command_hint_window` (1572-1604)
- Внешний редактор, буфер обмена, экспорт debug-бандла: `handle_external_editor`,
  `copy_to_clipboard`, `clipboard_command`, `export_debug_bundle` (1606-1705)
- `toggle_plan_mode`, `toggle_debug_zones` (1707-1728)
- `handle_slash_command` (1730-1854) — диспетчер остаётся здесь (он уже
  делегирует в `CommandController`)
- Обработчики swarm/plugin/goal/language-команд (1856-2009)
- Открытие/обработка селекторов: `open_tasks_browser`, `open_undo_selector`,
  `open_help_panel`/`handle_help_key`, `open_provider_selector`/
  `handle_provider_key`, `needs_setup?`, `start_setup_for_provider`,
  `provider_label`, `open_permission_selector`/`handle_permission_list_key`/
  `apply_permission_mode`, effort, theme, sudo, `open_session_selector`/
  `session_picker_label`/`sanitize_picker_text`/`handle_session_key`,
  `open_model_selector`/`handle_model_key` (2011-2518); константы
  `PERMISSION_MODES`, `EFFORT_LEVELS`, `THEMES`, `SUDO_MODES`.

### `src/tui/turn_controller.cr` — `module TurnController`
Жизненный цикл хода/очереди/steer + утилиты предпросмотра.
- `submit_message`, `enqueue_message`, `start_turn`, `drain_next_queued`,
  `truncate_preview`, `deliver_external_prompt` (1365-1456)
- `tool_preview_text`, `tool_args_preview`, `truncate_json_field` (1458-1513),
  константы `TOOL_PREVIEW_LINES`, `TOOL_PREVIEW_CHARS`
- `queue_hint`, `steer_or_queue`, `steer_queued` (1515-1570)
- `finalize_streaming_thinking`, `thinking_status` (4058-4069)
- `detect_git_branch`, `visible_len`, `current_tip` (4053-4086), константа `TIPS`

### `src/tui/render_controller.cr` — `module RenderController`
Пайплайн сборки кадра (геометрия/зоны/курсор), без попавшего в `App`
минимума.
- `render`, `render_now`, `build_render_output`, `render_to` (2520-2561)
- `throttle_log`, `render_zones`, `do_render` (2566-2620)
- `build_rendered_lines`, `build_rendered_lines_split` (2626-2830)
- `invalidate_log_cache!` (2639-2641)
- `truncate_render_lines`, `apply_line_resets` (2835-2855)
- `incremental_render` (2899-2978)
- `position_cursor` (2980-3037)
- Сборка активной зоны (командные хинты, очередь списков/панелей) — та часть
  `build_rendered_lines_split`, что ссылается на рендереры панелей (2714-2826).

### `src/tui/message_renderer.cr` — `module MessageRenderer`
Рендер одной записи транскрипта и её блоков.
- `render_message` (3039-3165)
- `render_streaming_text`, `render_live_thinking` (3172-3250)
- `render_compaction_block`, `render_plan_box`, `title_visible`,
  `render_plan_body_lines`, `render_thinking_block`, `wrap_thinking`
  (3305-3478)
- `render_read_group`, `count_non_empty_lines`, `read_group_file_path`
  (3480-3552)
- `render_welcome_box`, `colorize_logo` (3562-3644)
- `render_running_tool`, `tool_header`, `render_swarm_progress` (4378-4554),
  константа `BRAILLE_LEVELS`
- `extract_key_argument`, `sudo_command?`, `wrap_text` (4556-4625)
- `render_edit_diff`, `render_highlighted_add` (4302-4371)
- `tool_preview` (4269-4300)

### `src/tui/ui_panels.cr` — `module UIPanels`
Рендер перекрывающих панелей и бокса редактора (самая объёмная часть рендера).
- `render_editor` (3554-3560)
- `render_editor_box`, `search_picker_active?`, `current_search_query`,
  `search_placeholder`, `render_query_row`, `build_editor_row`,
  `wrap_editor_line`, `cps_to_string` (3646-3930)
- `build_context_status`, `current_todos`, `render_todo_panel` (3937-3998)
- `render_queue_pane` (4003-4016)
- `render_footer` (4018-4040)
- `render_provider_panel`, `render_model_panel`, `model_picker_hint`,
  `render_picker_item` (4088-4212)
- `render_select_panel`, `render_approval_panel` (4214-4267)
- `render_session_panel`, `render_sudo_approval_panel` (2336-2358, 2438-2463)

## Порядок действий

1. Создать `app_models.cr`, перенести туда 6 структур + `MCP_HELP_TEXT`.
2. Создать 6 файлов-контроллеров, перенести методы согласно распределению выше.
   Каждый файл — `module Hcode; module TUI; module XController ... end; end; end`
   с теми же `private`/`def` квалификаторами. Константы переезжают вместе с
   использующими их методами.
3. В `class App` добавить `include EventController, InputController,
   TurnController, RenderController, MessageRenderer, UIPanels` (порядок не
   важен — модули не имеют коллизий методов).
4. Обновить список `require` в `src/hcode.cr`: вставить 7 новых
   `require "./tui/<file>"` **перед** строкой 142 (`require "./tui/app"`).
5. Удалить из `app.cr` перенесённый код; оставить только каркас (см. блок
   «структура файлов»).

## Проверка

- `crystal build src/hcode.cr` — компиляция (Crystal проверит сигнатуры и
  видимость методов между модулями на этапе компиляции).
- `crystal spec spec/tui/` — все TUI-спеки (`app_spec.cr`, `zone_*`,
  `editor_cursor_sync_spec`, `large_log_render_spec`, …) покрывают рендер,
  зоны и курсор; они должны остаться зелёными без правок.
- Сводно: `crystal spec spec/` целиком, чтобы убедиться, что ничего за
  пределами TUI не сломалось от изменения порядка загрузки.

## Риски / примечания

- **Видимость `private` между модулями**: уже работает в проекте
  (`SetupController`/`CommandController` вызывают private-методы `App` и
  наоборот). Подтверждается компилятором — любая ошибка разрешится на этапе
  build.
- **Константы**: при переносе в модуль становятся доступны включающему классу.
  Дубликатов имён между модулями нет (проверено по списку).
- **Порядок `require`**: новый файл должен идти до `app.cr`, т.к. `App`
  делает `include` этих модулей. Crystal однопроходный, порядок критичен.
- Поведение НЕ меняется — перенос дословный; риска регрессии логики нет,
  риск чисто синтаксический (опечатка при вырезании), ловится сборкой.
