# AskUserQuestion — план портирования из JS в Crystal

> Источник: `packages/agent-core-v2/src/agent/questionTools/tools/ask-user.ts`
> + `ask-user.md`, `question-background-task.ts`,
>   `session/question/question.ts`, `session/question/questionService.ts`,
>   `session/interaction/interaction.ts`,
>   `agent/task/notificationXml.ts`.

Цель — тул `AskUserQuestion` в `hcode.cr/src/tools/ask_user_question.cr` с
идентичным LLM-контрактом и инжекченным `QuestionService` для фактического
взаимодействия с пользователем.

---

## 1. Контракт тула

| Поле           | JS (`AskUserQuestionTool`)                                     | Crystal (`Tools::AskUserQuestion`)                     |
|----------------|----------------------------------------------------------------|---------------------------------------------------------|
| `name`         | `'AskUserQuestion' as const`                                  | `"AskUserQuestion"`                                     |
| `description`  | `${DESCRIPTION}- Set background=true ...` (verbatim см. §1.2) | Собирается из `DESCRIPTION` + суффикса                  |
| `parameters`   | `toInputJsonSchema(AskUserQuestionInputSchemaWithBackground)` | Эквивалентная JSON Schema через `JSON.parse`            |
| `execute`      | `resolveExecution(args).execute(ctx)`                         | `execute(input : JSON::Any) : ToolResult`               |

### 1.1. `name`

`"AskUserQuestion"`.

### 1.2. `description` (verbatim)

Состоит из базового `DESCRIPTION` (содержимое `ask-user.md`) и приписанного
суффикса, склеенных напрямую (без дополнительного перевода строки):

**DESCRIPTION** (verbatim):
```
Use this tool when you need to ask the user questions with structured options during execution. This allows you to:
1. Collect user preferences or requirements before proceeding
2. Resolve ambiguous or underspecified instructions
3. Let the user decide between implementation approaches as you work
4. Present concrete options when multiple valid directions exist

**When NOT to use:**
- When you can infer the answer from context — be decisive and proceed
- Trivial decisions that don't materially affect the outcome

Overusing this tool interrupts the user's flow. Only use it when the user's input genuinely changes your next action.

**Usage notes:**
- Users always have an "Other" option for custom input — don't create one yourself
- Use multi_select to allow multiple answers to be selected for a question
- Keep option labels concise (1-5 words), use descriptions for trade-offs and details
- Each question should have 2-4 meaningful, distinct options
- Question texts must be unique across the call, and option labels must be unique within each question
- You can ask 1-4 questions at a time; group related questions to minimize interruptions
- If you recommend a specific option, list it first and append "(Recommended)" to its label
- The result is JSON with an `answers` object keyed by question text; each value is the chosen option's label (comma-separated labels for multi_select, or the user's own words if they picked "Other"); if `answers` is empty and a `note` says the user dismissed it, they chose not to answer — do not treat this as selecting the recommended option; decide based on context and do not re-ask the same question
```

**Суффикс** (приписывается сразу после DESCRIPTION):
```
- Set background=true when you can keep working without the answer. This starts a background question task and returns a task_id immediately. The answer arrives automatically in a later turn — you do not need to poll, sleep, or check on it. Continue with other work; never fabricate or predict the answer.
```

### 1.3. `parameters` — JSON Schema

Поля (object, strict):

| Поле                          | Тип            | Required | Default | Описание (verbatim)                                                                                                                                                                                                                                                                |
|-------------------------------|----------------|----------|---------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `questions`                   | `array`        | ✅        | —       | `The questions to ask the user (1-4 questions).`                                                                                                                                                                                                                                  |
| `questions[].question`        | `string`       | ✅        | —       | `A specific, actionable question. End with '?'.`                                                                                                                                                                                                                                  |
| `questions[].header`          | `string`       | ❌        | `""`    | `Short category tag (max 12 chars, e.g. 'Auth', 'Style').`                                                                                                                                                                                                                        |
| `questions[].options`         | `array`        | ✅        | —       | `2-4 meaningful, distinct options. Do NOT include an 'Other' option — the system adds one automatically.`                                                                                                                                                                         |
| `questions[].options[].label` | `string`       | ✅        | —       | `Concise display text (1-5 words). If recommended, append '(Recommended)'.`                                                                                                                                                                                                       |
| `questions[].options[].description` | `string` | ❌        | `""`    | `Brief explanation of trade-offs or implications.`                                                                                                                                                                                                                                |
| `questions[].multi_select`    | `boolean`      | ❌        | `false` | `Whether the user can select multiple options.`                                                                                                                                                                                                                                    |
| `background`                  | `boolean`      | ❌        | `false` | `Set true to ask in the background and return immediately with a background task_id; you are notified automatically when the user answers — do not poll with TaskOutput while the question is pending.`                                                                            |

