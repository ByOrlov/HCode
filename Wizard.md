# Wizard — First-run Provider Setup

## Цель

Интерактивный first-run wizard, который спрашивает у пользователя провайдера,
ключ и модель при первом запуске, сохраняет выбор в `~/.kimi/config.toml` и
больше не беспокоит. В non-TTY среде (pipe, CI, скрипт) — fail-fast с понятной
инструкцией вместо падения в глубоком стеке.

## Контекст / Мотивация

### Юридическая

Сегодня в коде захардкожено:

| Где | Что | Файл:строка |
| --- | --- | --- |
| `DEFAULT_PROVIDER_NAME = "kimi"` | дефолт провайдера | `src/llm/provider.cr:62` |
| `endpoint = "https://api.kimi.com/coding/v1"` | дефолт endpoint KimiProvider | `src/llm/kimi_provider.cr:68` |
| `property endpoint : String = "https://api.kimi.com/coding/v1"` | дефолт endpoint в Config | `src/config/config.cr:9` |
| `property model : String = "kimi-for-coding"` | дефолт model в Config | `src/config/config.cr:4` |
| `property provider_name : String = "kimi"` | дефолт provider в Config | `src/config/config.cr:5` |

Поскольку проект называется **KimiO** + модуль `Kimi` + дефолт указывает на
`api.kimi.com` (end-point Moonshot AI), это выглядит как **эндорсмент /
аффилированность** с Moonshot — основание для претензии по товарному знаку
(passing off). GPL и CLA от этого **не защищают**: GPL — лицензия авторских
прав, не товарных знаков.

Wizard решает проблему: пользователь **явно выбирает** провайдера, никакого
дефолта на конкретного вендора в коде нет. KimiProvider остаётся в коде как
одна из опций (nominative fair use — «работает с Kimi»).

### UX

- Сейчас первый запуск требует знать список env-переменных (`KIMI_API_KEY`,
  `KIMI_ENDPOINT`, `KIMI_MODEL`, ...) — высокий порог входа.
- Wizard = один вопрос, один ключ, дальше работает. Сравнение: у `aider`,
  `opencode`, `goose`, `codex` — у всех wizard на первом запуске, ни один не
  имеет захардкоженного дефолта на конкретного вендора. Это industry standard
  для OSS AI-агентов.

## Текущее состояние (до wizard)

```crystal
# src/kimi.cr:143
config = Config::Config.load
# ...
provider = build_provider(config, oauth)   # line 156
```

`Config.load` молча подставляет дефолты `provider_name = "kimi"` и
`endpoint = "https://api.kimi.com/coding/v1"`. Если у пользователя нет
`KIMI_API_KEY` и нет OAuth-токена — `KimiProvider` создаётся, но падает при
первом же запросе с невнятным 401.

## Целевая архитектура

```
                    ┌───────────────────────────┐
                    │   Kimi.run(argv)          │
                    │   src/kimi.cr             │
                    └─────────────┬─────────────┘
                                  │
                                  ▼
                       ┌─────────────────────┐
                       │  Config.load        │  ← подставляет NIL-дефолты
                       │  src/config/        │
                       └─────────┬───────────┘
                                 │
                                 ▼
                  ┌──────────────────────────────┐
                  │  Setup.ensure_provider!      │  ← NEW
                  │  src/setup/wizard.cr         │
                  │                              │
                  │  if config.provider_name? && │
                  │     config.satisfied?        │
                  │    → return (nothing to do)  │
                  │                              │
                  │  elsif TTY                   │
                  │    → run interactive wizard  │
                  │    → Config.save             │
                  │                              │
                  │  else                        │
                  │    → raise SetupRequired     │
                  └──────────────┬───────────────┘
                                 │
                                 ▼
                       ┌─────────────────────┐
                       │  build_provider     │
                       └─────────────────────┘
```

## Контракт

### Config changes (`src/config/config.cr`)

| Поле | Было | Стало |
| --- | --- | --- |
| `provider_name` | `String = "kimi"` | `String? = nil` |
| `endpoint` | `String = "https://api.kimi.com/coding/v1"` | `String? = nil` |
| `model` | `String = "kimi-for-coding"` | `String? = nil` |
| `api_key` | `String = ""` | `String? = nil` |

Добавить:

```crystal
# Returns true when the current provider_name + credentials are sufficient
# to attempt a connection. Used by Setup.ensure_provider! to decide whether
# to run the wizard. Does NOT validate the key — only that one is present.
def provider_configured? : Bool
  case provider_name
  when "kimi"     then !api_key.blank? || oauth_credentials_present?
  when "zai"      then !zai_api_key.blank?
  when "zai-cp"   then !zai_api_key.blank?
  when "openai"   then !api_key.blank?
  when "openrouter" then !api_key.blank?
  when "ollama"   then true  # local, no key needed
  when "mock"     then true
  when nil        then false
  else            !api_key.blank?
  end
end
```

### Env vars (unchanged for back-compat)

