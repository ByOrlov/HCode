# План: единый конфиг, убрать скрытые ENV-чтения

## Контекст проблемы

`Config::Config#load` (src/config/config.cr) — единственное место, где env-override'ы
собираются в один объект. Это правильно для ~30 провайдерных ключей. Но часть
**поведенческих** флагов читается из `ENV` напрямую в разбросанных местах кода,
минуя Config. В итоге:

- поведение нельзя воспроизвести/переопределить декларативно (через config.json);
- тесты и сабагенты не получают этих настроек через инжекцию, а читают реальный ENV;
- при сборке флаг-объекта в `Config.load` эти ключи «невидимы».

Полный список разбросанных чтений (актуален на момент аудита):

| ENV-ключ | Где читается напрямую |
|---|---|
| `HCODE_DEBUG` | loop/agent.cr:307,383 · hcode.cr:650 · tools/cron.cr:301 · llm/openai_chat_provider.cr:505 |
| `HCODE_DISABLE_CRON` | hcode.cr:811,885,908 · tools/cron.cr:841 |
| `HCODE_CRON_NO_STALE` | tools/cron.cr:222 |
| `HCODE_SUBAGENT_TIMEOUT_MS` | loop/subagent_agent_runner.cr:299 · loop/subagent_swarm_runner.cr:39 |
| `HCODE_EXPERIMENTAL_FLAG` | tui/command_controller.cr:381 |
| `HCODE_MOCK_SCRIPT` | llm/mock_provider.cr:399 |
| `EDITOR` / `VISUAL` / `TMPDIR` | tui/input_controller.cr:298,299,356 · plugin/manager.cr:415 |
| `GIT_TERMINAL_PROMPT` / `SHELL` | tools/bash.cr:567,568 · prompt/system_prompt.cr:189 |

Примечание: `HCODE_HOME`, `HOME`, `HTTP_PROXY` и провайдерные ключи — это
инфраструктурные значения, их трогать не нужно (пути файловой системы и
провайдерные секреты уже в `Config.load`).

## Цель

Все поведенческие флаги читаются **только** в `Config.load` (или в тонком
`Env`-слое), складываются в `Config::Config`, а потребители получают уже
готовые значения через DI (конструктор / property / сервис). Прямых `ENV[...]`
поведенческих чтений вне `config.cr` не остаётся.

---

## Шаг 1. Расширить `Config::Config` поведенческими полями

В src/config/config.cr добавить секцию поведенческих настроек рядом с
существующими свойствами (`debug_zones`, `max_steps` и т.д.):

```crystal
# --- Поведенческие флаги (раньше читались из ENV напрямую) ---
property? debug : Bool = false
property? cron_enabled : Bool = true
property? cron_no_stale : Bool = false
property subagent_timeout_ms : Int32? = nil
property experimental_flag : String? = nil
property mock_script : String? = nil
property editor : String? = nil
property tmp_dir : String? = nil
property git_terminal_prompt : String? = nil
property shell : String? = nil
```

Типы `String?` (а не `Bool`) для `GIT_TERMINAL_PROMPT`/`SHELL` сохраняют
текущую семантику «прокси реального ENV в дочерний процесс» — эти значения
просто прокидываются дальше в `env` хэш child-процесса.

## Шаг 2. Заполнить их в `Config.load`

В том же методе `self.load`, рядом с существующими env-override'ами:

```crystal
config.debug = ENV.has_key?("HCODE_DEBUG")
config.cron_enabled = !ENV.has_key?("HCODE_DISABLE_CRON")
config.cron_no_stale = ENV.has_key?("HCODE_CRON_NO_STALE")
if v = ENV["HCODE_SUBAGENT_TIMEOUT_MS"]?.try(&.to_i?); v.try { |x| config.subagent_timeout_ms = x if x >= 1 } end
config.experimental_flag = ENV["HCODE_EXPERIMENTAL_FLAG"]?
config.mock_script = ENV["HCODE_MOCK_SCRIPT"]?
config.editor = ENV["EDITOR"]? || ENV["VISUAL"]?
config.tmp_dir = ENV["TMPDIR"]?
config.git_terminal_prompt = ENV["GIT_TERMINAL_PROMPT"]?
config.shell = ENV["SHELL"]?
```

(Приоритет ENV > config.json — такой же, как сейчас у провайдеров. При желании
добавить JSON-секции (`"runtime": {…}`) в `parse_json` — опционально, на первом
этапе достаточно ENV-источника, т.к. именно его и унифицируем.)

## Шаг 3. Пробросить Config в потребителей

Сейчас `config` уже есть в `hcode.cr` (локальная переменная в `run` и `run_headless`).
Нужно передать нужные поля вниз. Изменения минимальны — туда, где уже есть
доступ к `config`, добавить аргумент/property:

1. **`Loop::Agent`** — добавить `property? debug : Bool = false` (или
   `@debug`). Agent не должен держать весь Config; ему нужен только флаг.
   В `hcode.cr`, при создании `agent`, выставить `agent.debug = config.debug`.

2. **`LLM::Provider` / `MockProvider`** — `HCODE_DEBUG` в
   `openai_chat_provider.cr:505` читать через `@debug` (добавить property на
   базовом провайдере, выставлять в `build_provider` из `config.debug`).
   Для `MockProvider`: убрать `script_from_env`, в фабрике
   `build_mock_provider` передавать `config.mock_script` и выбирать скрипт по
   строке, а не по `ENV`.

3. **`LiveCronService`** — в трёх местах `hcode.cr` (811/885/908) заменить
   `!ENV.has_key?("HCODE_DISABLE_CRON")` на `config.cron_enabled`. В
   `tools/cron.cr:841` (сообщение об ошибке) и `:222` (`HCODE_CRON_NO_STALE`)
   — получать значения из сервиса/конфига, который уже построен; cron-сервис
   уже хранит `enabled`, добавить `@no_stale` аналогично.

4. **`SubagentAgentRunner` / `SubagentSwarmRunner`** — в `timeout_ms`
   заменить `ENV["HCODE_SUBAGENT_TIMEOUT_MS"]?` на значение из конфига.
   Runners строятся в `wire_subagent_runners(..., config)` (hcode.cr:517) —
   туда и передать `config.subagent_timeout_ms` (или целиком поле).

5. **`TUI::CommandController`** (`HCODE_EXPERIMENTAL_FLAG`) и
   **`TUI::InputController`** (`EDITOR/VISUAL/TMPDIR`) — App уже держит
   `app_config` (hcode.cr:702). Контроллеры берут значения из
   `app.app_config.experimental_flag` / `.editor` / `.tmp_dir`.

6. **`Tools::Bash`** (`GIT_TERMINAL_PROMPT`, `SHELL`) — Bash уже создаётся
   как объект в hcode.cr:802. Добавить в конструктор (или property) значения
   `config.git_terminal_prompt`, `config.shell`, использовать их в
   `bash.cr:567-568`. Альтернатива: Bash читает `app_config` через уже
   существующий мост — но чище передать явно.

7. **`Prompt::SystemPrompt`** (`SHELL`, system_prompt.cr:189) — передать
   `config.shell` в `SystemPrompt.build` (он уже вызывается из hcode.cr).

## Шаг 4. Удалить прямые `ENV[...]` в коде потребителей

После Шага 3 каждое чтение из таблицы выше заменяется на поле `config` /
`@debug` / property. Физически удалить `ENV["HCODE_DEBUG"]?` и т.д. из:
loop/agent.cr, hcode.cr, tools/cron.cr, llm/openai_chat_provider.cr,
llm/mock_provider.cr, tui/input_controller.cr, tui/command_controller.cr,
loop/subagent_*, tools/bash.cr, prompt/system_prompt.cr, plugin/manager.cr.

Единственные оставшиеся `ENV[...]` — в `config.cr` (источник) и инфраструктурные
(`HOME`, `HCODE_HOME`, провайдерные секреты, `HTTP_PROXY`).

## Шаг 5. Тесты и проверка

- В spec/config/ добавить кейсы: `Config.load` с выставленным ENV даёт корректные
  поля (`debug == true`, `cron_enabled == false` при `HCODE_DISABLE_CRON`, и т.д.).
- Существующие spec'и, читающие эти ENV, перевести на инжекцию (передать Config
  с нужными полями вместо мутации ENV) — там, где это практично; где мутация ENV
  остаётся, она проверяет именно слой `Config.load`.
- `crystal spec` + `bin/ameba` должны быть зелёными.
- Ручная smoke-проверка: `HCODE_DEBUG=1` всё ещё включает `[debug]`-логи;
  `HCODE_DISABLE_CRON=1` глушит cron — поведение не меняется, меняется только
  место чтения.

---

## Что НЕ делаем (намеренно)

- Не выносим `HOME`/`HCODE_HOME`/`HTTP_PROXY` и провайдерные секреты в новые
  структуры — они уже собраны в `Config.load` и являются инфраструктурой.
- Не добавляем JSON-секции для этих флагов на первом этапе (ENV уже унифицирован
  в одной точке). Это можно сделать позже как `parse_json`-расширение без
  переделки потребителей, т.к. поля уже будут в Config.
- Не заводим отдельный `Env`-класс — `Config.load` уже играет эту роль и
  доступен везде; дополнительный слой был бы избыточен.

## Итог

После рефакторинга: один метод `Config.load` — единственный читатель поведенческих
ENV-флагов; все компоненты получают значения через DI; поведение воспроизводимо
в тестах и у сабагентов без мутации реального окружения.