Ограничения:

- `questions`: `minItems: 1`, `maxItems: 4`.
- `questions[].options`: `minItems: 2`, `maxItems: 4`.
- `questions[].question`: `minLength: 1`.
- `questions[].options[].label`: `minLength: 1`.
- `additionalProperties: false` на каждом уровне.

---

## 2. Константы

| Имя                                       | Значение                                                                                                                                                                                                                                                               |
|-------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `MIN_QUESTIONS`                           | `1`                                                                                                                                                                                                                                                                    |
| `MAX_QUESTIONS`                           | `4`                                                                                                                                                                                                                                                                    |
| `MIN_OPTIONS`                             | `2`                                                                                                                                                                                                                                                                    |
| `MAX_OPTIONS`                             | `4`                                                                                                                                                                                                                                                                    |
| `QUESTION_UNIQUENESS_MESSAGE`             | `"Question texts must be unique across questions, and option labels must be unique within each question."`                                                                                                                                                              |
| `QUESTION_DISMISSED_MESSAGE`              | `"User dismissed the question without answering."`                                                                                                                                                                                                                     |
| `QUESTION_UNSUPPORTED_FAILURE_MESSAGE`    | `"The connected client does not support interactive questions. Do NOT call this tool again. Ask the user directly in your text response instead."`                                                                                                                       |

`header` (max 12 chars) и label (1-5 слов) — **advisory**, без жёсткого
ограничения в схеме.

---

## 3. Валидация — все ветки

### 3.1. JSON Schema-уровень

Реализуется вручную при парсинге входа в `parse_input` (Crystal не имеет
zod). При провале — `ToolResult.error(message)` с указанием, какое поле
ошиблось.

### 3.2. `question_uniqueness_error(questions) : String?`

Чистая функция, проверяющая кросс-поля. Два режима ошибок:

1. **Дубликат вопроса** в массиве:
   `"Invalid questions: duplicate question text <JSON.stringify(question)>. <QUESTION_UNIQUENESS_MESSAGE> Rephrase the duplicates and call the tool again."`
2. **Дубликат label внутри одного вопроса**:
   `"Invalid questions: duplicate option label <JSON.stringify(label)> in question <JSON.stringify(question)>. <QUESTION_UNIQUENESS_MESSAGE> Rephrase the duplicates and call the tool again."`

Один и тот же label в **двух разных вопросах** — разрешён. Сравнение
case-sensitive, без нормализации.

### 3.3. Execution-layer re-check

`question_uniqueness_error` вызывается ещё раз в начале `execute` (на случай
внутреннего вызова мимо схемы):

```crystal
if err = question_uniqueness_error(questions)
  return ToolResult.error(err)
end
```

### 3.4. `execute_question` — обработка ошибок

```crystal
rescue ex : AbortError
  raise ex  # пробросить
rescue ex : NotImplementedError
  return ToolResult.error(QUESTION_UNSUPPORTED_FAILURE_MESSAGE)
rescue ex
  return dismissed_result  # любая другая ошибка → dismissed, НЕ isError
end
```

Важно: ошибка `NOT_IMPLEMENTED` становится `isError: true` с жёстким
сообщением "Do NOT call this tool again". Любая другая ошибка тихо
превращается в dismissed-успех (без `"Do NOT call this tool again"`).

---

## 4. Формат вывода — 5 веток

### 4.1. Отвечено (foreground, непустой answers)

```crystal
{ answers: { "Вопрос 1?": "SQLite", "Вопрос 2?": "Postgres" } }.to_json
```

`method` (enter/space/number_key) **отбрасывается** из model-visible JSON;
идёт только в telemetry.

### 4.2. Dismissed (null / пустой answers / любая ошибка кроме NOT_IMPLEMENTED)

```json
{"answers":{},"note":"User dismissed the question without answering."}
```

