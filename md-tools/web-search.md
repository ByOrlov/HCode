# WebSearch — план портирования из JS в Crystal

> Источник: `packages/agent-core-v2/src/app/auth/webSearch/tools/web-search.ts`
> + `web-search.md`, `webSearch.ts`, `webSearchService.ts`,
>   `providers/moonshot-web-search.ts`, `app/auth/configSection.ts`.

Цель — тул `WebSearch` в `h2code.cr/src/tools/web_search.cr` с идентичным
LLM-контрактом. Поиск — через `MoonshotWebSearchProvider`, который дёргает
`<base_url>` endpoint с телом `{"text_query": "..."}`.

**Важно:** тул сам-региструется **только если** сконфигурирован провайдер.
Если ни `[services.moonshot_search]`, ни managed OAuth — тул не
регистрируется и модель его не видит.

---

## 1. Контракт тула

| Поле           | JS (`WebSearchTool`)                                | Crystal (`Tools::WebSearch`)                           |
|----------------|-----------------------------------------------------|---------------------------------------------------------|
| `name`         | `'WebSearch' as const`                              | `"WebSearch"`                                           |
| `description`  | импорт из `web-search.md?raw`                       | Константа `DESCRIPTION` (verbatim §1.2)                 |
| `parameters`   | `toInputJsonSchema(z.object({ query: z.string() }))`| Эквивалентная JSON Schema через `JSON.parse`            |
| `execute`      | `resolveExecution(args).execute(ctx)`               | `execute(input : JSON::Any) : ToolResult`               |

### 1.1. `name`

`"WebSearch"`.

### 1.2. `description` (verbatim)

```
Search the web for information. Use this when you need up-to-date information from the internet.

Each result includes its title, its URL, and a snippet, plus its source site and publication date when available. Results are short summaries, not full pages — when a result looks relevant, call the FetchURL tool on its URL to read the full page content. Fetch only the few URLs you actually need. Prefer specific queries, and refine the query if the results don't contain what you need.

When you rely on a result in your answer, cite its source URL so the user can verify it.
```

### 1.3. `parameters` — JSON Schema

```json
{
  "type": "object",
  "properties": {
    "query": {
      "type": "string",
      "description": "The query text to search for."
    }
  },
  "required": ["query"],
  "additionalProperties": false
}
```

Одно свойство `query` — string, **required**, без default/enum/constraints.

---

## 2. Константы

| Имя                  | Значение                                                                                                                                  |
|----------------------|--------------------------------------------------------------------------------------------------------------------------------------------|
| `MAX_CHARS`          | `50_000`                                                                                                                                   |
| `TRUNCATION_MARKER`  | `"[...truncated]"`                                                                                                                         |
| `TRUNCATION_MESSAGE` | `"Output is truncated to fit in the message."`                                                                                             |
| `NO_RESULTS_MESSAGE` | `"No search results found."`                                                                                                               |
| `CITE_REMINDER`      | `"When you rely on a result in your answer, cite its source URL so the user can verify it."`                                               |

`preview = query.size > 40 ? "#{query[0..39]}…" : query` (для `description`
в `resolveExecution`).

---

## 3. Валидация

Тул сам не валидирует — передаёт `query` как есть в провайдер. Провайдер
тоже не валидирует. Любые ошибки классифицируются через
`classify_search_error` (см. §6.3).

---

## 4. `WebSearchProvider` contract

```crystal
struct WebSearchResult
  property title : String
  property url : String
  property snippet : String
  property date : String?       # nil если пустой
  property site_name : String?  # nil если пустой
end

abstract class WebSearchProvider
  abstract def search(query : String, tool_call_id : String? = nil,
                      signal : AbortController? = nil) : Array(WebSearchResult)
end
```

Опциональные поля добавляются только если непустые.

---

## 5. Вывод — формат ToolResult

`builder = ToolResultBuilder.new(max_line_length: nil)`.

### 5.1. Пустой список

`builder.write(NO_RESULTS_MESSAGE); builder.ok()` → `"No search results found."`.

### 5.2. Непустой список

Для каждого результата (между ними разделитель `"---\n\n"`, перед первым
разделителя нет):

```
Title: <title>
[Site: <site_name>        ← только если site_name непустой]
[Date: <date>             ← только если date непустой]
URL: <url>
Snippet: <snippet>
<blank line>
```

После всех результатов — финальный CITE_REMINDER (без дополнительного
разделителя).

Пример для двух результатов без site/date:

```
Title: <t1>
URL: <u1>
Snippet: <s1>

---
Title: <t2>
URL: <u2>
Snippet: <s2>

When you rely on a result in your answer, cite its source URL so the user can verify it.
```

`ToolResultBuilder` применяет общий char-бюджет `MAX_CHARS` + транкацию
через `TRUNCATION_MARKER` + `TRUNCATION_MESSAGE`.