`KIMI_API_KEY`, `MOONSHOT_API_KEY`, `KIMI_ENDPOINT`, `KIMI_MODEL`,
`KIMI_PROVIDER`, `ZAI_API_KEY`, `ZHIPU_API_KEY`, `ZAI_ENDPOINT`, `ZAI_MODEL` —
остаются. Если заданы — wizard пропускается (existing flow для скриптов/CI).

### New: `Setup::Wizard` (`src/setup/wizard.cr`)

```crystal
module Kimi
  module Setup
    class SetupRequired < Exception
      def initialize(message = "No provider configured. Run `kimio` in a TTY to set up, or set KIMI_PROVIDER + KIMI_API_KEY + KIMI_ENDPOINT env vars.")
        super(message)
      end
    end

    module Wizard
      PROVIDER_CHOICES = [
        {name: "kimi",      label: "Kimi / Moonshot",         needs_key: true,  default_endpoint: "https://api.kimi.com/coding/v1"},
        {name: "zai",       label: "Z.AI / Zhipu (GLM)",      needs_key: true,  default_endpoint: "https://api.z.ai/api/paas/v4"},
        {name: "openai",    label: "OpenAI",                  needs_key: true,  default_endpoint: "https://api.openai.com/v1"},
        {name: "openrouter",label: "OpenRouter (300+ models)",needs_key: true,  default_endpoint: "https://openrouter.ai/api/v1"},
        {name: "ollama",    label: "Local (Ollama)",          needs_key: false, default_endpoint: "http://localhost:11434/v1"},
      ]

      def self.ensure!(config : Config::Config) : Nil
        return if config.provider_name && config.provider_configured?

        if TTY::Terminal.interactive?
          run_interactive(config)
          Config.save(config)
        else
          raise SetupRequired.new
        end
      end

      # ... run_interactive, prompt_provider, prompt_credentials, prompt_model
    end
  end
end
```

### New providers to register in `KNOWN_PROVIDERS` (`src/llm/provider.cr`)

```crystal
KNOWN_PROVIDERS = [
  ProviderInfo.new("kimi",       "Kimi / Moonshot — Chat Completions"),
  ProviderInfo.new("zai",        "Z.AI / Zhipu — pay-as-you-go (OpenAI-compatible)"),
  ProviderInfo.new("zai-cp",     "Z.AI / Zhipu — Coding Plan subscription"),
  ProviderInfo.new("openai",     "OpenAI — official API"),
  ProviderInfo.new("openrouter", "OpenRouter — 300+ models, single key"),
  ProviderInfo.new("ollama",     "Local Ollama server (no API key)"),
  ProviderInfo.new("mock",       "Mock — scripted self-test provider (testing)"),
]
```

`OpenAIProvider`, `OpenRouterProvider`, `OllamaProvider` — тонкие подклассы
`OpenAIChatProvider` (по аналогии с `KimiProvider`/`ZaiProvider`). Они уже
могут быть созданы через `OpenAIChatProvider.new(model, endpoint, api_key)`
напрямую, но выделение в именованные классы упрощает wire-dialect флаги и
`/provider` селектор.

## TTY wizard flow

```
$ kimio

Welcome to KimiO. Choose your provider:

  > Kimi / Moonshot
    Z.AI / Zhipu (GLM)
    OpenAI
    OpenRouter (300+ models)
    Local (Ollama)

API key (kimi): █
  Get one at https://platform.moonshot.cn

Endpoint [https://api.kimi.com/coding/v1]: █

Model [kimi-for-coding]: █

Saved to ~/.kimi/config.toml.
```

Для `ollama` — ключ не спрашивается. Для `openrouter` — ссылка на
`https://openrouter.ai/keys`.

## Non-TTY fallback (CI, scripts, pipes)

```crystal
raise Setup::SetupRequired.new
```

Вывод:

```
Error: No provider configured.

Run `kimio` once in a TTY to set up interactively, or set:

  export KIMIO_PROVIDER=kimi        # or: zai, openai, openrouter, ollama
  export KIMIO_API_KEY=YOUR_API_KEY # not needed for ollama
  export KIMIO_ENDPOINT=https://api.kimi.com/coding/v1
  export KIMIO_MODEL=kimi-for-coding

See `kimio --help-providers` for the full list.
```

Note: env-префикс остаётся `KIMI_*` для back-compat (см. раздел
«Out of scope»). `KIMIO_*` — отдельная задача (см. ниже).

## Реализация — пошаговая

### Шаг 1. Config: nil-able defaults

- `src/config/config.cr`: сменить дефолты 4 полей на `nil`.
- Обновить `parse_toml` — секции `[provider.kimi]`, `[provider.zai]`,
  `[provider.zai-cp]` продолжают работать как есть.
- `save` писать только заполненные секции (не писать `endpoint = ""`).

### Шаг 2. Провайдеры-обёртки

- `src/llm/openai_provider.cr` — NEW, 20 строк, `< OpenAIChatProvider`.
- `src/llm/openrouter_provider.cr` — NEW, 20 строк.
- `src/llm/ollama_provider.cr` — NEW, 15 строк, без api_key.
- Зарегистрировать в `src/kimi.cr` require-блоке.
- Поправить `build_named_provider` (line ~226) — обрабатывать новые имена.

