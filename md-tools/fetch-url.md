# FetchURL — план портирования из JS в Crystal

> Источник: `packages/agent-core-v2/src/app/web/tools/fetch-url.ts`
> + `fetch-url-types.ts`, `fetch-url.md`, `web.ts`, `webService.ts`,
>   `providers/local-fetch-url.ts`, `providers/moonshot-fetch-url.ts`.

Цель — тул `FetchURL` в `kimi.cr/src/tools/fetch_url.cr` с идентичным
LLM-контрактом. HTTP-фечинг — через инжекченный `UrlFetcher`; есть две
реализации: `LocalFetcher` (HTTP::Client + простая HTML-очистка) и
`MoonshotFetcher` (через managed-OAuth `/fetch` endpoint).

---

## 1. Контракт тула

| Поле           | JS (`FetchURLTool`)                                  | Crystal (`Tools::FetchURL`)                            |
|----------------|------------------------------------------------------|---------------------------------------------------------|
| `name`         | `'FetchURL' as const`                                | `"FetchURL"`                                            |
| `description`  | импорт из `fetch-url.md?raw`                         | Константа `DESCRIPTION` (verbatim §1.2)                 |
| `parameters`   | `toInputJsonSchema(z.object({ url: z.string() }))`   | Эквивалентная JSON Schema через `JSON.parse`            |
| `execute`      | `resolveExecution(args).execute(ctx)`                | `execute(input : JSON::Any) : ToolResult`               |

### 1.1. `name`

`"FetchURL"`.

### 1.2. `description` (verbatim)

```
Fetch content from a URL. The content is returned either as the main text extracted from the page, or as the full response body verbatim; a note at the top of the result states which of the two you received, so you can judge how complete it is. Use this when you need to read a specific web page.

Only fully-formed public `http`/`https` URLs are supported; other schemes and private or loopback addresses are not fetched. Very large pages may be truncated or refused. The fetch carries no login or session for the target site, so pages behind authentication (private repositories, internal dashboards) return a login page or an error instead of the real content — if the text you get back looks like a generic landing or sign-in page, treat that as the login wall, not the answer, and reach the content through a credentialed route (an authenticated CLI or MCP tool) instead.
```

### 1.3. `parameters` — JSON Schema

```json
{
  "type": "object",
  "properties": {
    "url": {
      "type": "string",
      "description": "The URL to fetch content from."
    }
  },
  "required": ["url"],
  "additionalProperties": false
}
```

Одно свойство `url` — string, **required**, без default/enum/constraints.

---

## 2. Константы

| Имя                       | Значение                                                                                                                                                                                                 |
|---------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `DEFAULT_USER_AGENT`      | `"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"`                                                                                   |
| `DEFAULT_MAX_BYTES`       | `10 * 1024 * 1024` (10 MiB)                                                                                                                                                                               |
| `MAX_CHARS`               | `50_000` (общий бюджет на результат; см. `ToolResultBuilder`)                                                                                                                                              |
| `TRUNCATION_MARKER`       | `"[...truncated]"`                                                                                                                                                                                        |
| `TRUNCATION_MESSAGE`      | `"Output is truncated to fit in the message."`                                                                                                                                                            |
| `NOTE_PASSTHROUGH`        | `"The returned content is the full response body, returned verbatim."`                                                                                                                                    |
| `NOTE_EXTRACTED`          | `"The returned content is the main text extracted from the page."`                                                                                                                                        |
| `CITE_REMINDER`           | `"If you use it in your answer, cite this page as a markdown link, e.g. [title](url)."`                                                                                                                   |

`ToolResultBuilder` создаётся с `max_line_length: nil` (построчная
транкация отключена, работает только общий char-бюджет).

---

## 3. Валидация — все ветки

Тул не валидирует URL сам — делегирует `UrlFetcher`. В Crystal повторяем
логику `assert_safe_fetch_target(url, allow_private)`:

1. `URI.parse(url)` throws → `Error("Invalid URL: \"#{url}\"")`.
2. Схема не `http`/`https` → `Error("Unsupported URL scheme \"#{scheme}\" — only http(s) allowed.")`.
3. Если `allow_private == true` — пропустить проверки адресов.
4. Hostname lowercase; IPv6 `[...]` → strip brackets.
5. `host == "localhost"` или заканчивается на `".localhost"` → `Error("Refusing to fetch private host: \"#{host}\"")`.
6. IPv6 `::1`, `::`, `fe80:*` (link-local), `fc*`/`fd*` (ULA) → same.
7. IPv4 octets: каждый 0–255 иначе `Error("Invalid IPv4 literal: \"#{host}\"")`.
8. IPv4 private ranges → `Error("Refusing to fetch private address: \"#{host}\"")`:
   - `127.0.0.0/8`, `10.0.0.0/8`, `192.168.0.0/16`, `172.16.0.0/12`,
     `169.254.0.0/16`, `0.0.0.0/8`, `100.64.0.0/10` (CGNAT).
9. `Content-Length > DEFAULT_MAX_BYTES` → `Error("Response body too large: #{cl} bytes exceeds maxBytes (#{max}).")`.
10. После `response.body` реальный `bytesize > DEFAULT_MAX_BYTES` → same с актуальным byte count.
11. `response.status >= 400` → throw `HttpFetchError.new(status, "HTTP #{status} #{status_message}")`.

---

## 4. `UrlFetcher` contract

```crystal
enum UrlFetchKind
  Passthrough  # тело уже plain text/markdown, вернули как есть
  Extracted    # тело было HTML, извлекли главный текст
end

struct UrlFetchResult
  property content : String
  property kind : UrlFetchKind
end

class HttpFetchError < Exception
  property status : Int32
end

abstract class UrlFetcher
  abstract def fetch(url : String, tool_call_id : String? = nil,
                     signal : AbortController? = nil) : UrlFetchResult
end
```

---

## 5. HTML → text (`LocalFetcher.extract_main_content`)

Алгоритм (JS использует `@mozilla/readability` + `linkedom`):

1. `Content-Type` (lowercase) начинается с `"text/plain"` ИЛИ `"text/markdown"`
   → `{ content: body, kind: :passthrough }`. Без экстракции.
2. Иначе → extract:
   - Парсинг HTML.
   - Извлечение главного текста (см. ниже).
   - Если `title` непустой → `"# #{title}\n\n#{text}"`.
   - Иначе → `text`.
   - Если экстракция ничего не дала — fallback: `<title>`, затем
     `<article>` / `<main>` / `<body>` textContent. Если пусто → throw
     `Error("Failed to extract meaningful content from the page. The page may require JavaScript to render.")`.
   - `kind: :extracted`.

Crystal не имеет готового `readability`. Приближение:

- Удалить `<script>`, `<style>`, `<noscript>`, `<template>`, `<head>` (кроме `<title>`).
- Парсить примитивно (regex или легковесной библиотекой типа `crystal-html`).
- Из `<body>` извлечь текстовый контент, схлопнув whitespace.
- Заголовок — из `<title>`.
- Это даёт менее чистый результат, чем Readability, но сохраняет основной
  контракт (`kind: :extracted`, заголовок H1).

---

## 6. Вывод — формат ToolResult

`builder = ToolResultBuilder.new(max_line_length: nil)`. Все строки — plain
text (без XML-обёрток).

### 6.1. Пустой body

```crystal
{ output: "The response body is empty.", isError: false }
```

### 6.2. Успех

Один `builder.write(...)` со склеенной строкой:

```
<note> <citeReminder>\n\n<content>
```

Где:
- `note` = `NOTE_PASSTHROUGH` для `kind == :passthrough`, иначе `NOTE_EXTRACTED`.
- `citeReminder` = `CITE_REMINDER`.
- `content` — извлечённый текст.

`builder.ok()` добавляет `". "` к непустому сообщению без точки на конце, и
при truncation — `" " + TRUNCATION_MESSAGE`. Результат также помечается
`truncated: true`.

### 6.3. Ошибки

