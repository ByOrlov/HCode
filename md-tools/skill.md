# Skill — план портирования из JS в Crystal

> Источник: `packages/agent-core-v2/src/agent/skill/tools/skill.ts`
> + `skill.md`, `skill.ts` (interface), `skillService.ts`, `skillOps.ts`,
>   `prompt.ts`, `app/skillCatalog/registry.ts`.

Цель — тул `Skill` в `h2code.cr/src/tools/skill.cr` с идентичным
LLM-контрактом. Вызов зарегистрированного skill встраивает его промпт в
**текущий ход** через `Context::Memory` injection (аналог JS steer delivery).

---

## 1. Контракт тула

| Поле           | JS (`SkillTool`)                                                | Crystal (`Tools::Skill`)                                |
|----------------|-----------------------------------------------------------------|----------------------------------------------------------|
| `name`         | `'Skill' as const`                                              | `"Skill"`                                                |
| `description`  | `renderPrompt(skillDescriptionTemplate, { MAX_SKILL_QUERY_DEPTH })` | `DESCRIPTION` (verbatim §1.2)                            |
| `parameters`   | `toInputJsonSchema(SkillToolInputSchema)`                       | Эквивалентная JSON Schema                                |
| `execute`      | возвращает `delivery: { kind: 'steer', message }`               | Возвращает `ToolResult` + побочный эффект injection       |

### 1.1. `name`

`"Skill"`.

### 1.2. `description` (verbatim)

> Примечание: `MAX_SKILL_QUERY_DEPTH = 3` передаётся как nunjucks-переменная,
> но в шаблоне не интерполируется. Описание фиксировано.

```
Invoke a registered skill from the current skill listing. BLOCKING REQUIREMENT: when a skill from the listing matches the user's request, you MUST call this tool (not free-form text). Do not re-invoke a skill to repeat work already done: if a `<h2code-skill-loaded>` block for it with the same `args` is already present in the conversation, follow those instructions directly instead of calling the tool again. Do call the tool again when you need the skill with different arguments — the loaded block was expanded with the earlier `args` and will not reflect new inputs.
```

### 1.3. `parameters` — JSON Schema

```json
{
  "type": "object",
  "properties": {
    "skill": {
      "type": "string",
      "description": "The exact name of the skill to invoke, spelled as it appears in the current skill listing (e.g. \"commit\", \"pdf\")."
    },
    "args": {
      "type": "string",
      "description": "Optional argument string for the skill, written like a command line (e.g. `-m \"fix bug\"`, `123`, a file path). It is split on whitespace (quotes group a token) and expanded into the skill's placeholders ($NAME, $1, $ARGUMENTS); if the skill body has no placeholders, the whole string is still appended as a trailing `ARGUMENTS:` line. Omit it only when there is nothing to pass."
    }
  },
  "required": ["skill"],
  "additionalProperties": false
}
```

| Поле    | Тип      | Required | Default | Описание          |
|---------|----------|----------|---------|-------------------|
| `skill` | `string` | ✅        | —       | имя skill         |
| `args`  | `string` | ❌        | `""`    | аргументы (CLI-style) |

---

## 2. Константы / ошибки

| Имя                       | Значение                                                                       |
|---------------------------|---------------------------------------------------------------------------------|
| `MAX_SKILL_QUERY_DEPTH`   | `3`                                                                             |

```crystal
class NestedSkillTooDeepError < Exception
  getter skill_name : String?
  getter depth : Int32
  def initialize(@skill_name : String?, @depth : Int32)
    name_str = @skill_name ? "\"#{@skill_name}\"" : ""
    super("Nested skill invocation #{name_str} exceeded the maximum depth of #{@depth} — refusing to recurse further.")
  end
end
```

---

## 3. Валидация — все ветки в `execute_model_skill`

В порядке:

1. `current_depth >= MAX_SKILL_QUERY_DEPTH (3)` → throw `NestedSkillTooDeepError`.
2. `catalog.get_skill(args.skill).nil?` →
   `{ isError: true, output: "Skill \"#{args.skill}\" not found in the current skill listing." }`.
3. `skill.metadata.disable_model_invocation == true` →
   `{ isError: true, output: "Skill \"#{name}\" can only be triggered by the user (model invocation is disabled)." }`.
4. `!inline_skill_type?(skill.metadata.type)` →
   `{ isError: true, output: "Skill \"#{name}\" is not an inline skill and cannot be invoked by the model in v1." }`.

`inline_skill_type?(type)` = `type.nil? || type == "prompt" || type == "inline"`.

`get_skill` нормализует имя: `name.downcase`.

---

## 4. Успешный путь — `origin`, рендеринг, запись

```crystal
skill_args = args.args || ""
trigger = current_depth > 0 ? "nested-skill" : "model-tool"

origin = SkillActivationOrigin.new(
  activation_id: UUID.random.to_s,
  skill_name: skill.name,
  skill_args: skill_args.size > 0 ? skill_args : nil,
  trigger: trigger,                  # "model-tool" | "nested-skill"
  skill_type: skill.metadata.type,
  skill_path: skill.path,
  skill_source: skill.source,
)