### 4.3. Unsupported client (NOT_IMPLEMENTED)

`is_error: true`, контент — `QUESTION_UNSUPPORTED_FAILURE_MESSAGE`.

### 4.4. Uniqueness violation

`is_error: true`, контент — сообщение из §3.2.

### 4.5. Background immediate return

Многострочный текст (НЕ JSON):

```
task_id: <id>
description: <questionDescription>
status: running
automatic_notification: true
next_step: Continue your current work; the answer will arrive automatically when the user responds.
next_step: Use TaskOutput with this task_id for a non-blocking status/answer snapshot.
next_step: Use TaskStop only if the question should be cancelled.
human_shell_hint: The pending question is also visible in /tasks.
```

`questionDescription(questions)`:
- первый тримmed вопрос, или `"Ask user question"` если пустой;
- если вопросов > 1, добавить `" (+#{questions.size - 1} more)"`.

---

## 5. `QuestionService` — абстракция

```crystal
struct QuestionOption
  property label : String
  property description : String
end

struct QuestionItem
  property question : String
  property header : String
  property options : Array(QuestionOption)
  property multi_select : Bool
end

struct QuestionRequest
  property turn_id : Int32?
  property tool_call_id : String?
  property questions : Array(QuestionItem)
end

# Результат: nil = dismissed, Hash = answers (key = вопрос, value = строка ответа).
QuestionResult = Hash(String, String) | Nil

abstract class QuestionService
  abstract def request(req : QuestionRequest, signal : AbortController?) : QuestionResult
end

class AskUserQuestion < Tool
  @@service : QuestionService?
  def self.service=(s); @@service = s end
  def self.service; @@service end
  def self.tasks; @@tasks end  # IAgentTaskService? для background
end
```

Тул вызывает **только** `service.request(req, signal)`. `enqueue`/`answer`/
`dismiss`/`list_pending` существуют только для REST/TUI-адаптеров.

### 5.1. Маппинг snake_case → in-process

Тул конвертирует `multi_select` в `multi_select : Bool` поля `QuestionItem`
(в JS это `multiSelect`, в Crystal оставляем snake_case).

---

## 6. Background-режим (`background: true`)

### 6.1. Диспетчеризация

1. Pre-abort guard: `signal.aborted? → raise AbortError`.
2. `description = question_description(questions)`.
3. `task = QuestionBackgroundTask.new(->(task_signal) { execute_question(args, tool_call_id, turn_id, task_signal) }, description, question_count, tool_call_id)`.
4. `task_id = @@tasks.not_nil!.register_task(task, detached: true)`.
5. `status = @@tasks.not_nil!.get_task(task_id).try(&.status) || "running"`.
6. Вернуть блок §4.5 синхронно.

Если `register_task` выбрасывает — `ToolResult.error(ex.message)`.

### 6.2. `QuestionBackgroundTask`

```crystal
class QuestionBackgroundTask < AgentTask
  KIND = "question"
  ID_PREFIX = "question"

  def start(sink : AgentTaskSink) : Nil
    result = @run.call(sink.signal)
    output = result.content
    sink.append_output(output)
    sink.settle(status: :completed)  # ВСЕГДА completed, даже если result.is_error
  rescue ex : AbortError
    sink.settle(status: :killed)
  rescue ex
    sink.settle(status: :failed, stop_reason: ex.message)
  end

  def kind; "question" end
  def id_prefix; "question" end
end
```

**Важно:** v2 всегда ставит `:completed`, даже если внутренний `execute_question`
вернул `is_error: true` (например, NOT_IMPLEMENTED). v1 в этом случае ставил
`:failed` с `stopReason` — v2-поведение — source of truth.

### 6.3. Доставка ответа позже

Не через SystemReminder, а через `<notification>` XML, инжекченный в
`Context::Memory` как новая user-role запись. См. `md-tools/task.md` §5.

---

## 7. single-select vs multi-select, опции по умолчанию

- **Нет** предустановленной опции. Пользователь выбирает сам.
- Система автоматически добавляет «Other» для свободного ввода — на уровне
  TUI/REST-адаптера, **не** в схеме. Модели в описании явно сказано не
  создавать свой «Other».
- В JSON-ответе multi-select значения склеиваются через `", "` (запятая +
  пробел).