- `signal.aborted? → raise` (обрабатывается выше).
- `ex : HttpFetchError`:
  `{ isError: true, output: "Failed to fetch URL. Status: #{ex.status}. #{ex.message}" }`.
- Любая другая ошибка:
  `{ isError: true, output: "Failed to fetch URL due to network error: #{url}. #{ex.message || ex.to_s}" }`.

---

## 7. Service abstraction — `IWebFetchService`

```crystal
abstract class WebFetchService
  abstract def get_url_fetcher : UrlFetcher
end

class LocalWebFetchService < WebFetchService
  # Всегда local fetcher (для TUI без OAuth).
end

class ManagedWebFetchService < WebFetchService
  # Managed:kimi-code OAuth + fallback на local при ошибке.
  def initialize(@provider : Provider, @oauth : OAuth, @host_headers : Hash(String, String))
    @local = LocalFetcher.new
  end

  def get_url_fetcher : UrlFetcher
    return @local unless @provider.type == "kimi" && (oauth = @provider.oauth)
    token_provider = @oauth.resolve_token_provider("managed:kimi-code", oauth)
    return @local unless token_provider
    base_url = (@provider.base_url || KIMI_CODE_BASE_URL).rstrip("/") + "/fetch"
    MoonshotFetcher.new(base_url, token_provider, @host_headers, @provider.custom_headers, @local)
  end
end

class FetchURL < Tool
  @@service : WebFetchService = LocalWebFetchService.new
  def self.service=(s); @@service = s end
end
```

---

## 8. MoonshotFetcher — HTTP-запрос

Конструктор: `MoonshotFetcher.new(base_url, token_provider, default_headers, custom_headers, local_fallback)`.

`fetch(url, tool_call_id, signal)`:

1. Вызывает `fetch_via_moonshot(url, tool_call_id, signal)` в `begin/rescue`.
2. На любой ошибке, если `signal.try(&.aborted?)` → re-raise.
3. Иначе — делегировать `local_fallback.fetch(url, tool_call_id, signal)`.
4. На успехе всегда возвращать `kind: :extracted` (бэкенд уже вернул
   markdown/text).

`fetch_via_moonshot`:

- `body_json = { url: url }.to_json`.
- `response = post(body_json, tool_call_id, signal)`.
- `response.status != 200` → throw `HttpFetchError.new(status, "Moonshot fetch request failed: HTTP #{status}. #{detail}".strip)`.
- `200` → `response.body` как есть.

`post`:

- Метод: `POST`.
- URL: `base_url` (с уже добавленным `/fetch`), без query.
- Headers (порядок важен — последний выигрывает):
  1. `default_headers` (host identity).
  2. `Authorization: Bearer <access_token>`.
  3. `Accept: text/markdown`.
  4. `Content-Type: application/json`.
  5. `X-Msh-Tool-Call-Id: <tool_call_id>` (если непустой).
  6. `custom_headers` (последний).
- Body: `body_json`.
- Signal: пробрасывается.

`resolve_api_key`:

1. Если `token_provider` есть → `token = token_provider.get_access_token`.
   Если `token.strip.size > 0` → вернуть. Иначе если `api_key` непустой →
   вернуть его. Если `get_access_token` throws и `api_key` непустой →
   вернуть его, иначе re-raise.
2. Иначе если `api_key` непустой → вернуть.
3. Иначе throw `Error("Moonshot fetch service is not configured: missing API key or token provider.")`.

---

## 9. Approval / accesses / plan-mode

- `accesses: ToolAccesses.none()` — нет resource access.
- `approvalRule: literalRulePattern("FetchURL", url)` → в Crystal правило
  `"FetchURL(\"#{url}\")"` (subject escape: backslash перед glob-meta chars).
- `matchesRule: matchesGlobRuleSubject(ruleArgs, url)` — picomatch по url.
- **Plan mode**: входит в read-only whitelist для `plan` и `explore` профилей.
- **Auto-approve**: входит в `DEFAULT_APPROVE_TOOLS`. В Crystal — добавить
  `"FetchURL"` в `Permission::Manager#auto_approve?`.

