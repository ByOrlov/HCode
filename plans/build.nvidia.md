# Интеграция build.nvidia.com (NVIDIA NIM) в H2code

## Контекст

NVIDIA build.nvidia.com (NIM API) — полностью OpenAI-совместимый эндпоинт:
- базовый URL `https://integrate.api.nvidia.com/v1`
- авторизация по ключу `nvapi-...` (`Authorization: Bearer ...`)
- стандартный Chat Completions + SSE-стриминг
- модели именуются как `vendor/model` (`meta/llama-3.3-70b-instruct`, `deepseek-ai/deepseek-r1`, …)
- `GET /models` работает из коробки

В H2code уже есть общий движок `OpenAIChatProvider` (транспорт, SSE-парсинг, накопление tool-call-ов).
Поэтому интеграция — это ещё один провайдер-наследник по образцу `ZaiProvider`, плюс улучшения
обработки 429, который у NIM ожидается часто из-за агрессивных лимитов.

## Что уже есть (429 уже обрабатывается)

- `openai_chat_provider.cr:477` поднимает `ApiError(status_code=429, retryable: true)` —
  `retryable_status?(429)` = true (`types.cr:740`).
- Петля агента ловит его в `agent.cr:317`, проверяет `retry_policy.retryable?(ex)` → true.
- `RetryPolicy.delay_for` — экспоненциальный backoff: 2с → 4с → 8с (степень двойки, кэп 30с),
  `max_retries=3` (`retry.cr:17`).
- Шлёт `Event.info("Retrying in #{delay}s... (#{ex.message})")` и `sleep`, затем повторяет шаг.

То есть класс-наследник NIM унаследует этот ретрай автоматически.

## Слабые места, которые стоит улучшить под NIM

1. **Не парсится `Retry-After`.** NIM (как и OpenAI) шлёт HTTP-заголовок `Retry-After` при 429.
   Сейчас backoff фиксирован (2/4/8с) и игнорирует его. В `openai_chat_provider.cr:474`
   читается только тело ответа, заголовки не сохраняются в `ApiError`.
2. **Сообщение не дружелюбное.** Сейчас: `Retrying in 2s... (Chat API error 429: ...)`.
   Нужно «Too many requests... Paused for a few seconds...» — различить 429 от прочих
   retryable-ошибок и выдать человеческий текст.
3. **`max_retries=3` захардкожен** (`agent.cr:275` → `RetryPolicy.new`). Для лимитного NIM
   может не хватить. Стоит сделать параметры настраиваемыми через `[retry]` секцию конфига.

## План правок

| Файл | Правка |
|---|---|
| `src/llm/nvidia_provider.cr` (новый) | Класс `NvidiaProvider < OpenAIChatProvider`, ~15 строк (по образцу `zai_provider.cr`): `DEFAULT_MODEL`, `DEFAULT_ENDPOINT = "https://integrate.api.nvidia.com/v1"`, `name = "nvidia"`, `token = @api_key`, `@thinking_wire = ThinkingWire::ReasoningEffort` для reasoning-моделей |
| `src/llm/provider.cr:74` | Добавить в `KNOWN_PROVIDERS`: `ProviderInfo.new("nvidia", "NVIDIA NIM (build.nvidia.com) — OpenAI-compatible")` |
| `src/llm/types.cr:732` | В `ApiError` добавить поле `retry_after : Int32?` + парсинг заголовка `Retry-After` |
| `src/llm/openai_chat_provider.cr:474` | Передать `response.headers["Retry-After"]?` в `ApiError` |
| `src/llm/openai_chat_provider.cr:201` | Аналогично для `fetch_models` (опционально) |
| `src/loop/retry.cr:25` | Учитывать `retry_after` из ошибки, если он есть (новый метод/перегрузка `delay_for`) |
| `src/loop/agent.cr:352` | Различить 429: при rate-limit — `Event.info("Too many requests... paused for #{delay}s")`, иначе текущий текст |
| `src/loop/agent.cr:275` | `RetryPolicy.new(max_retries: config.retry_max, base_delay: config.retry_base_delay, max_delay: config.retry_max_delay)` — сделать настраиваемым |
| `src/config/config.cr:12` | Поля `nvidia_api_key : String`, `nvidia_endpoint : String`, `nvidia_model : String` (рядом с zai) |
| `src/config/config.cr:137` | Парсинг TOML: кейсы `[provider.nvidia] api_key/endpoint/model` |
| `src/config/config.cr:43` | Env-маппинг: `NVIDIA_API_KEY`, `NVIDIA_ENDPOINT`, `NVIDIA_MODEL` |
| `src/config/config.cr` | Новая секция `[retry]` с полями `max_retries` (default 3), `base_delay` (default 2), `max_delay` (default 30) + env `H2CODE_RETRY_MAX` и т.п. |
| `src/config/config.cr:287` | `provider_configured?`: `when "nvidia" then !nvidia_api_key.empty?` |
| `src/h2code.cr:389` | В `build_named_provider` ветка `when "nvidia"` → `LLM::NvidiaProvider.new(...)` + проверка наличия ключа |
| `src/h2code.cr` | `require` для `nvidia_provider.cr` (там, где уже `require` остальных провайдеров) |
| `src/setup/wizard.cr:23` | В `PROVIDER_CHOICES`: `ProviderChoice.new("nvidia", "NVIDIA NIM (build.nvidia.com)", true, "https://integrate.api.nvidia.com/v1", "meta/llama-3.3-70b-instruct", "Get a key at https://build.nvidia.com")` |
| `src/setup/wizard.cr:147` | Ветка `when "nvidia"` для ввода ключа |

## Значения по умолчанию

- `NvidiaProvider::DEFAULT_ENDPOINT = "https://integrate.api.nvidia.com/v1"`
- `NvidiaProvider::DEFAULT_MODEL = "meta/llama-3.3-70b-instruct"` (или любой NIM-модель на выбор)
- `[retry] max_retries = 3`, `base_delay = 2`, `max_delay = 30` (текущие дефолты сохраняются;
  пользователь может повысить под NIM, например до 5–6)

## Ключевое отличие от локальных провайдеров

NIM требует **API-ключ** (как ZAI), а не пустой токен. Базовый `OpenAIChatProvider` шлёт
`Authorization: Bearer`, если `token` непустой — это уже covered. Никакого OAuth, как у
Moonshot, не нужно.

## Проверка

- `crystal spec` — запустить существующие спеки, убедиться что ничего не сломано.
- Добавить спек на парсинг `Retry-After` в `ApiError` (если есть spec-файл для types/retry).
- Ручной тест: `H2CODE_PROVIDER=nvidia NVIDIA_API_KEY=nvapi-... h2code` → отправить запрос,
  убедиться что `/model` показывает список NIM-моделей через `GET /models`.
