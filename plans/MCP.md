# MCP (Model Context Protocol) — план реализации для Crystal-версии

> **Статус: все фазы реализованы и приведены в соответствие с JS-версией.**
> Код в `src/mcp/`, тесты в `spec/mcp/mcp_spec.cr` (40 примеров), полный
> suite зелёный (1063 примера).
>
> | Фаза | Компоненты | Статус |
> |---|---|---|
> | 1 — stdio MVP | JSON-RPC, stdio-транспорт, handshake, proxy tools, config | ✅ |
> | 2 — HTTP | Streamable HTTP + SSE, bearer token, proxy | ✅ |
> | 3 — Медиа | image/audio/resource → base64 data URI | ✅ |
> | 4 — OAuth | RFC 9728/8414 discovery, RFC 7591 DCR, PKCE, callback, tokens | ✅ |
> | JS-parity | enabled/disabled tools, enabled flag, timeouts, unexpected close, needs-auth + synthetic auth tool, output budget/cap, multi-source config | ✅ |
> | JS-parity fixes | image compression (ImageProcessor), dynamic callback port, OAuth store key+atomic write+0600, legacy toolResult shape | ✅ |

## Контекст

MCP — открытый протокол (JSON-RPC 2.0), стандартизирующий подключение внешних
инструментов и источников данных к LLM-агенту. В JS-версии (`kimi-code`) уже
реализован поверх официального SDK `@modelcontextprotocol/sdk` (~3000 строк
обёрток в `packages/agent-core/src/mcp/`). В Crystal SDK нет — wire-протокол
нужно реализовать напрямую, но его поверхность мала: 4 метода (`initialize`,
`notifications/initialized`, `tools/list`, `tools/call`).

Архитектура Crystal **идеально подходит** для MCP — интерфейс `Tool`, реестр,
диспетчеризация и сериализация спроектированы так, что реализация инструмента
непрозрачна для цикла агента. Основная работа — транспортный слой (JSON-RPC
поверх stdio), а не интеграция в систему инструментов.

## Wire-протокол

MCP — JSON-RPC 2.0. Каждое сообщение — JSON-объект с `jsonrpc: "2.0"`.

### Типы сообщений

**Request** (клиент → сервер):
```json
{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {...}}
```

**Response** (сервер → клиент):
```json
{"jsonrpc": "2.0", "id": 1, "result": {...}}
```

**Notification** (в любую сторону, без `id`):
```json
{"jsonrpc": "2.0", "method": "notifications/initialized"}
```

### Фрейминг по транспортам

| Транспорт | Wire-формат | Разделитель сообщений |
|---|---|---|
| **stdio** | Newline-delimited JSON через stdin/stdout дочернего процесса | Один JSON-RPC = одна строка (`\n`) |
| **Streamable HTTP** | HTTP POST для запросов, SSE-stream для ответов | `Content-Type: application/json` (inline) или `text/event-stream` |
| **HTTP+SSE** (deprecated) | GET для открытия SSE-потока, POST для запросов | — |

### Методы протокола (всё, что нужно реализовать)

1. **`initialize`** (request) — handshake:
   ```json
   {"jsonrpc":"2.0","id":1,"method":"initialize","params":{
     "protocolVersion":"2025-06-18",
     "capabilities":{},
     "clientInfo":{"name":"hcode","version":"X.Y.Z"}
   }}
   ```
2. **`notifications/initialized`** (notification) — сразу после `initialize`.
3. **`tools/list`** (request) — обнаружение инструментов. Возвращает:
   ```json
   {"tools":[{"name":"...","description":"...","inputSchema":{...jsonSchema...}}]}
   ```
4. **`tools/call`** (request) — вызов инструмента:
   ```json
   {"jsonrpc":"2.0","id":N,"method":"tools/call","params":{
     "name":"tool_name",
     "arguments":{...}
   }}
   ```
   Возвращает `{content: ContentBlock[], isError: boolean}`.

Сервер также может слать `notifications/tools/list_changed` — можно игнорировать
в MVP.

### Типы content blocks (из `tools/call`)

- `text` — `{type:"text", text:"..."}`
- `image` — `{type:"image", data:"<base64>", mimeType:"image/png"}`
- `audio` — `{type:"audio", data:"<base64>", mimeType:"audio/mpeg"}`
- `resource` (EmbeddedResource) — `{type:"resource", resource:{uri, mimeType, text|blob}}`
- `resource_link` — `{type:"resource_link", uri, mimeType}`

## Точки интеграции в существующем коде

5 из 7 точек требуют **нулевых изменений**.