---

## 10. Env / config

Сам тул не читает env. Влияют:

- `KIMI_CODE_BASE_URL` (по умолчанию `"https://api.kimi.com/coding/v1"`,
  обрезанные trailing slashes) — fallback для provider base URL.
- Константа `KIMI_CODE_PROVIDER_NAME = "managed:kimi-code"` (не env).

`[services.moonshot_fetch]` TOML-секция в JS парсится, но не используется
`WebFetchService` (только managed OAuth).

---

## 11. План реализации (чек-лист)

- [ ] Прочитать JS: `fetch-url.ts`, `fetch-url-types.ts`, `fetch-url.md`,
      `web.ts`, `webService.ts`, `providers/local-fetch-url.ts`,
      `providers/moonshot-fetch-url.ts`.
- [x] Описать контракт в `md-tools/fetch-url.md`.
- [ ] Реализовать `Tools::FetchURL < Tool` в `src/tools/fetch_url.cr`:
  - [ ] Константы §2.
  - [ ] `name`, `description`, `parameters`.
  - [ ] `execute(input)`:
    1. `url = input["url"].to_s`.
    2. `fetcher = @@service.get_url_fetcher`.
    3. `result = fetcher.fetch(url, tool_call_id, abort_controller)` в rescue.
    4. На успехе — `format_success(result)`.
    5. На `HttpFetchError` — `format_http_error`.
    6. На abort — проброс.
    7. На прочее — `format_network_error`.
  - [ ] Хелперы: `format_success`, `format_http_error`, `format_network_error`,
        `truncate_to_budget` (50 000 char cap).
- [ ] Реализовать `LocalFetcher < UrlFetcher`:
  - [ ] `assert_safe_fetch_target`.
  - [ ] `HTTP::Client` с `DEFAULT_MAX_BYTES` cap.
  - [ ] `extract_main_content` (упрощённый: strip scripts/styles + body
        textContent + title H1; passthrough для `text/plain`/`text/markdown`).
- [ ] Реализовать `MoonshotFetcher < UrlFetcher` (опционально — когда есть
      OAuth).
- [ ] Реализовать `LocalWebFetchService`/`ManagedWebFetchService`.
- [ ] Зарегистрировать тул в `Tools::Registry`.
- [ ] Тесты в `spec/tools/fetch_url_spec.cr`:
  - [ ] Passthrough (`text/plain`) — формат §6.2.
  - [ ] Extracted (HTML) — формат §6.2.
  - [ ] Пустой body — `"The response body is empty."`.
  - [ ] HTTP 404 — `HttpFetchError` формат.
  - [ ] Private host (localhost / 127.0.0.1) → rejected.
  - [ ] Truncation > 50 000 char → `[...truncated]` + `TRUNCATION_MESSAGE`.
  - [ ] Content-Length > 10 MiB → rejected до загрузки.
- [ ] Обновить `FIX-TOOLS.md`: отметить строку #4 выполненной.

---

## 12. Расхождения / допущения

- `@mozilla/readability` недоступен в Crystal. Делаем simpler extract: strip
  scripts/styles, body textContent с нормализацией whitespace, заголовок из
  `<title>`. Это приемлемо для большинства публичных страниц.
- `linkedom` недоступен — легковесный regex-парсер или внешняя зависимость
  (`myhtml` или `crystal-html`).
- `signal` пробрасывается в `HTTP::Client` через Fiber.cancel + ручной
  timeout. В Crystal нет нативного AbortSignal для HTTP-запроса; используем
  `HTTP::Client#read_timeout` + проверку `signal.aborted?` перед запросом.
- `custom_headers` provider'а — пока захардкодить пустой `Hash(String,String)`;
  подключение к `[providers]` TOML секции — отдельная задача.
- Token provider для managed OAuth — пока заглушка; пока нет OAuth в
  `kimi.cr`, `WebFetchService` остаётся local-only. Контракт тула от этого
  не меняется.
