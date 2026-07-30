# Multi-Content Message: переход на `ContentPart[]`

Перевод `LLM::Message.content` с `String?` на `Array(ContentPart)` по образцу
`kosong` (`kimi-code/packages/kosong/src/message.ts`). Цель: мультимодальный
ввод (images/audio/video), персистентность reasoning (`ThinkPart`), основа для
vision/Anthropic в будущем.

План построен волнами: каждая волна компилируется и проходит тесты
самостоятельно, следующая начинает с зелёного состояния.

---

## Волна 0 — Типы (`src/llm/types.cr`)

Сердце изменения. Добавить иерархию `ContentPart`, заменить `Message.content`,
расширить сериализацию.

### 0.1 ContentPart hierarchy

Новые типы в `types.cr`, рядом с существующими `MessagePart` (streaming).

```crystal
abstract class ContentPart
  include JSON::Serializable
  use_json_discriminator "type", {
    text:      TextContent,
    think:     ThinkContent,
    image_url: ImageContent,
    audio_url: AudioContent,
    video_url: VideoContent,
  }
  property type : String
end

class TextContent < ContentPart
  property text : String
  def initialize(@text); @type = "text"; end
end

class ThinkContent < ContentPart
  property think : String
  property encrypted : String?
  def initialize(@think, @encrypted = nil); @type = "think"; end
end

class ImageContent < ContentPart
  property image_url : ImageRef
  def initialize(@image_url); @type = "image_url"; end
end

struct ImageRef
  include JSON::Serializable
  property url : String
  property id : String?
  def initialize(@url, @id = nil); end
end

# AudioContent / VideoContent / AudioRef / VideoRef — аналогично
```

Назначение каждого типа:

| Тип | Зачем | Источник в kosong |
|---|---|---|
| `TextContent` | текст | `TextPart` |
| `ThinkContent` | reasoning, переживает шаг и resume; `encrypted` — подпись Anthropic (на будущее) | `ThinkPart` |
| `ImageContent` | vision input (base64 data URL или remote URL) | `ImageURLPart` |
| `AudioContent` | audio input | `AudioURLPart` |
| `VideoContent` | video input | `VideoURLPart` |

### 0.2 Message.content → Array(ContentPart)

```crystal
struct Message
  property role : String
  property content : Array(ContentPart)
  @[JSON::Field(emit_null: false)]
  property tool_calls : Array(ToolCall)?
  @[JSON::Field(emit_null: false)]
  property tool_call_id : String?
end
```

Конструкторы-фабрики принимают строку и оборачивают её в `[TextContent.new(s)]`:

```crystal
def self.user(content : String) : Message
  new("user", [TextContent.new(content)] of ContentPart)
end

def self.user(content : Array(ContentPart)) : Message
  new("user", content)
end
```

Аналогично `.assistant`, `.tool`, `.system`. Строковая перегрузка сохраняется
для обратной совместимости с ~30 точками вызова.

### 0.3 Хелпер extract_text

```crystal
def self.extract_text(content : Array(ContentPart)) : String
  content.select(TextContent).map(&.text).join
end

def text : String
  ContentPart.extract_text(@content)
end
```

Используется в местах, которым нужен «просто текст» (token counter, TUI export,
debug print). Эквивалент `extractText()` в kosong.

### 0.4 JSON-сериализация Message

`Message.to_json` — ручной метод (как сейчас у `ChatRequest`), чтобы:
- `content` сериализовался как массив объектов с `type`-дискриминатором;
- nil-поля (`tool_calls`, `tool_call_id`) пропускались;
- десериализация через `use_json_discriminator` корректно восстанавливала
  union `TextContent | ThinkContent | ImageContent | ...`.

### 0.5 Обновить streaming MessagePart

Текущие `TextPart`, `ThinkPart`, `ToolCallPart`, `UsagePart`, `FinishPart`
(streaming) — **не трогать**. Они служат для yield'а в блок `chat()`, а не для
хscения в истории. Связь: провайдер накапливает `TextPart` deltas и в конце
шага формирует `Message` с `[TextContent.new(accumulated_text)]`.

### 0.6 spec/llm/types_spec.cr

Обновить тесты:
- `.user("hello")` → `msg.content` — это `Array(ContentPart)`,
  `msg.content.first.is_a?(TextContent)` → true,
  `msg.text` → `"hello"`.
- JSON: `msg.to_json` → `"content":[{"type":"text","text":"hello"}]`.
- Сериализация с `ThinkContent` (добавить новый тест).
- Десериализация через `Message.from_json` корректно восстанавливает типы.

---

## Волна 1 — Адаптация потребителей