| Где | Что | Сложность |
|---|---|---|
| `src/hcode.cr:256-283` | Запуск MCP-серверов после регистрации встроенных инструментов | Низкая |
| `src/tools/registry.cr` | `registry.register(McpProxyTool.new(...))` — без изменений в реестре | Нулевая |
| `src/tools/tool.cr:3-14` | `McpProxyTool < Tool` — реализует 4 абстрактных метода | Низкая |
| `src/loop/tool_batch.cr:85,161` | Диспетчеризация — без изменений, прокси-инструмент проходит тот же путь | Нулевая |
| `src/llm/types.cr:77-100` | Сериализация — `parameters : JSON::Any` проходит как есть | Нулевая |
| `src/config/config.cr` | Секция `[[mcp_servers]]` по аналогии с `[[hooks]]` (`:305-349`) | Низкая |
| `src/permission/manager.cr` | Разрешения — проходит автоматически по имени `mcp__server__tool` | Нулевая |

### Интерфейс Tool (существующий)

`src/tools/tool.cr:3-14`:

```crystal
abstract class Tool
  abstract def name : String
  abstract def description : String
  abstract def parameters : JSON::Any
  abstract def execute(input : JSON::Any) : ToolResult
end
```

`ToolResult` (строки 33–49): `content : String`, `is_error`, `truncated?`,
опциональный `display : ToolDisplay?`.

MCP-инструмент — это `Tool`, у которого `parameters` приходит из
`tools/list`, а `execute` делает `tools/call` JSON-RPC round-trip.

### Реестр

`src/tools/registry.cr:3-37`:

```crystal
class Registry
  @tools : Hash(String, Tool) = {} of String => Tool
  def register(tool : Tool) : Nil          # ключ — tool.name
  def get(name : String) : Tool?           # lookup по имени
  def definitions : Array(LLM::ToolDefinition)
end
```

Регистрация встроенных инструментов — в `src/hcode.cr:256-283`. Естественная
точка инъекции MCP: после встроенных, итерировать `config.mcp_servers`,
подключать каждый, вызвать `tools/list`, и `tools.register(McpProxyTool.new(...))`
для каждого удалённого инструмента.

### Путь диспетчеризации

1. LLM возвращает tool calls → `execute_step` (`src/loop/agent.cr:265-351`).
2. `run_tool_batch` (`agent.cr:353`) → `ToolBatch#run(tool_calls)`.
3. Lookup: `tool = @registry.get(tc.name)` (`tool_batch.cr:85`).
4. Permission + dedup + hooks (`tool_batch.cr:94-139`).
5. Параллельное выполнение: `spawn` в fiber (`tool_batch.cr:62`), вызов
   `tool.execute(input)` (строка 161), где `input = JSON.parse(tc.arguments)`.
6. `assemble_results` (`tool_batch.cr:189`) — сборка в порядке.

Прокси-инструмент проходит весь этот путь без изменений.

### Последовательность запуска

`src/hcode.cr:153-347` (`CLI.run`):

1. Парсинг аргументов (166–202).
2. `Config::Config.load` (214) — `~/.hcode/config.toml` + env.
3. Создание провайдера (246).
4. **Создание реестра инструментов (256–283)** — ← здесь подключаются MCP-серверы.
5. `Loop::Agent.new(provider, memory, tools, permission)` (322).
6. Ветвление `run_headless` / `run_interactive` (343–347).

MCP-серверы спавнятся между строками 283 и 322. Жизненный цикл соединений
владелец — `CLI` (или `Mcp::Manager`), уничтожение при выходе процесса или
пересоздании агента.

### Доступные Crystal-библиотеки

- `HTTP::Client` — используется в `src/llm/http_transport.cr`. Достаточно для HTTP-транспорта.
- `JSON` + `JSON::Serializable` — везде.
- `Process.new(..., input: Process::Redirect::Pipe, output: ..., error: ...)` —
  используется в `src/tools/bash.cr:105-113`. 1:1 матч для stdio-транспорта.
- `Channel` / `spawn` / `Fiber` — для асинхронной JSON-RPC мультиплексации.
- `toml` shard (0.8.1) — есть в `shard.yml`, но основной конфиг-парсер bespoke.
- JSON-RPC библиотеки **нет** — нужно написать (~150-200 строк поверх stdlib).

## Фазы реализации

### Фаза 1 — MVP (stdio, text-only)

**~1 200–1 400 строк**

