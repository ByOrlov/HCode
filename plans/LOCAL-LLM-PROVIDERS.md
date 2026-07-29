# Local LLM Providers — Ollama, LMStudio, и first-run wizard

## Цель

1. Поддержка Ollama и LMStudio как провайдеров (локальные OpenAI-compatible серверы, без API-ключа).
2. First-run wizard в TUI: input box в режиме настройки вместо отдельного ANSI-скрипта.
3. Nil-able дефолты в Config — убрать захардкоженный `moonshot` (юридический нюанс из Wizard.md + чистый first-run).

## Контекст

- Провайдеры — тонкие подклассы `OpenAIChatProvider` (`src/llm/`): `MoonshotProvider`, `ZaiProvider`, `MockProvider`.
  Разница между ними — только `token`, `name`, и флаг `@thinking_wire`.
- `KNOWN_PROVIDERS` (`src/llm/provider.cr:74`) и `build_named_provider` (`src/hcode.cr:315-360`) — единая точка регистрации.
- Тестов против сети нет: вся `spec/llm/` проверяет `build_request` (формирование JSON-запроса),
  интеграция агента гоняется на `MockProvider`.
- `Config.load` (`src/config/config.cr`) читает env + TOML, `save` пишет TOML.
- Мастера настройки в коде нет — `Wizard.md` это только дизайн-док.
- Решение по wizard: переиспользовать TUI input box (режим wizard), а не отдельный ANSI-скрипт.

## Часть 1. Провайдеры Ollama + LMStudio

Делается первой — даёт немедленно работающих провайдеров через env даже без wizard.

| Файл | Изменение |
|---|---|
| `src/llm/ollama_provider.cr` | NEW — `< OpenAIChatProvider`, `DEFAULT_ENDPOINT = "http://localhost:11434/v1"`, `token` возвращает `""`, `@thinking_wire = None` |
| `src/llm/lmstudio_provider.cr` | NEW — то же, `DEFAULT_ENDPOINT = "http://localhost:1234/v1"` |
| `src/llm/provider.cr:74` | Добавить в `KNOWN_PROVIDERS` |
| `src/hcode.cr:315` (`build_named_provider`) | Две ветки: возврат без проверки ключа |
| `src/llm/openai_chat_provider.cr:444` | Опустить `Authorization` когда `token.empty?` — в `stream_response` + `fetch_models` + `refresh_model_metadata` |
| `src/config/config.cr` | Поля `ollama_endpoint`, `lmstudio_endpoint` + env `OLLAMA_ENDPOINT`/`LMSTUDIO_ENDPOINT` + parse/save TOML |
| `src/hcode.cr` | require новых файлов |

### Тесты (без сети)

| Файл | Что проверяет |
|---|---|
| `spec/llm/types_spec.cr` (расширить) | `build_request` для ollama/lmstudio: нет `thinking`, нет `reasoning_effort`, нет `Authorization`. Provider identity: `name`, `model_name`, `endpoint`, `token == ""`. |

Сетевых тестов не добавляем. Ручная проверка локальной модели — через `hcode --hi`.

## Часть 2. Nil-able дефолты в Config

| Поле | Было | Стало |
|---|---|---|
| `provider_name` | `String = "moonshot"` | `String? = nil` |
| `endpoint` | `String = "https://..."` | `String? = nil` |
| `model` | `String = "kimi-for-coding"` | `String? = nil` |
| `api_key` | `String = ""` | `String? = nil` |

Добавить `provider_configured?` (как в `Wizard.md:111-123`):

```crystal
def provider_configured? : Bool
  case provider_name
  when "moonshot"     then !api_key.blank? || oauth_credentials_present?
  when "zai"          then !zai_api_key.blank?
  when "zai-coding-plan" then !zai_api_key.blank?
  when "ollama"       then true  # local, no key needed
  when "lmstudio"     then true  # local, no key needed
  when "mock"         then true
  when nil            then false
  else                !api_key.blank?
  end
end
```

Обновить `build_named_provider` — принимать `String?` и обрабатывать `nil` (raise с понятным сообщением).
Обновить все места чтения (`config.model`, `config.endpoint`, и т.д.).
Обновить `save` — писать только заполненные секции.

### Тесты

| Файл | Что проверяет |
|---|---|
| `spec/config/config_spec.cr` (новый) | `provider_configured?` для каждого провайдера; nil-able parse/save TOML |
| `spec/hcode_spec.cr` (расширить или новый) | `HCODE_PROVIDER=ollama` → `build_named_provider` строит `OllamaProvider`; `nil` provider → `ProviderConfigError` |

## Часть 3. Wizard в TUI

### Архитектура

TUI App получает режим `@setup_mode : Bool`. Когда `true`:
- Editor placeholder меняется на текущий шаг wizard
- `submit_message` не вызывает `run_turn`, а вызывает `on_setup_submit` callback
- Transcript показывает приветствие и инструкции
- `SelectList` (уже существует) переиспользуется для выбора провайдера

### State machine wizard (в новом `src/setup/wizard.cr`)

```
step :welcome     → показать выбор провайдера (SelectList)
step :credentials → placeholder "Enter API key..." (или пропустить для ollama/lmstudio)
step :endpoint    → placeholder "Endpoint [http://localhost:11434/v1]:" (с дефолтом)
step :model       → placeholder "Model name [llama3.2]:" (с дефолтом)
step :confirm     → "Saved to ~/.hcode/config.toml. Starting..."
```

### Hook в `Hcode.run` (`src/hcode.cr:215`)

```crystal
provider = if config.provider_name && config.provider_configured?
             build_provider(config, oauth)
           elsif STDIN.tty?  # interactive wizard
             run_setup_wizard(config)  # → TUI in setup mode, returns updated config
             config.save
             build_provider(config, oauth)
           else
             raise SetupRequired.new  # non-TTY: clear error + env instructions
           end
```

После wizard — продолжаем normal flow (memory, tools, agent, TUI normal mode).

### Non-TTY fallback

`raise SetupRequired` с инструкцией по env-переменным, exit code 2.

## Что не делаем (out of scope)

- `--help-providers` флаг
- Реструктуризация env-имён (`MOONSHOT_*` остаётся как есть для back-compat)
- Multi-profile (несколько сохранённых профилей)
- `hcode login` subcommand для OAuth

## Порядок работ

1. **Часть 1** (провайдеры) — независимо, можно сразу тестировать через `HCODE_PROVIDER=ollama`
2. **Часть 2** (nil-able конфиг) — требует wizard для first-run, но env-переменные работают сразу
3. **Часть 3** (wizard в TUI) — самое объёмное
4. **Тесты** — параллельно с каждой частью

## Критерии приёмки

- [ ] `OllamaProvider` и `LmStudioProvider` строятся без ключа, `token == ""`, `Authorization` опускается
- [ ] `HCODE_PROVIDER=ollama ./hcode` и `HCODE_PROVIDER=lmstudio ./hcode` стартуют без вопросов
- [ ] `KNOWN_PROVIDERS` включает `ollama` и `lmstudio`
- [ ] В `src/` нет ни одного строкового литерала `https://api.kimi.com` в качестве дефолта
- [ ] `DEFAULT_PROVIDER_NAME` равно `nil`
- [ ] Первый запуск в TTY без config → wizard
- [ ] Первый запуск в non-TTY без config → понятная ошибка с exit code 2
- [ ] Все существующие спеки проходят
- [ ] Новые спеки добавлены и проходят
- [ ] `rake build` чистый
- [ ] `rake spec` 0 failures
