# select_tools tool — план портирования из JS в Crystal

> Источник: `packages/agent-core-v2/src/agent/toolSelect/`:
> `tools/select-tools.ts`, `toolSelect.ts` (contract),
> `toolSelectService.ts` (impl), `toolSelectAnnouncements.ts`,
> `toolSelectAnnouncementsService.ts`, `dynamicTools.ts`, `flag.ts`.

Цель — 1 тул `Tools::SelectTools` в `h2code.cr/src/tools/select_tools.cr`,
предлагаемый в shaped tool view только пока открыт disclosure gate
(progressive tool disclosure). Тул позволяет модели загрузить
MCP/deferred-тулы по точному имени из announced tool list.

**Регистрация** — всегда (если активна), но в shaped view виден только при
`toolSelect.enabled?`.

---

## 1. Контракт

### 1.1. `name`

`"select_tools"` (snake_case — единственный тул с подчёркиванием в имени).

Константа `SELECT_TOOLS_TOOL_NAME = "select_tools"`.

### 1.2. `description` (verbatim)

```
Load one or more tools by name so you can call them. All available tool names are listed in the <tools_added>/<tools_removed> announcements in the system context — fold them in order to get the current list. Pass the exact name(s) you need; their full definitions become available immediately, so you can call them directly in your next tool call.
```

### 1.3. `parameters`

```json
{
  "type": "object",
  "properties": {
    "names": {
      "type": "array",
      "items": { "type": "string" },
      "minItems": 1,
      "description": "Exact tool names to load, taken from the latest announced tool list."
    }
  },
  "required": ["names"],
  "additionalProperties": false
}
```

Strict-object (zod `.strict()` → `additionalProperties: false`).

---

## 2. `resolveExecution`

```crystal
def resolve_execution(args) : ToolExecution
  {
    description:     "Loading #{args.names.join(", ")}",
    approval_rule:   "select_tools",
    matches_rule:    nil,  # без path/glob subject
    execute:         ->execute(args.names),
  }
end
```

---

## 3. `execute` — алгоритм

1. Если `!@tool_select.enabled?` →
   `ToolResult.error("select_tools is not available for the current model.")`.
2. `result = @tool_select.load(args.names)` возвращает:
   ```crystal
   struct LoadToolsResult
     property to_load : Array(String)            # вновь загруженные
     property already_available : Array(String)  # уже были активны
     property unknown : Array(String)            # не найдены в announcements
   end
   ```
3. Build output lines:
   - `to_load.any?` → `"Loaded: #{to_load.join(", ")}"`.
   - `already_available.any?` → `"Already available: #{already_available.join(", ")}"`.
   - для каждого `name` в `unknown`:
     `"Unknown tool: #{name}. Pick from the latest announced tools list."`.
4. `is_error = to_load.empty? && already_available.empty?`.
5. Return:
   ```crystal
   ToolResult.new(output: lines.join('\n'), is_error: is_error)
   ```

---

## 4. `ToolSelectService` — абстракция

```crystal
SELECT_TOOLS_TOOL_NAME = "select_tools"

abstract class ToolSelectService
  abstract def enabled? : Bool
  abstract def shape_tools(entries : Array(ToolInfo)) : Array(ShapedToolEntry)
  abstract def shape_history(messages : Array(ContextMessage)) : Array(ContextMessage)
  abstract def load(names : Array(String)) : LoadToolsResult
  abstract def loadable_tools_announcement : String?
end

struct ShapedToolEntry < ToolInfo
  property deferred : Bool?  # true = не посылать schema, только имя
end

struct LoadToolsResult
  property to_load : Array(String)
  property already_available : Array(String)
  property unknown : Array(String)
end
```

### `enabled?`

True если:

- Модель поддерживает progressive disclosure (capability flag).
- Disclosure gate открыт (например, активирован experimental flag
  `H2CODE_EXPERIMENTAL_TOOL_SELECT` или model-config флаг).

### `shape_tools(entries)`

- Если `!enabled?` → вернуть entries as-is (всегда full schemas).
- Если `enabled?`:
  - Встроенные тулы (Bash/Read/Write/…) — full schemas.
  - MCP / deferred тулы — заменить на `ShapedToolEntry` с `deferred: true`
    (schema опускается, остаётся только `name`).
- `select_tools` всегда full schema (чтобы модель могла его вызвать).

### `shape_history(messages)`

- Если `!enabled?` → as-is.
- Если `enabled?` — удалить tool-call аргументы для deferred тулов в
  исторических ассистент-сообщениях (оставить только имена), чтобы
  снизить token overhead. Конкретнее см. `toolSelectService.ts`.

### `load(names)`

- Для каждого name:
  - Уже в активном set → в `already_available`.
  - Есть в announcements (loadable) → загрузить schema из MCP-server,
    добавить в активный set, в `to_load`.
  - Не найден → в `unknown`.