Каждый файл правится минимально: `.content` (String?) → `.text` (String) или
`.content` (Array). Места, которым нужен массив (провайдеры), получают его
напрямую.

### 1.1 src/context/memory.cr

`add_user`, `add_assistant`, `add_tool_result` принимают `String` (как сейчас)
и内部но оборачивают в `[TextContent.new(s)]`. Это сохраняет все 30 точек
вызова рабочими без правок.

```crystal
def add_user(content : String) : Nil
  @history << ContextMessage.new(Message.user(content))
  update_token_count
end
```

— без изменений, т.к. `Message.user(String)` перегрузка обрабатывает обёртку.

### 1.2 src/llm/token_counter.cr

```crystal
# было: total += estimate(content) если content = String?
# стало:
msg.text.each... → total += estimate(msg.text)
```

Учитывать `ThinkContent` в токен-подсчёте:
`content.each { |p| total += estimate(p.text) если p TextContent|ThinkContent }`.

### 1.3 src/llm/openai_chat_provider.cr

`chat()` уже сериализует `ChatRequest` через `Message.to_json` — после волны 0
`content` автоматически станет массивом в JSON. OpenAI Chat Completions wire
формат принимает `content: [{"type":"text","text":"..."}]` — это стандарт.

Спец-кейс: если в `content` есть `ImageContent`, провайдер должен слать
`content: [{"type":"text",...},{"type":"image_url",...}]` — тоже стандарт
OpenAI vision API. `Message.to_json` из волны 0 это уже обеспечит.

`build_request` — без изменений, он оперирует `Array(Message)`.

### 1.4 src/loop/agent.cr

- Строка 78: `@context.add_assistant(step_result.text, step_result.tool_calls)` —
  без изменений (`add_assistant` принимает строку).
- Строка 141 (debug print): `msg.content.to_s[0...80]` → `msg.text[0...80]`.
- Строка 256 (compaction prompt): `old_messages.map(&.message.content.to_s)` →
  `old_messages.map(&.message.text)`.

### 1.5 src/loop/tool_batch.cr

- Строка 70: `result.content` — это `ToolResult.content`, **не** `Message.content`.
  Не путать; не трогать.
- Строка 152: `budgeted_content` — строка из `Budget.budget`. Не трогать.
- Строка 173–174: `@context.add_tool_result(result.content, ...)` — без изменений
  (`add_tool_result` принимает строку).

### 1.6 src/loop/subagent_agent_runner.cr, subagent_swarm_runner.cr

- `cm.message.content.to_s` → `cm.message.text` (3 точки).

### 1.7 src/tui/app.cr

Самый большой объём (~15 точек), но все однотипные:
`msg.content.to_s` → `msg.text`.

Конкретные точки:
- 569: `[compacted] #{msg.content.to_s}` → `msg.text`
- 575: `msg.content.to_s` → `msg.text`
- 587: `(text = msg.content).to_s.empty?` → `(text = msg.text).empty?`
- 588: `Message.new("assistant", text.to_s)` — `text` уже String
- 591: `msg.content.to_s` → `msg.text`
- 593: `msg.content.to_s` → `msg.text`
- 1527: `last_assistant.content` → `last_assistant.text`
- 2445, 2451, 2453, 2507, 2517, 2522, 2527, 2698: `msg.content` → `msg.text`

### 1.8 src/hcode.cr

- 676: `cm.message.content.to_s` → `cm.message.text`
- 999, 1001, 1004: `msg.content` → `msg.text` (export_session)
- headless render (`run_headless`): использует streaming events, не `Message.content` напрямую.

### 1.9 src/tools/*

- `fetch_url.cr`, `skill.cr`, `plan_mode.cr`: `.content` обращается к
  `ToolResult.content` / `FetchResult.content` / `PlanStatus.content` —
  **не** к `Message.content`. Не трогать.

---

## Волна 2 — Персистентность reasoning (ThinkPart)

Сейчас `ThinkPart` приходит только в streaming и теряется после шага.
Сохраняем его в `Message.content` как `ThinkContent`.

### 2.1 src/llm/openai_chat_provider.cr — накопление thinking

В `chat()`:
```crystal
accumulated_text = IO::Memory.new
accumulated_thinking = IO::Memory.new   # ← новый
# ...
if reasoning = delta.reasoning_content
  accumulated_thinking << reasoning
  block.call(ThinkPart.new(reasoning))
end
# ...
# Финальный StepResult + формирование Message агентом:
```

Шаг 2 — агент (волна 2.2) добавит thinking в историю.

### 2.2 src/loop/agent.cr — сохранение thinking в историю

