# Подключить /plan режим в Crystal-версии

## Контекст

В Crystal уже портированы контракты инструментов `EnterPlanMode`/`ExitPlanMode`
(`src/tools/plan_mode.cr`) и slash-команда `/plan` (`src/tui/app.cr:1551`), но
они **не соединены с рантаймом**:

- `PlanMode.plan_service` никогда не назначается в `run_interactive` → инструменты
  падают с "Plan service is not initialized."
- `app.on_plan_mode` никогда не выставляется → `/plan` падает с "Plan mode is not
  wired up."
- `PlanMode.permission_mode` не выставляется → недостижима auto-ветка.
- Нет enforcement read-only (JS имеет `plan-mode-guard-deny.ts`).
- Нет reminder-инъекции в контекст (JS имеет `PlanModeInjector`).
- Нет интерактивного review-диалога для `ExitPlanMode` (JS имеет
  `exit-plan-mode-review-ask.ts` + TUI `PlanBoxComponent` / approval-runtime).

Цель: закончить портирование — сделать `/plan`, `EnterPlanMode`, `ExitPlanMode`
работоспособными с полным паритетом к JS: permission guard + reminder + review
диалог.

## Архитектурные решения

1. **Состояние plan-mode — на `Agent`, а не глобал.** Сейчас `PlanMode` — модуль с
   `class_property` (глобал). Глобал работает для тестов, но `AgentPlanService`
   должен жить в рамках сессии/агента и знать `session_dir` + `agent_id`. Поэтому
   сервис создаётся в `run_interactive` и кладётся в `PlanMode.plan_service`
   (глобал) — это согласуется с существующим паттерном `Tools::Task.service = ...`
   и `Tools::AskUserQuestion.service = ...` в `hcode.cr`. Минус — глобал; плюс —
   ноль инвазии в `Agent`/`Loop::ToolBatch`. Решение: оставить глобал (как уже
   сделано для `Task`/`AskUserQuestion`), но инициализировать его в
   `run_interactive`.

2. **Permission guard — как правило `RuleSet`, а не новая абстракция политик.** В
   Crystal `Permission::Manager.check` сначала гоняет `rules.evaluate`, потом
   режим. JS имеет отдельные `PermissionPolicy`-классы; Crystal — проще. План: в
   `PlanMode.guard_check(tool_name, args)` (новый метод в `PlanMode`-модуле)
   проверять активен ли plan mode и возвращает deny-сообщение для мутирующих
   инструментов, кроме записи в plan-файл. `Permission::Manager.check` будет
   звать его в самом начале. Это минимальная инвазия — одна строка в `check`.

3. **Reminder-инъекция — в `inject_step_reminders`.** Уже есть в
   `Loop::Agent#inject_step_reminders` (todo-напоминание). Добавить туда же
   plan-mode reminder как `<system-reminder>` через `@context.add_injection`.

4. **Review-диалог — по образцу `AppQuestionService` + `QuestionDialog`.**
   `ExitPlanMode.execute` в auto-режиме остаётся как есть. В manual/yolo — через
   новый `PlanReviewService` (глобал как `QuestionService`): сервис вызывает
   `app.request_plan_review(plan, path, options)`, App показывает
   `PlanReviewDialog`, возвращает результат (Approve/Revise/Reject/Reject&Exit +
   выбранный option + feedback). `ExitPlanMode` формирует итоговое сообщение по
   тем же правилам, что JS `exitPlanModeApprovalResult`.

## План реализации

### 1. Инициализация PlanService в `run_interactive`
**Файл:** `src/hcode.cr`, метод `run_interactive` (около строки 634, где
создаются `permission`, `lifecycle`).

- Создать `plan_service = Tools::AgentPlanService.new(store.session_dir,
  "main", plan_path)` где `plan_path` = `File.join(store.session_dir,
  "agents/main/plans")` — сервис сам построит путь к файлу по id.
- `Tools::PlanMode.plan_service = plan_service`
- `Tools::PlanMode.permission_mode = Tools::PermissionModeRef.new(auto:
  permission.mode.auto?)`
- Назначить `app.on_plan_mode` — callback, который:
  - при включении: `plan_service.enter` + обновляет `@plan_mode` в TUI
  - при выключении через повторный `/plan`: `plan_service.cancel` + сбрасывает
    флаг
  - возвращает `true` если переключение удалось, `false` если сервис не задан
- В существующем обработчике `/plan` (`src/tui/app.cr:1551`) сейчас уже есть
  ветка с `@on_plan_mode.try(&.call(...))` — менять логику не нужно, только
  назначить callback.