- Изменение активного set триггерит `<tools_added>` / `<tools_removed>`
  announcement injection в `Context::Memory`.

### `loadable_tools_announcement`

Возвращает строку с текущим списком loadable tools (для
`<tools_loadable>` блока) или nil если disclosure выключен.

---

## 5. Announcements (XML-блоки)

Прогрессивный disclosure использует несколько XML-блоков, которые
инъектируются в context через `Context::Memory#add_injection`:

- `<tools_loadable>` — список всех loadable tool names (один раз в
  начале, обновляется при изменении set).
- `<tools_added>` — добавленные с момента последнего shape (после
  `select_tools` call или MCP server registration).
- `<tools_removed>` — удалённые с момента последнего shape.

Формат (пример):

```
<tools_loadable>
mcp__github__create_issue
mcp__github__list_pulls
mcp__filesystem__extended_search
</tools_loadable>
```

`toolSelectAnnouncementsService.ts` генерирует эти блоки и обновляет при
изменении registry.

---

## 6. Disclosure gate (flag)

`flag.ts`:

```crystal
TOOL_SELECT_FLAG = "toolSelect"

# В flags registry:
register_flag_definition(FlagDefinition.new(
  id: TOOL_SELECT_FLAG,
  default: false,
  env_key: "H2CODE_EXPERIMENTAL_TOOL_SELECT",
))
```

Включение через `H2CODE_EXPERIMENTAL_TOOL_SELECT=1` или
`H2CODE_EXPERIMENTAL_FLAG=1`.

`toolSelect.enabled?` → `flags.enabled(TOOL_SELECT_FLAG) && model_capability.supports_progressive_disclosure`.

---

## 7. План реализации (чек-лист)

- [ ] Прочитать JS: `tools/select-tools.ts`, `toolSelect.ts`,
      `toolSelectService.ts`, `toolSelectAnnouncements.ts`,
      `toolSelectAnnouncementsService.ts`, `dynamicTools.ts`,
      `flag.ts`.
- [x] Описать контракт в `md-tools/select-tools.md`.
- [ ] Добавить experimental flag `toolSelect` в
      `packages/agent-core/src/flags/registry.ts` (Crystal — в
      соответствующий flags module).
- [ ] Реализовать `ToolSelectService` (abstract) + простую impl:
  - [ ] `enabled?` (flag + capability check).
  - [ ] `shape_tools(entries)` с `deferred: true` для MCP.
  - [ ] `shape_history(messages)` с stripping deferred tool args.
  - [ ] `load(names)` с трёхсторонней классификацией.
  - [ ] `loadable_tools_announcement` — генерация XML-блока.
- [ ] Реализовать `Tools::SelectTools` (§1–§3).
- [ ] Реализовать announcements service — генерация `<tools_loadable>` /
      `<tools_added>` / `<tools_removed>` блоков, injection через
      `Context::Memory#add_injection`.
- [ ] Реализовать динамический MCP-tool loading (подгрузка schema из
      MCP-server при `load`).
- [ ] Регистрация `select_tools` в `src/h2code.cr:166` — всегда (т.к.
      сам тул не deferred).
- [ ] В Loop-runner'е: применять `shape_tools` перед сериализацией в
      provider request, `shape_history` — к message history.
- [ ] Тесты в `spec/tools/select_tools_spec.cr`:
  - [ ] disabled → `"select_tools is not available for the current model."`.
  - [ ] success — `Loaded: a, b`.
  - [ ] already available — `Already available: c`.
  - [ ] unknown — `Unknown tool: x. Pick from the latest announced tools list.`.
  - [ ] partial — mixed case, lines order.
  - [ ] isError — `to_load.empty? && already_available.empty?`.
- [ ] Обновить `FIX-TOOLS.md`: отметить строку #20 выполненной.

---

## 8. Расхождения / дополнения

- В отличие от большинства тулов, `select_tools` — единственный со
  snake_case-именем (это исторически сложилось в MCP-экосистеме).
- Shaped view — критичен: без него модель не сможет пользоваться
  disclosure (видя `select_tools` в early turns и loadable list, но не
  видя schemas остальных MCP-тулов до явного запроса).
- MCP-server loading — зависит от MCP-client infrastructure (которая
  сама по себе большая задача). MVP — disclosure работает для builtin
  "deferred" тулов, без MCP.
- Announcements — генерируются на основе diff'а active set между
  turn'ами. Хранится в `ToolSelectService` last-seen snapshot.
- `shape_history` — strip tool args в исторических сообщениях только
  для deferred тулов (не builtin). Builtin тулы остаются полными.
- Token economics — основная цель PTD: сэкономить tokens в early turns,
  не посылая schemas редко-используемых тулов. Критично для
  MCP-heavy setups.
- В Crystal `Array(String).join(", ")` — прямый аналог JS
  `names.join(", ")`.