### 5.3. Ошибки — `classify_search_error(error)`

Приоритет (после проверки `signal.aborted? → raise`):

1. `error.name == "AbortError"` ИЛИ message `includes("abort")` →
   `"Search cancelled: #{message}"`.
2. `error.name == "TimeoutError"` ИЛИ message `includes("timed out")` /
   `includes("timeout")` → `"Search timed out: #{message}"`.
3. message `includes("401")` / `includes("unauthorized")` /
   `includes("auth")` → `"Search failed (authentication): #{message}"`.
4. message `includes("http ")` / `includes("network")` /
   `includes("fetch")` ИЛИ `error.name == "TypeError"` →
   `"Search failed (network): #{message}"`.
5. fallback → `"Search failed: #{message}"`.

`message = ex.message || ex.to_s`. `name = ex.class.name`.

---

## 6. `IWebSearchProviderService` — абстракция

```crystal
abstract class WebSearchProviderService
  abstract def get_web_search_provider : WebSearchProvider?
end

class ConfigWebSearchService < WebSearchProviderService
  # Из [services.moonshot_search] TOML секции.
  def initialize(@config : Config)
    @search = @config.services.try(&.moonshot_search)
  end

  def get_web_search_provider : WebSearchProvider?
    return nil if @search.nil? || (base_url = @search.base_url).nil?
    MoonshotWebSearchProvider.new(
      base_url: base_url,
      token_provider: oauth_token_provider(@search.oauth),
      api_key: non_empty(@search.api_key),
      default_headers: host_headers,
      custom_headers: @search.custom_headers,
    )
  end
end

class ManagedWebSearchService < WebSearchProviderService
  def initialize(@provider : Provider, @oauth : OAuth, @host_headers : Hash(String, String))
  end

  def get_web_search_provider : WebSearchProvider?
    return nil unless @provider.type == "moonshot" && (oauth = @provider.oauth)
    token_provider = @oauth.resolve_token_provider("managed:kimi-code", oauth)
    return nil unless token_provider
    base_url = (@provider.base_url || MOONSHOT_CODE_BASE_URL).rstrip("/") + "/search"
    MoonshotWebSearchProvider.new(base_url, token_provider, nil, @host_headers, @provider.custom_headers)
  end
end

class CompositeWebSearchService < WebSearchProviderService
  def initialize(@config_service, @managed_service)
  end

  def get_web_search_provider : WebSearchProvider?
    @config_service.get_web_search_provider || @managed_service.get_web_search_provider
  end
end

class WebSearch < Tool
  @@service : WebSearchProviderService?  # nil → тул не регистрируется
  def self.service=(s); @@service = s end
end
```

`non_empty(s)`: трим; вернуть `nil` если пустой.

---

## 7. MoonshotWebSearchProvider — HTTP-запрос

Конструктор: `MoonshotWebSearchProvider.new(base_url, token_provider, api_key, default_headers, custom_headers)`.

`search(query, tool_call_id, signal)`:

1. `body = { text_query: query }; body_json = body.to_json` →
   `{"text_query":"<query>"}`.
2. `response = post(body_json, tool_call_id, signal)`.
3. **401 special-case**: `detail = safe_read_text(response)` → throw
   `Error("Moonshot search request failed: HTTP 401 (auth/unauthorized). #{detail}".strip)`.
4. Любой другой `status != 200`: throw
   `Error("Moonshot search request failed: HTTP #{status}. #{detail}".strip)`.
5. `200`: `json = response.body` → parse; `raw = json["search_results"]? || []`.

`post`:

- Метод: `POST`.
- URL: `base_url` (с уже добавленным `/search`), без query.
- Headers (порядок важен):
  1. `default_headers` (host identity).
  2. `Authorization: Bearer <access_token>`.
  3. `Content-Type: application/json`.
  4. `X-Msh-Tool-Call-Id: <tool_call_id>` (если непустой).
  5. `custom_headers`.
- Body: `body_json`.
- Signal: пробрасывается.

**Замечание:** в отличие от fetch, нет `Accept` header.

`resolve_api_key`:

1. Если `token_provider` есть → `return token_provider.get_access_token`.
   Если throws и `api_key` непустой → `api_key`, иначе re-raise.
2. Иначе если `api_key` непустой → `api_key`.
3. Иначе throw
   `Error("Moonshot search service is not configured: missing API key or token provider.")`.

---

## 8. Маппинг ответа → `WebSearchResult`

JSON wire-формат:

```ts
interface MoonshotSearchResult {
  site_name?: string;
  title?: string;
  url?: string;
  snippet?: string;
  content?: string;
  date?: string;
  icon?: string;
  mime?: string;
}
interface MoonshotSearchResponse { search_results?: MoonshotSearchResult[]; }
```