### Шаг 3. Setup::Wizard

- `src/setup/wizard.cr` — NEW, ~150 строк.
  - `PROVIDER_CHOICES` таблица.
  - `ensure!(config)` — gate-функция.
  - `run_interactive(config)` — основной flow.
  - `prompt_provider`, `prompt_credentials`, `prompt_model`, `confirm_save`.
- `src/setup/tty.cr` или использовать `STDIN.tty?` + `STDIN.raw` для меню.
  Можно переиспользовать `TUI::SelectList` (`src/tui/select_list.cr`) если он
  доступен до старта TUI.

### Шаг 4. Hook в entry point

- `src/kimi.cr:143` после `Config.load`, до `build_provider`:

```crystal
config = Config::Config.load
config.model = model if model
config.permission_mode = pm if pm
config.ensure_kimi_home

Setup::Wizard.ensure!(config)   # ← NEW
```

### Шаг 5. `--help-providers` flag

- В `Kimi.run` добавить обработку `--help-providers` → вывести таблицу
  провайдеров с endpoint-ами и ссылками на получение ключей.

### Шаг 6. README update

- Заменить секцию «Quick Start» → «First run: setup wizard».
- Добавить `--help-providers` в usage.
- Обновить `CONTRIBUTING.md` — dev setup должен упоминать wizard.

## Тест-план

### Unit (`spec/setup/wizard_spec.cr`)

1. `ensure!` no-op когда `config.provider_name` задан и `provider_configured?` true.
2. `ensure!` no-op когда достаточно env-переменных (`KIMI_PROVIDER` + `KIMI_API_KEY`).
3. `ensure!` поднимает `SetupRequired` в non-TTY когда конфиг пустой (stub `TTY::Terminal.interactive?` → false).
4. `provider_configured?` корректно классифицирует каждый провайдер (kimi без ключа → false, kimi с ключом → true, ollama без ключа → true).
5. `run_interactive` через pipe-stub: эмулировать ввод «1\nkey\n\n\n» и проверить, что в `config` попали правильные поля (mock STDIN).

### Integration (`spec/kimi_spec.cr` — расширить)

6. Запуск `Kimi.run([])` без config и без TTY → exit code 2, stderr содержит
   «No provider configured» и подсказку про env-переменные.
7. Запуск с `KIMI_PROVIDER=mock` → wizard не запускается, TUI стартует.

### Manual

8. Удалить `~/.kimi/config.toml`, запустить `./kimio` в реальном терминале →
   должен запуститься wizard, сохранить config, запустить TUI.
9. Повторный запуск — wizard не должен появляться.
10. `KIMI_PROVIDER=ollama ./kimio` → сразу стартует без вопросов.

## Критерии приёмки

- [ ] В `src/` нет ни одного строкового литерала `https://api.kimi.com` в
      качестве **дефолта** (может быть в `PROVIDER_CHOICES` как один из
      вариантов — это nominative use).
- [ ] `DEFAULT_PROVIDER_NAME` равно `nil`.
- [ ] Первый запуск в TTY без config → wizard.
- [ ] Первый запуск в non-TTY без config → понятная ошибка с exit code 2.
- [ ] Все 427 существующих спек проходят.
- [ ] Новые спеки (см. тест-план) добавлены и проходят.
- [ ] `rake build` чистый.
- [ ] `rake spec` 0 failures.
- [ ] README и CONTRIBUTING обновлены.

## Out of scope (отдельные задачи)

- **Rename `module Kimi` → `module Kimio`** — отдельная задача, 30+ правок
  по `src/`. Wizard с ней не связан.
- **Rename env-префикса `KIMI_*` → `KIMIO_*`** — back-compat-breaking change,
  требует deprecation-период. В рамках wizard старый префикс остаётся.
- **MCP-провайдеры** — wizard покрывает только built-in провайдеры.
- **Multi-profile** (несколько сохранённых профилей с переключением через
  `--profile name`) — future work.
- **`kimio login` subcommand для OAuth** — сейчас OAuth-токен читается из
  `~/.kimi-code/credentials/kimi-code.json` (общий с TS-версией). Вынос
  логина в отдельную команду — отдельная задача.

## Зависимости

- Никаких новых shard-зависимостей. TTY-меню можно сделать на `STDIN.raw` +
  ANSI escape codes или переиспользовать `TUI::SelectList`, если он умеет
  работать вне основного TUI-loop.

## Оценка

| Часть | Строк | Часы |
| --- | --- | --- |
| Config nil-able + `provider_configured?` | ~50 | 1 |
| 3 новых провайдера-обёртки | ~60 | 1 |
| `Setup::Wizard` + TTY flow | ~150 | 3 |
| `--help-providers` + README | ~50 | 1 |
| Спеки (unit + integration) | ~150 | 2 |
| **Итого** | **~460** | **8** |