- Очистка при `app.on_new_session` / `on_resume_session`: сбрасывать
  `plan_service`, иначе plan-mode «протекает» между сессиями. Создавать новый
  сервис на новый `store.session_dir`.

### 2. Permission guard для read-only enforcement
**Файл:** `src/tools/plan_mode.cr` (новый метод в модуле `PlanMode`).

Добавить:
```crystal
MUTATING_TOOLS = {"Write", "Edit", "TaskStop", "CronCreate", "CronDelete"}

def self.guard_check(tool_name : String, args : String) : String?
  svc = plan_service
  return nil unless svc && (status = svc.status)
  plan_path = status.path

  if tool_name == "Write" || tool_name == "Edit"
    # Разрешить запись только в plan-файл.
    target = extract_path(tool_name, args)
    if target && plan_path && File.expand_path(target) == File.expand_path(plan_path)
      return nil
    end
    return "Plan mode is active. You may only write to the current plan file: #{plan_path || "(no plan file selected yet)"}. Call ExitPlanMode to exit plan mode before editing other files."
  end

  if MUTATING_TOOLS.includes?(tool_name)
    return "#{tool_name} is not available in plan mode. Call ExitPlanMode first."
  end

  nil
end
```
`extract_path` — парсит JSON args и достаёт `filePath` (Write/Edit).

**Файл:** `src/permission/manager.cr`, метод `check` (строка 61).
В самое начало `check`, до `@rules.evaluate`, вставить:
```crystal
if plan_block = Tools::PlanMode.guard_check(tool_name, args)
  on_event.call(Loop::Event.info(plan_block))
  return false
end
```
Это автоматически блокирует мутирующие инструменты пока plan mode активен, во
всех режимах (yolo тоже) — как в JS.

### 3. Reminder-инъекция в `Loop::Agent`
**Файл:** `src/loop/agent.cr`, метод `inject_step_reminders` (строка 252).

После todo-reminder добавить план-reminder:
```crystal
private def inject_plan_reminder : Nil
  svc = Tools::PlanMode.plan_service
  return unless svc && (status = svc.status)
  plan_path = status.path
  body = plan_mode_active_reminder(plan_path)
  reminder = "<system-reminder>\n#{body}\n</system-reminder>"
  @context.add_injection(reminder)
end
```
Текст `plan_mode_active_reminder` — упрощённый аналог JS `fullReminder`: workflow
(understand → design → write plan → exit), запрет править всё кроме plan-файла,
требование завершать ход `ExitPlanMode`. При `plan_path.nil?` — вариант "no plan
file path available".

### 4. `ExitPlanMode` review-диалог
**4a. Сервисный контракт.**
**Файл:** `src/tools/plan_mode.cr`, добавить в модуль `Tools`:
```crystal
enum PlanReviewDecision
  Approve
  Revise
  RejectAndExit
  Dismissed  # Esc / Ctrl-C
end

struct PlanReviewResult
  getter decision : PlanReviewDecision
  getter selected_label : String?   # для options
  getter feedback : String          # для Revise
end

abstract class PlanReviewService
  abstract def request(plan : String, path : String?,
                       options : Array(PlanOption)?) : PlanReviewResult?
end

# В модуль PlanMode добавить class_property plan_review_service
```

**4b. App-side сервис + диалог.**
**Файл:** `src/tui/plan_review_dialog.cr` (новый) — по образцу
`QuestionDialog`. Методы `show(plan, path, options, on_result)`,
`handle_input`, `render`, `visible?`. UI:
- Заголовок: "Plan review" + имя файла плана.
- Тело: отрендеренный markdown плана (через `MarkdownRenderer`, как
  `render_plan_body_lines` в `app.cr:2787`).
- Если `options` (>=1): список radio-переключателей label + description.
- Кнопки (нижняя строка): `[Approve] [Revise] [Reject & Exit] [Cancel]`.
- При `Revise` — inline ввод feedback (как "Other" в QuestionDialog).
- `Cancel` (Esc) → `Dismissed`.
Возвращает `PlanReviewResult`.

**Файл:** `src/tui/app.cr` — добавить `@plan_review_dialog : PlanReviewDialog`,
свойство `request_plan_review(...)` (по образцу `request_questions`, строка 838),
интегрировать в `handle_input` (строка 909) и `render` (строка 2255).

**Файл:** `src/hcode.cr` — добавить класс `AppPlanReviewService <
Tools::PlanReviewService` (по образцу `AppQuestionService`, строка 1188),
блокирующий на `Channel(PlanReviewResult)`. Назначить
`Tools::PlanMode.plan_review_service = AppPlanReviewService.new(app)` в
`run_interactive`.