| Компонент | LOC | Описание |
|---|---|---|
| JSON-RPC 2.0 клиент | ~200 | Конверт `jsonrpc:"2.0"`, `id`, `method`, `params`. Асинхронная диспетчеризация через `Channel` |
| stdio-транспорт | ~200 | `Process.new(command, args, input/output: Pipe)`. Newline-delimited JSON. Сбор stderr в bounded-буфер |
| Protocol handshake | ~100 | `initialize` + `notifications/initialized` + `tools/list` + `tools/call` |
| Типы MCP | ~50 | `MCPToolDefinition`, `MCPToolResult`, `MCPContentBlock` — аналог `types.ts` |
| Connection manager | ~200 | Параллельное подключение, изоляция ошибок по серверам, таймаут 30с, status tracking |
| Имена инструментов | ~50 | `mcp__<server>__<tool>`, санитизация, FNV-1a хэш для truncation |
| Конвертация результата | ~50 | text-only: `MCPContentBlock` → `ToolResult.content : String` |
| Загрузка конфига | ~100 | Парсинг секции `[[mcp_servers]]` в `config.toml` (по аналогии с `[[hooks]]`) или `mcp.json` |
| Прокси-инструмент | ~100 | `McpProxyTool < Tool` — реализует `name`, `description`, `parameters`, `execute` |
| Интеграция в startup | ~100 | Запуск серверов между `registry` и `Agent.new` в `hcode.cr:283→322` |
| Shutdown/cleanup | ~50 | `Process#kill` при выходе, hook в `Signal::INT.trap` |

**Покрывает:** подключение любого stdio MCP-сервера
(`npx @modelcontextprotocol/server-*`), обнаружение и вызов инструментов,
корректное завершение.

**Не покрывает:** HTTP-серверы, OAuth, изображения/медиа.

#### Структура файлов

```
src/mcp/
  jsonrpc.cr           # JSON-RPC 2.0 клиент (envelope, id correlation, dispatch)
  transport.cr         # абстрактный транспорт + stdio-реализация
  client.cr            # MCP-клиент: initialize, tools/list, tools/call
  types.cr             # MCPToolDefinition, MCPToolResult, MCPContentBlock
  manager.cr           # connection manager: connect, disconnect, status
  tool_naming.cr       # mcp__<server>__<tool>, sanitize, FNV-1a hash
  proxy_tool.cr        # McpProxyTool < Tool
  config.cr            # McpServerConfig, парсинг конфига
```

#### Конфиг

Секция в `config.toml`:

```toml
[[mcp_servers]]
name = "github"
command = "npx"
args = ["-y", "@modelcontextprotocol/server-github"]
env = { GITHUB_TOKEN = "ghp_..." }

[[mcp_servers]]
name = "postgres"
command = "npx"
args = ["-y", "@modelcontextprotocol/server-postgres", "postgresql://localhost/mydb"]
```

Или файл `~/.hcode/mcp.json` (формат как в JS):

```json
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": { "GITHUB_TOKEN": "ghp_..." }
    }
  }
}
```

### Фаза 2 — HTTP-транспорт

**+400 строк**

| Компонент | LOC | Описание |
|---|---|---|
| Streamable HTTP клиент | ~250 | POST JSON-RPC, разбор inline-ответа или SSE-stream (`text/event-stream`) |
| SSE-парсер | ~100 | Чтение `data:` строк из chunked-ответа |
| Bearer token из env | ~50 | `ENV["MCP_<NAME>_TOKEN"]` |

Покроет большинство современных удалённых MCP-серверов с преднастроенным
токеном.

#### Конфиг для HTTP

```toml
[[mcp_servers]]
name = "remote"
type = "http"
url = "https://mcp.example.com/sse"
token_env = "MCP_REMOTE_TOKEN"
```

### Фаза 3 — Медиа-результаты

**+200–300 строк**

Конвертация `image`/`audio` content blocks в base64 data URIs. Сейчас
`ToolResult.content : String`, поэтому изображения потребуют расширения типа
(либо data URI в строке, либо добавления `ToolResult.media`).

### Фаза 4 — OAuth (опционально)

**+700 строк**

RFC 9728/8414/7591 discovery, DCR, PKCE, callback HTTP-сервер на localhost,
персистентность токенов. **Можно отложить** — bearer token из env покрывает
большинство сценариев.

## Что можно отложить или пропустить

| Фича | Усилие | Приоритет |
|---|---|---|
| HTTP-транспорт (Streamable HTTP) | Средний | Фаза 2 — многие серверы HTTP-only |
| SSE-транспорт (deprecated) | Средний | Низкий — legacy |
| OAuth flow | Очень высокий | Отложить — bearer token покрывает most use cases |
| Synthetic auth tool | Средний | Зависит от OAuth |
| Медиа (изображения/audio) | Высокий | Фаза 3 — text-only достаточно для старта |
| Progressive disclosure (select_tools) | Средний | Nice-to-have |
| Unexpected close detection | Средний | Важно для надёжности, но не day-1 |
| Global config CRUD | Низкий | Достаточно загрузки из файла |
| stderr capture | Низкий | Quality of life для отладки |
| Proxy env handling | Низкий | Crystal handles differently |

## Рекомендация

Начать с **Фазы 1** — это даёт работающий MCP уже через ~1 200 строк, и все
stdio-серверы из экосистемы становятся доступными. HTTP-транспорт (Фаза 2) —
следующий приоритет, OAuth и медиа можно отложить.
