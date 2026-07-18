# FIX-TOOLS — Задачи по приведению Crystal-тулов к паритету с JS

Сравнение: JS-движок (`packages/agent-core-v2`) имеет ~26 встроенных инструментов, Crystal-прототип (`hcode.cr`) — 7.

## 1. Отсутствующие в Crystal tools

| # | Tool | Группа | Задача | Приоритет |
|---|---|---|---|---|
| 1 | `Agent` | Субагенты | ✅ DONE — `src/tools/agent.cr` (13/13 specs). Subagent launch (foreground/background), profile catalog, `AgentRunner` abstract contract. |
| 2 | `AgentSwarm` | Субагенты | ✅ DONE — `src/tools/agent_swarm.cr` (14 spec). |
| 3 | `AskUserQuestion` | Взаимодействие с пользователем | ✅ DONE — `src/tools/ask_user_question.cr` (19/19 specs). 1-4 structured questions, `QuestionService` + `AgentTaskService` contracts. |
| 4 | `FetchURL` | Веб | ✅ DONE — `src/tools/fetch_url.cr` (18/18 specs). SSRF protection, HTML extraction, `UrlFetcher`/`WebFetchService`/`LocalFetcher` contracts. |
| 5 | `WebSearch` | Веб | ✅ DONE — `src/tools/web_search.cr` (11/11 specs). Moonshot provider, error classification, truncation. |
| 6 | `Skill` | Навыки | ✅ DONE — `src/tools/skill.cr` (14/14 specs). Placeholder substitution (`$1`, `$ARGUMENTS`, `$NAME`), `SkillCatalog`/`InMemorySkillCatalog`. |
| 7 | `EnterPlanMode` | Планирование | ✅ DONE — `src/tools/plan_mode.cr` (15/15 specs shared). `EnterPlanMode` + `ExitPlanMode`, `PlanService`/`AgentPlanService`. |
| 8 | `ExitPlanMode` | Планирование | ✅ DONE — combined with `EnterPlanMode` in `src/tools/plan_mode.cr`. |
| 9 | `CreateGoal` | Цели | ✅ DONE — `src/tools/goal.cr` (25/25 specs shared). `GoalService`/`AgentGoalService`, `GoalStatus`/`GoalSnapshot`/`GoalBudgetLimits`/`GoalBudgetReport`. |
| 10 | `GetGoal` | Цели | ✅ DONE — combined with `CreateGoal` in `src/tools/goal.cr`. |
| 11 | `UpdateGoal` | Цели | ✅ DONE — combined with `CreateGoal` in `src/tools/goal.cr`. |
| 12 | `SetGoalBudget` | Цели | ✅ DONE — combined with `CreateGoal` in `src/tools/goal.cr`. |
| 13 | `TaskList` | Фоновые задачи | ✅ DONE — `src/tools/task.cr` (39/39 specs shared). `TaskService`/`InMemoryTaskService`, `AgentTaskInfo`/`AgentTaskOutputSnapshot`. |
| 14 | `TaskOutput` | Фоновые задачи | ✅ DONE — combined with `TaskList` in `src/tools/task.cr`. |
| 15 | `TaskStop` | Фоновые задачи | ✅ DONE — combined with `TaskList` in `src/tools/task.cr`. |
| 16 | `CronCreate` | Планировщик | ✅ DONE — `src/tools/cron.cr` (40/40 specs shared). `SessionCronService`/`InMemoryCronService`, cron parser `Cron.parse_expression`/`compute_next_cron_run`/`to_human`. |
| 17 | `CronList` | Планировщик | ✅ DONE — combined with `CronCreate` in `src/tools/cron.cr`. |
| 18 | `CronDelete` | Планировщик | ✅ DONE — combined with `CronCreate` in `src/tools/cron.cr`. |
| 19 | `ReadMediaFile` | Мультимодальность | ✅ DONE — `src/tools/read_media.cr` (25/25 specs). `MediaFileSystem`/`LocalMediaFileSystem`, `MediaKind` enum, `detect_media_file_type`/`sniff_image_dimensions`. |
| 20 | `select_tools` | Управление инструментами | ✅ DONE — `src/tools/select_tools.cr` (12/12 specs). `ToolSelectService`/`InMemoryToolSelectService`, `LoadToolsResult` (to_load/already_available/unknown). |

## 2. Доработка существующих Crystal tools до паритета с JS

| Tool | Чего не хватает в Crystal по сравнению с JS | Задача | Приоритет |
|---|---|---|---|
| `Bash` | Только foreground; `run_in_background` отклоняется; `timeout` max 300 с; нет `disable_timeout` | Добавить фоновое выполнение (`run_in_background`), `disable_timeout`, auto-background-on-timeout и увеличить max timeout для фона | Высокий |
| `Grep` | Нет `output_mode`, контекста `-A`/`-B`/`-C`, `-i`, `multiline`, пагинации `head_limit`/`offset`, `type`, `include_ignored`, sensitive/VCS-фильтрации и сортировки по mtime | Расширить схему и реализацию до полного паритета с JS `GrepTool` | Высокий |
| `Read` | Имена параметров расходятся (`filePath`/`offset`/`limit`); нет отрицательного tail-offset; нет детекта NUL/бинарных; нет обработки line-endings; нет транкации строк | Выровнять имена (`path`/`line_offset`/`n_lines`), добавить tail-чтение, бинарный/NUL-детект, нормализацию line-endings и транкацию строк | Высокий |
| `Write` | Имена параметров расходятся (`filePath`/`content`); нет `mode: append`; нет проверки «родитель — не директория»; нет path access policy | Выровнять имена (`path`/`content`/`mode`), добавить append-режим, валидацию родителя и path access policy | Высокий |
| `Edit` | Имена параметров расходятся (`filePath`/`oldString`/`newString`/`replaceAll`) | Выровнять имена (`path`/`old_string`/`new_string`/`replace_all`), остальная функциональность близка к паритету | Средний |
| `Glob` | Близок к паритету; Windows-пути out-of-scope | При необходимости добавить Windows-специфичную обработку путей, иначе считать готовым | Низкий |
| `TodoList` | Схема расходится (`content`/`completed`/`cancelled`/`priority` vs `title`/`status: done`); нет персистентности в session store | Выровнять схему с JS (`title`, `status: pending/in_progress/done`), добавить персистентность и query-режим | Средний |