**4c. Логика в `ExitPlanMode.execute`.**
**Файл:** `src/tools/plan_mode.cr`, метод `execute` (строка 181).
Сейчас при non-auto режиме он просто выходит. Заменить:
```crystal
mode = PlanMode.permission_mode
if mode && mode.auto?
  service.exit
  ToolResult.success(format_auto_approved(resolved.content, status.path))
else
  # Interactive review.
  reviewer = PlanMode.plan_review_service
  if reviewer.nil?
    # Без UI (headless) — auto-approve как fallback.
    service.exit
    return ToolResult.success(format_user_approved(resolved.content, status.path))
  end
  result = reviewer.request(resolved.content, status.path, options)
  # Обработка по JS exitPlanModeApprovalResult:
  case result.try(&.decision) || PlanReviewDecision::Dismissed
  in .approve?
    service.exit
    sel = result.not_nil!.selected_label
    prefix = sel ? "Selected approach: #{sel}\n..." : ""
    ToolResult.success(prefix + format_user_approved(resolved.content, status.path))
  in .revise?
    fb = result.not_nil!.feedback
    msg = fb.empty? ? "User requested revisions. Plan mode remains active." :
      "User rejected the plan. Feedback:\n\n#{fb}"
    ToolResult.success(msg)  # режим НЕ выходим
  in .reject_and_exit?
    service.exit
    ToolResult.error("Plan rejected by user. Plan mode deactivated.")
  in .dismissed?
    ToolResult.success("Plan approval dismissed. Plan mode remains active.")
  end
end
```

### 5. Тесты
**Файлы:** дополнить `spec/tools/plan_mode_spec.cr`, `spec/loop/agent_spec.cr`,
`spec/permission/` (новый или существующий).

- `spec/tools/plan_mode_spec.cr`: добавить кейсы review-диалога через mock
  `PlanReviewService` (возвращает фиксированный `PlanReviewResult`) — проверить
  все 4 ветки (approve без options, approve с option+selected_label, revise с
  feedback, revise без feedback, reject_and_exit, dismissed).
- `spec/permission/manager_spec.cr` (или `policies_spec.cr`): проверить, что
  `guard_check` блокирует `Write`/`Edit`/`TaskStop`/`CronCreate`/`CronDelete`
  пока plan mode активен, и пропускает запись в plan-файл + read-only
  инструменты.
- `spec/loop/agent_spec.cr`: добавить интеграционный кейс — mock provider
  вызывает `EnterPlanMode`, затем пытается `Write` (блокируется guard), затем
  `ExitPlanMode` (auto-режим) — проверить что reminder инъецирован и Write
  заблокирован.

### 6. Сборка / проверка
- `crystal spec spec/tools/plan_mode_spec.cr spec/loop/agent_spec.cr` —
  должны пройти.
- `crystal build src/hcode.cr` — должно компилироваться.
- Вручную: `/plan` → индикатор "Plan mode: on" → `EnterPlanMode` → reminder →
  попытка Write блокируется → `ExitPlanMode` → диалог.

## Файлы (резюме изменений)

| Файл | Изменение |
|------|-----------|
| `src/hcode.cr` | Создание `AgentPlanService`, назначение `plan_service`/`permission_mode`/`plan_review_service`, `app.on_plan_mode` callback, `AppPlanReviewService`, сброс при new/resume session |
| `src/tools/plan_mode.cr` | `guard_check`, `PlanReviewService` контракт, `PlanReviewDecision`/`PlanReviewResult`, `PlanMode.plan_review_service`, переработка `ExitPlanMode.execute` под review |
| `src/permission/manager.cr` | Вызов `PlanMode.guard_check` в начале `check` |
| `src/loop/agent.cr` | `inject_plan_reminder` + вызов в `inject_step_reminders` |
| `src/tui/plan_review_dialog.cr` | Новый TUI-компонент review-диалога |
| `src/tui/app.cr` | `@plan_review_dialog`, `request_plan_review`, интеграция в input/render |
| `spec/tools/plan_mode_spec.cr` | Тесты review-веток |
| `spec/permission/*` | Тесты guard_check |
| `spec/loop/agent_spec.cr` | Интеграционный тест plan-mode flow |

## Риски / заметки

- `PlanMode` — глобал (`class_property`). Согласовано с паттернами `Task`/
  `AskUserQuestion`. Если сессия меняется (new/resume), сервис нужно
  пересоздавать, иначе state протечёт.
- `ExitPlanMode.execute` сейчас не async и блокирует fiber tool-batch-а — это
  нормально, `AppQuestionService` делает так же (ждёт на канале).
- В JS review-диалог использует approval-runtime с `ToolInputDisplay.plan_review`.
  В Crystal мы идём через сервисный глобал — проще, без перестройки tool execution
  pipeline.