- «Other» в `answers` → текст пользователя как есть (не label).
- Рекомендуемая опция помечается добавлением `" (Recommended)"` к label и
  выставлением её первой — конвенция описания, без enforcement.

---

## 8. Approval rules / accesses

- `approvalRule: 'AskUserQuestion'` — без subject. Совпадает с тем, как
  Crystal `Permission::Manager` использует `tool.name` по умолчанию.
- `accesses` — отсутствуют. Тул не участвует в file/resource scheduling.
- **Auto-mode deny** — отдельная policy: при `Permission::Mode::Auto` тул
  жёстко отклоняется с сообщением
  `"AskUserQuestion is disabled while auto permission mode is active. Make a reasonable decision and continue without asking the user."`.
  В Crystal — добавить проверку в `Permission::Policies` или прямо в `execute`.

---

## 9. План реализации (чек-лист)

- [ ] Прочитать JS: `ask-user.ts`, `ask-user.md`, `question-background-task.ts`,
      `session/question/question.ts`, `session/question/questionService.ts`,
      `session/interaction/interaction.ts`, `agent/task/notificationXml.ts`.
- [x] Описать контракт в `md-tools/ask-user-question.md`.
- [ ] Реализовать типы `QuestionOption`, `QuestionItem`, `QuestionRequest`,
      `QuestionResult`, `QuestionService`, `QuestionBackgroundTask`.
- [ ] Реализовать `Tools::AskUserQuestion < Tool` в `src/tools/ask_user_question.cr`:
  - [ ] Константы §2.
  - [ ] `name`, `description` (см. §1.2), `parameters` (см. §1.3).
  - [ ] `execute(input)`:
    1. Парсинг + базовая валидация (min/max, minLength).
    2. `question_uniqueness_error` (§3.2) → `ToolResult.error`.
    3. Если `@@service.nil?` → `ToolResult.error(QUESTION_UNSUPPORTED_FAILURE_MESSAGE)`.
    4. Если `background == true` и `@@tasks.nil?` → fallback на foreground.
    5. Если `background == true` → `execute_in_background`.
    6. Иначе → `execute_question`.
  - [ ] `execute_question` (§3.4 rescue + §4.1/§4.2 рендер).
  - [ ] `execute_in_background` (§6.1 + рендер §4.5).
  - [ ] Хелперы: `question_description`, `question_uniqueness_error`,
        `dismissed_result`, `normalize_result`.
- [ ] Зарегистрировать тул в `Tools::Registry` (`src/hcode.cr`).
- [ ] Тесты в `spec/tools/ask_user_question_spec.cr`:
  - [ ] Схема: пустой `questions`, 1 option, пустой `question`/`label`,
        дубликат вопроса, дубликат label внутри вопроса.
  - [ ] Разрешён одинаковый label в разных вопросах.
  - [ ] Foreground-success: JSON с `answers`, без `method`.
  - [ ] Foreground-dismissed (null/empty): JSON с `note`.
  - [ ] Foreground NOT_IMPLEMENTED: `isError: true`, "Do NOT call this tool again".
  - [ ] Foreground общая ошибка → dismissed без "Do NOT call again".
  - [ ] AbortError пробрасывается.
  - [ ] Background: немедленный возврат с `task_id`, `automatic_notification: true`.
  - [ ] Auto-mode: отклонение с сообщением §8.
- [ ] Обновить `FIX-TOOLS.md`: отметить строку #3 выполненной.

---

## 10. Расхождения / допущения

- `trace` / `telemetry` (`question_answered`, `question_dismissed`) — опущены
  в первом приближении (Crystal пока не имеет `ITelemetryService`).
- `toolCallId` / `turnId` — передаются через `ToolContext` или аргументы
  `execute`. В кими.cr эти поля берутся из `Loop::ToolBatch::ToolCall`.
- `interaction` kernel (с pending-state и race semantics abort-after-park) —
  упрощён: `QuestionService#request` блокирует fiber до ответа пользователя.
  AbortController вызывает dismiss через `signal.on_abort { service.dismiss(id) }`.
- Background-доставка через `<notification>` — реализуется в
  `md-tools/task.md`, не здесь.
- Метод ввода `click` (не входит в тип `QuestionAnswerMethod`) — drop на
  границе.
- `QuestionAnswers` значение `string | true` — нормализуем `true` в строку
  вопроса (`question_text`).