Маппинг (для каждой записи, пропущенные поля → `""`):

- `title = raw["title"]? || ""`.
- `url = raw["url"]? || ""`.
- `snippet = raw["snippet"]? || ""`.
- `date = raw["date"]?` если `String` и непустой.
- `site_name = raw["site_name"]?` если `String` и непустой.

`content`, `icon`, `mime` парсятся интерфейсом, но **игнорируются**.
`search_results` отсутствует/non-array → `[]`.

---

## 9. Конфигурация и env

WebSearch конфигурируется двумя источниками (конфиг выигрывает):

**(1) `[services.moonshot_search]` TOML**:

```toml
[services.moonshot_search]
base_url = "..."            # string? — REQUIRED для активации секции
api_key = "..."             # string? — трим; пустой → nil
oauth = { storage = "file"|"keyring", key = "...", oauth_host = "..." }
custom_headers = { "X-Foo" = "bar" }
```

TOML-ключи `snake_case`. Секция без `base_url` игнорируется.

**(2) Managed `managed:kimi-code` OAuth**:

- Производная от provider с `type: "moonshot"` и `oauth` ref.
- `base_url = (provider.base_url || MOONSHOT_CODE_BASE_URL).rstrip("/") + "/search"`.

Env: `MOONSHOT_CODE_BASE_URL` (по умолчанию `"https://api.kimi.com/coding/v1"`).

---

## 10. Approval / accesses / plan-mode / регистрация

- `accesses: ToolAccesses.none()` — нет resource access.
- `approvalRule: literalRulePattern("WebSearch", query)` → `"WebSearch(\"#{query}\")"`.
- **Plan mode**: входит в read-only whitelist.
- **Auto-approve**: в `DEFAULT_APPROVE_TOOLS` → добавить в Crystal
  `auto_approve?`.
- **Условная регистрация**: тул НЕ регистрируется в `Tools::Registry`, если
  `WebSearchProviderService.get_web_search_provider.nil?`. Реализуется
  проверкой перед `tools.register(WebSearch.new(...))` в `src/h2code.cr`.

---

## 11. План реализации (чек-лист)

- [ ] Прочитать JS: `web-search.ts`, `web-search.md`, `webSearch.ts`,
      `webSearchService.ts`, `providers/moonshot-web-search.ts`,
      `app/auth/configSection.ts`.
- [x] Описать контракт в `md-tools/web-search.md`.
- [ ] Реализовать `WebSearchResult`, `WebSearchProvider`,
      `MoonshotWebSearchProvider`, `WebSearchProviderService`.
- [ ] Реализовать `Tools::WebSearch < Tool` в `src/tools/web_search.cr`:
  - [ ] Константы §2.
  - [ ] `name`, `description`, `parameters`.
  - [ ] `execute(input)`:
    1. `query = input["query"].to_s`.
    2. `provider = @@service.not_nil!.get_web_search_provider.not_nil!`.
    3. `results = provider.search(query, tool_call_id, abort_controller)`.
    4. `format_results(results)` или `format_empty`.
    5. rescue: `classify_search_error` → `ToolResult.error`.
  - [ ] Хелперы: `format_results`, `format_empty`, `classify_search_error`,
        `truncate_to_budget`.
- [ ] В `src/h2code.cr`:
  - [ ] Инициализация `WebSearch.service = CompositeWebSearchService.new(...)`.
  - [ ] Условная регистрация только если provider доступен.
- [ ] Тесты в `spec/tools/web_search_spec.cr`:
  - [ ] Непустой список — формат §5.2 (с и без site/date).
  - [ ] Пустой список — `NO_RESULTS_MESSAGE`.
  - [ ] 401 → `"Search failed (authentication): ..."`.
  - [ ] Network error → `"Search failed (network): ..."`.
  - [ ] Truncation > 50 000 char.
  - [ ] `search_results` отсутствует → `[]` → `NO_RESULTS_MESSAGE`.
- [ ] Обновить `FIX-TOOLS.md`: отметить строку #5 выполненной.

---

## 12. Расхождения / допущения

- `MoonshotWebSearchProvider` требует наличия API-key или OAuth-token. Пока
  в `h2code.cr` нет OAuth, реализовать только API-key path через
  `[services.moonshot_search].api_key`. Без него тул не регистрируется.
- `MoonshotSearchResult.content`/`icon`/`mime` игнорируются (как в JS).
- `ToolResultBuilder` — упростить до ручной транкации по `MAX_CHARS` с
  теми же `TRUNCATION_MARKER`/`TRUNCATION_MESSAGE` семантиками.
- `signal` (abort) — пока только pre-check `signal.aborted?` перед запросом;
  сам HTTP-запрос обрывается по `HTTP::Client#dns_timeout`/`read_timeout`.