```crystal
unless step_result.text.empty? && step_result.tool_calls.empty?
  parts = [] of LLM::ContentPart
  parts << LLM::TextContent.new(step_result.text) unless step_result.text.empty?
  parts << LLM::ThinkContent.new(step_result.thinking) unless step_result.thinking.empty?
  @context.add_assistant_parts(parts, step_result.tool_calls)
  # ...
end
```

`StepResult` получает новое поле `thinking : String = ""`.

`Context::Memory` получает метод:
```crystal
def add_assistant_parts(parts : Array(LLM::ContentPart), tool_calls = nil)
  msg = LLM::Message.assistant_parts(parts, tool_calls)
  @history << ContextMessage.new(msg)
  update_token_count
end
```

### 2.3 src/session/store.cr — персистенция thinking в wire.jsonl

В `replay()` добавить обработку thinking из события `assistant.text`.
Вариант: расширить wire-событие `assistant.text` полем `thinking`:

```json
{"type":"assistant.text","data":{"content":"...","thinking":"..."}}
```

В `replay`:
```crystal
when "assistant.text"
  text = event[:data]["content"]?.try(&.to_s) || ""
  thinking = event[:data]["thinking"]?.try(&.to_s)
  parts = [] of LLM::ContentPart
  parts << LLM::ThinkContent.new(thinking) if thinking && !thinking.empty?
  parts << LLM::TextContent.new(text) unless text.empty?
  mem.add_assistant_parts(parts) unless parts.empty?
```

В `hcode.cr` (`run_interactive`, `run_headless`) — при `assistant_text` event
персистить thinking:
```crystal
when .assistant_text?
  store.append("assistant.text", {
    "content" => JSON::Any.new(event.text),
    "thinking" => event.thinking ? JSON::Any.new(event.thinking) : nil,
  })
```

`Loop::Event.assistant_text` получает опциональное поле `thinking : String?`.

### 2.4 spec/session/session_spec.cr

Добавить тест: round-trip thinking через `wire.jsonl` → `replay`.

---

## Волна 3 — Миграция старых сессий

Старые сессии хранят `assistant.text` events с `content` строкой и без `thinking`.
Миграция не требует конвертации файлов — совместимость обеспечивается в `replay`.

### 3.1 Обратная совместимость replay (главная защита)

`Store#replay` уже обрабатывает `assistant.text` — в старых сессиях `content`
хранится как строка, а `thinking` отсутствует. После волны 0 `content` в
wire-событии остаётся строкой (мы пишем `{"content": JSON::Any.new(text)}`),
поэтому **старые и новые события имеют идентичный wire-формат для текста**.

Поле `thinking` добавляется как опциональное (`event[:data]["thinking"]?`),
поэтому старые события без него просто дают `nil` → `ThinkContent` не
создаётся. **Никакой конвертации файлов не требуется.**

### 3.2 Message JSON backwards compat

`Message.from_json` должен принимать оба формата `content`:
- **Новый:** `"content":[{"type":"text","text":"hello"}]` — массив частей.
- **Старый:** `"content":"hello"` — голая строка.

Реализуется кастомным `from_json` через `JSON::Serializable` + ручной парсинг:
если `content` парсится как `String`, оборачиваем в `[TextContent.new(s)]`;
если как массив — стандартный путь через `use_json_discriminator`.

Это нужно только для мест, где `Message.from_json` вызывается напрямую (вне
`wire.jsonl`). В wire.jsonl формат контролируется полностью (см. 3.1).

### 3.3 live migration при resume

При `store.replay(memory)` старой сессии:
- Старые `assistant.text` events читаются как `content: String` →
  `replay` оборачивает в `[TextContent.new(text)]`.
- Thinking утрачен (его не было в wire) — это ожидаемо и корректно: модель
  не возвращала reasoning в старых сессиях, либо он не сохранялся.
- После resume новые шаги пишутся в wire уже с `thinking` полем (если модель
  его вернула) — смешанный формат в одном файле валиден.

**Пользователь не должен ничего делать.** Старые сессии открываются, рендерятся
и продолжаются без конвертации.

### 3.4 Версионирование wire (на будущее)

Добавить опциональное поле `wire_version` в `state.json`:
```json
{"id":"...","wire_version":2,...}
```
Текущие сессии не имеют поля → v1 (поведение по умолчанию). Позволит未来
детектировать формат и при необходимости конвертировать.

---

## Волна 4 — Хелперы (по образцу kosong)

Дополнительные функции из `message.ts` для удобства и future-proofing.

### 4.1 merge_in_place (streaming accumulation)