skill_content = catalog.render_skill_prompt(skill, skill_args, session_id: session_id)

message = ContextMessage.new(
  role: "user",
  content: [TextPart.new(render_model_tool_skill_prompt(skill_name, skill_args, skill_content, skill_source, skill_dir, trigger))],
  origin: origin,
)

skill_service.record_model_tool_activation(origin)  # fire-and-forget

return ToolResult.success("Skill \"#{skill.name}\" loaded inline. Follow its instructions."),
       plus delivery injection of `message` into Context::Memory
```

---

## 5. Формат вывода — текст ToolResult

Возвращаемое `output` (что видит модель как tool result):

```
Skill "<skill.name>" loaded inline. Follow its instructions.
```

Сам контент skill — **НЕ** в tool result. Он уходит отдельной user-role
инжекцией в `Context::Memory` (см. §7).

---

## 6. Блок `<h2code-skill-loaded>`

`render_model_tool_skill_prompt` склеивает через `\n`:

```
Skill tool loaded instructions for this request. Follow them.
<h2code-skill-loadedATTRS>
<skillContent>
</h2code-skill-loaded>
```

Атрибуты (`render_skill_attributes` — только с непустым значением):

| Attr       | Source                                            | Всегда?                                                  |
|------------|---------------------------------------------------|----------------------------------------------------------|
| `name`     | `skill_name`                                      | да                                                       |
| `trigger`  | `trigger` (`"model-tool"` или `"nested-skill"`)   | да                                                       |
| `source`   | `skill_source` (`"project"`/`"user"`/`"extra"`/`"builtin"`) | только если определён                          |
| `dir`      | `skill_dir`                                       | только если определён                                    |
| `args`     | `skill_args` (raw строка, `""` если опущены)      | да — `args=""` рендерится при пустых args                |

Каждое значение экранируется через `escape_xml`:
`&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`, `"` → `&quot;`. Порядок важен — `&` первым.

---

## 7. Встраивание в текущий ход — механизм

JS использует `delivery: { kind: 'steer', message }`, который попадает в
текущий ход через `inject(message)` в `AgentPromptService`. В Crystal:

1. `ToolResult.success(output)` возвращается как обычно.
2. `Context::Memory#add_injection(content)` добавляет system-role
   сообщение (с существующим `MessageOrigin::Injection`).
3. Injection содержит ровно тот же текст, что и JS message.content —
   preamble + `<h2code-skill-loaded>…</h2code-skill-loaded>`.

Реализация в Crystal:

```crystal
class Skill < Tool
  @@memory : Context::Memory?
  def self.memory=(m); @@memory = m end
end

# В execute после успешной загрузки:
@@memory.try(&.add_injection(injection_text))
```

`add_injection` уже существует в `Context::Memory` (`src/context/memory.cr:39`)
и помечает сообщение как `MessageOrigin::Injection` — оно автоматически
удаляется между ходами через `prune_injections`.

---

## 8. Расширение плейсхолдеров skill (`render_skill_prompt`)

`catalog.render_skill_prompt(skill, raw_args, session_id)`:

1. `argument_names = parse_argument_names(skill.metadata.arguments)`.
   - `arguments` — string (split по whitespace) или array of strings.
   - Имена, состоящие только из цифр или пустые, отбрасываются.
2. `tokens = tokenize_args(raw_args)` — shell-токенайзер:
   - whitespace делит.
   - `'`/`"` переключают quoting (сами кавычки удаляются; quoted контент
     становится одним токеном даже если пустой).
   - escape chars отсутствуют.
3. Подстановка плейсхолдеров:
   - `$<name>` (не следует за `[` или word char) → `escape_xml_tags(tokens[i] || "")`.
   - `$ARGUMENTS[<n>]` → `tokens[n] || ""`.
   - `$<n>` (не следует за word char) → `tokens[n] || ""`.
   - `$ARGUMENTS` → весь `raw_args` (XML-tag-escaped).
   - `${H2CODE_SKILL_DIR}` → `skill_dir`.
   - `${H2CODE_SESSION_ID}` → `session_id || ""`.
4. Если ни один аргументный плейсхолдер не заменён И `raw_args.size > 0` →
   добавить `"\n\nARGUMENTS: #{escape_xml_tags(raw_args)}"`.
5. Если у skill есть `plugin.instructions` — prepend
   `<h2code-plugin-instructions plugin="#{escape_xml_attr(id)}">...</h2code-plugin-instructions>\n\n`.

`escape_xml_tags(s)` = заменить `<`→`&lt;`, `>`→`&gt;` (только два).
`escape_xml_attr(s)` = `&`→`&amp;`, `"`→`&quot;`.

---

## 9. Service abstraction — `IAgentSkillService`

```crystal
abstract class AgentSkillService
  abstract def activate(input : SkillActivationInput) : Turn
  abstract def record_model_tool_activation(origin : SkillActivationOrigin) : Nil
end
```

Тул вызывает **только** `record_model_tool_activation(origin)` (fire-and-forget).
`activate` — для user-slash пути (`/skill foo`).

`record_model_tool_activation(origin)`:

1. `wire.dispatch(skill_activate({ origin: origin }))` — fire-and-forget
   Op (transient, `persist: false`).
2. `publish_activation(origin)` — telemetry:
   - `skill_invoked { skill_name, trigger }` (always)
   - `flow_invoked { flow_name }` (only when `origin.skill_type == "flow"`)
3. `input.nil?` (model-tool path) → return без нового turn'а.

---

## 10. Approval / accesses

- `approvalRule: 'Skill'` (без subject). Совпадает с Crystal
  `Permission::Manager` по умолчанию.
- `matchesRule: matchesGlobRuleSubject(ruleArgs, args.skill)` —
  позволяет `Skill(commit)`/`Skill(pdf)` правила (picomatch по имени skill).
- `accesses` — отсутствуют.

---

## 11. Существующая инфраструктура skill в h2code.cr

Crystal пока не имеет `SkillCatalog` / `AgentSkillService`. Минимальный
каркас:

```crystal
struct SkillDefinition
  property name : String
  property content : String
  property metadata : SkillMetadata
  property path : String?
  property source : String  # "project" | "user" | "extra" | "builtin"
end

struct SkillMetadata
  property type : String?            # nil | "prompt" | "inline" | "flow" | "reference"
  property arguments : String? | Array(String)?
  property disable_model_invocation : Bool = false
end

abstract class SkillCatalog
  abstract def get_skill(name : String) : SkillDefinition?
  abstract def ready? : Bool
  abstract def render_skill_prompt(skill : SkillDefinition, args : String, session_id : String?) : String
end

class Skill < Tool
  @@catalog : SkillCatalog?
  @@memory : Context::Memory?
  def self.catalog=(c); @@catalog = c end
  def self.memory=(m); @@memory = m end
end
```

---

## 12. План реализации (чек-лист)

- [ ] Прочитать JS: `skill.ts`, `skill.md`, `skill.ts` (interface),
      `skillService.ts`, `skillOps.ts`, `prompt.ts`,
      `app/skillCatalog/registry.ts`.
- [x] Описать контракт в `md-tools/skill.md`.
- [ ] Реализовать типы `SkillDefinition`, `SkillMetadata`, `SkillActivationOrigin`,
      `SkillCatalog` (abstract), `InMemorySkillCatalog`.
- [ ] Реализовать `Tools::Skill < Tool` в `src/tools/skill.cr`:
  - [ ] `name`, `description`, `parameters`.
  - [ ] `execute(input)`:
    1. `skill_name = input["skill"].to_s`.
    2. `args = input["args"]?.try(&.to_s) || ""`.
    3. Если `@@catalog.nil?` → `ToolResult.error("Skill catalog is not initialized.")`.
    4. `skill = @@catalog.get_skill(skill_name)` → ошибка §3.2 если nil.
    5. `disable_model_invocation` → ошибка §3.3.
    6. `!inline_skill_type?` → ошибка §3.4.
    7. `content = @@catalog.render_skill_prompt(skill, args, session_id)`.
    8. `injection_text = render_model_tool_skill_prompt(...)`.
    9. `@@memory.try(&.add_injection(injection_text))`.
    10. `ToolResult.success("Skill \"#{skill.name}\" loaded inline. Follow its instructions.")`.
  - [ ] Хелперы: `render_model_tool_skill_prompt`, `render_skill_attributes`,
        `escape_xml`, `escape_xml_tags`, `escape_xml_attr`, `tokenize_args`,
        `inline_skill_type?`, `parse_argument_names`.
- [ ] Зарегистрировать тул в `Tools::Registry`.
- [ ] Тесты в `spec/tools/skill_spec.cr`:
  - [ ] Skill не найден → `ToolResult.error("Skill \"...\" not found...")`.
  - [ ] `disable_model_invocation=true` → соответствующая ошибка.
  - [ ] `type="flow"` → соответствующая ошибка.
  - [ ] `type="prompt"` (default) → успех, injection в memory.
  - [ ] `args` с `$1`, `$ARGUMENTS`, `$NAME` — корректная подстановка.
  - [ ] `args` без плейсхолдеров в теле → добавляется `ARGUMENTS:` строка.
  - [ ] XML-экранирование в `<h2code-skill-loaded>` атрибутах.
- [ ] Обновить `FIX-TOOLS.md`: отметить строку #6 выполненной.

---

## 13. Расхождения / допущения

- `plugin.instructions` (prepend plugin-блока) — опущен в первом приближении
  (Crystal пока не имеет plugin-системы).
- Telemetry (`skill_invoked`, `flow_invoked`) — опущен.
- `wire.dispatch(skill_activate(...))` — опущен (нет wire-сервиса). Достаточно
  `record_model_tool_activation` как fire-and-forget hook; позже можно
  подключить event bus.
- `NestedSkillTooDeepError` и `withInitialQueryDepth(n)` — реализовать как
  защиту (query depth state), но не подключать к loop'у в первом
  приближении. По умолчанию depth=0 и ошибка не срабатывает.
- skill metadata `arguments` — строка или массив строк; поддержать оба формата.