```crystal
def ContentPart.merge_in_place(target : ContentPart, source : ContentPart) : Bool
  case {target, source}
  when {TextContent, TextContent}
    target.text += source.text; true
  when {ThinkContent, ThinkContent}
    target.think += source.think; true
  else
    false
  end
end
```

Полезно, если позже перейдём на итераторную модель streaming (как kosong).
Сейчас не критично — провайдер накапливает в `IO::Memory`.

### 4.2 is_content_part / extract_text (public API)

Уже добавлены в волне 0.3 (`extract_text`). Дополнить `text` accessor на `Message`.

---

## Порядок выполнения

| Волна | Что | Зависимости | Риск |
|---|---|---|---|
| 0 | Типы: `ContentPart`, `Message.content: Array` | нет | низкий |
| 1 | Правка ~30 потребителей `.content → .text` | волна 0 | низкий, механически |
| 2 | Персистенция reasoning (`ThinkContent` в истории + wire) | волны 0+1 | средний |
| 3 | Миграция: backwards-compat `Message.from_json` + replay | волны 0–2 | низкий |
| 4 | Хелперы kosong (`merge_in_place` и др.) | волна 0 | низкий |

После каждой волны: `crystal spec` должен быть зелёным.

---

## Что НЕ делается сейчас (вне scope)

- **Anthropic / Google / OpenAI Responses провайдеры** — архитектурно готовы,
  но реализация отдельных провайдеров отдельной задачей.
- **`uploadVideo` / `uploadFile`** — требует серверной интеграции (Kimi files
  API); когда появится vision input, добавить метод в `Provider`.
- **`ModelCapability` matrix** — отдельная задача (см. предыдущее обсуждение).
- **`ResponseFormat` (structured output)** — отдельная задача.
- **Message-level tools** (`messages[].tools`) — узкая Kimi-specific фича,
  откладывается до явной потребности.

---

## Файлы, затрагиваемые изменением

| Файл | Волна | Что меняется |
|---|---|---|
| `src/llm/types.cr` | 0 | новые типы `ContentPart*`, `Message.content: Array`, `extract_text` |
| `spec/llm/types_spec.cr` | 0 | обновить тесты под новый формат |
| `src/context/memory.cr` | 1 | `add_assistant_parts`, без изменения существующих методов |
| `src/llm/token_counter.cr` | 1 | `.text` вместо `.content`, учёт `ThinkContent` |
| `src/llm/openai_chat_provider.cr` | 1+2 | накопление thinking, сериализация content array |
| `src/loop/agent.cr` | 1+2 | `.text`, сохранение thinking в историю |
| `src/loop/tool_batch.cr` | 1 | только если обращается к `Message.content` (нет) |
| `src/loop/subagent_agent_runner.cr` | 1 | `.content.to_s` → `.text` |
| `src/loop/subagent_swarm_runner.cr` | 1 | `.content.to_s` → `.text` |
| `src/tui/app.cr` | 1 | ~15 точек `.content` → `.text` |
| `src/hcode.cr` | 1+2 | export, undo, wire persistence |
| `src/session/store.cr` | 2+3 | replay thinking, backwards-compat |
| `spec/session/session_spec.cr` | 2+3 | round-trip thinking test |
| `src/llm/provider.cr` | 0 | без изменений (абстракция не зависит от content) |

---

## Риски и решения

### Риск: `Message.to_json` ломает OpenAI wire формат

OpenAI Chat Completions принимает оба:
- `"content":"hello"` (legacy string)
- `"content":[{"type":"text","text":"hello"}]` (новый, vision-ready)

Moonshot (Kimi) тоже принимает оба. Ollama / LM Studio (OpenAI-compatible) —
тоже. Поэтому переход на массив не ломает существующие провайдеры.

**Проверка:** после волны 0 запустить `crystal spec` + мануально проверить,
что `provider.build_request(...).to_json` выдаёт валидный wire JSON.

### Риск: Производительность (аллокация массива на каждое сообщение)

`[TextContent.new(s)]` — один массив + один объект на сообщение. Для типичной
сессии (сотни сообщений) накладные расходы ~KB, незаметны. Существующий
`profiled_bytes` будет учитывать новый layout автоматически (волна 0.5).

### Риск: Регрессия TUI при отображении

Волна 1 правит все точки в `app.cr`, где `msg.content` использовался как
строка. После правки `msg.text` возвращает строку идентично старому
`msg.content.to_s`. Спека `spec/tui/` (если есть) должна это подтвердить.

### Риск: Старые сессии с `content` строкой в `wire.jsonl`

**Не проблема:** wire-формат `assistant.text` events остаётся
`{"content": "..."}`  — мы контролируем это в `store.cr#append`. `replay`
читает строку и оборачивает в `[TextContent]`. См. волна 3.
