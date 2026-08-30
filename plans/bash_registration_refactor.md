# Унификация регистрации и зависимостей `Tools::Bash`

## Контекст

`Tools::Bash` сегодня регистрируется **дважды** с разным набором зависимостей,
а часть зависимостей висит на классе (`@@`), часть — на экземпляре (`@`). В
результате один и тот же класс в разных режимах ведёт себя по-разному, и это
нигде не выражено в типах — только в порядке вызовов в `src/h2code.cr`.

Точки регистрации/создания `Bash.new`:

| Место                          | Аргументы                                             | Режим              |
|--------------------------------|-------------------------------------------------------|--------------------|
| `src/h2code.cr:292`             | `(work_dir)`                                          | общий (оба режима) |
| `src/h2code.cr:802`             | `(app_work_dir, ts, session_dir, delivery)`           | только interactive |
| `src/loop/subagent_registry.cr:122` | `(work_dir)`                                     | субагенты          |

Состояние зависимостей в `src/tools/bash.cr`:

- инстанс: `@task_service` (19), `@session_dir` (20), `@delivery` (21);
- класс:  `@@sudo_mode` (39), `@@sudo_approval` (40), `@@terminal_exec` (59).

Внешняя мутация классового состояния:
- `/sudo …` — `src/tui/command_controller.cr:243,246,249`,
  `src/tui/input_controller.cr:1001`;
- чтение режима для UI — `src/tui/input_controller.cr:981`,
  `src/tui/ui_panels.cr:620`;
- `terminal_exec=` / `sudo_approval=` — только в `run_interactive`,
  `src/h2code.cr:748-755`.

## Проблема

1. **Двойная регистрация.** В `run` (общий путь) Bash создаётся «усечённым»
   (`h2code.cr:292`). Затем `run_interactive` пересоздаёт его с полным набором
   зависимостей и перерегистрирует через `agent.tools.register(bash_tool)`
   (`h2code.cr:802-803`). В headless остаётся усечённый экземпляр →
   `run_in_background: true` падает с «Background execution is not available
   for this agent» (`bash.cr:156-161`), хотя `task_service` в headless
   существует и живёт (`h2code.cr:398-399`). Скрытый контракт: «в headless
   фоновые команды запрещены» — нигде в типах не выражен.

2. **Классовое состояние вместо инстансного.** `@@terminal_exec`,
   `@@sudo_approval`, `@@sudo_mode` — глобальны на весь процесс. Поэтому:
   - в headless sudo-команды молча идут по фолбэку «stdin closed» и падают
     с «a terminal is required to read the password», потому что
     `terminal_exec=` вызывается только в `run_interactive`;
   - субагенты (`ProfileRegistry.build`, `subagent_registry.cr:122`) создают
     свой Bash, но наследуют глобальный `@@sudo_mode` родителя —
     `sudo always`, выставленный в основном агенте, автоматически разрешает
     sudo во всех субагентах того же процесса;
   - параллельные сессии в одном процессе (future) разделяли бы режим sudo.

3. **Схема параметров не отражает возможности.** `parameters`
   (`bash.cr:112-146`) всегда рекламирует `run_in_background` /
   `disable_timeout`, независимо от того, есть ли `@task_service`. Модель
   узнаёт о недоступности только по ошибке во время выполнения.

## Цели рефакторинга

- Одна точка создания Bash на агент; убрать перерегистрацию в
  `run_interactive`.
- Все зависимости — инстансные (`@`), вводятся через конструктор или
  инстансные сеттеры. Убрать `@@sudo_mode`, `@@sudo_approval`,
  `@@terminal_exec`.
- Headless и interactive получают одинаковый базовый набор возможностей
  (`task_service`); TUI-only мосты (`terminal_exec`, `sudo_approval`,
  `delivery`) внедряются только когда есть TUI.
- Доступность `run_in_background` видна в схеме параметров инструмента.

## Дизайн

### 1. Инстансные зависимости для sudo/terminal

В `src/tools/bash.cr` заменить классовые переменные на инстансные:

```crystal
@sudo_mode       : SudoMode = SudoMode::Off
@sudo_approval   : (String -> SudoApprovalChoice)?
@terminal_exec   : TerminalExecService?
```

Добавить инстансные аксессоры:

```crystal
def sudo_mode=(mode : SudoMode); @sudo_mode = mode; end
def sudo_mode : SudoMode; @sudo_mode; end
def terminal_exec=(svc : TerminalExecService?); @terminal_exec = svc; end
def sudo_approval=(cb : (String -> SudoApprovalChoice)?); @sudo_approval = cb; end
```

Везде внутри класса заменить `@@sudo_mode → @sudo_mode`,
`@@sudo_approval → @sudo_approval`, `@@terminal_exec → @terminal_exec`
(строки 186, 249, 255, 260). Удалить `def self.sudo_mode=`,
`def self.sudo_mode`, `def self.sudo_approval=`, `def self.terminal_exec=`,
`def self.terminal_exec` (42-67).

> Поведение по умолчанию меняется с `SudoMode::Request` на `SudoMode::Off`:
> см. «Изменения поведения».

### 2. Связывание `/sudo` и UI через ссылку на экземпляр

`/sudo` и панель статуса сейчас ходят к классовым аксессорам. Им нужна ссылка
на активный Bash. Завести в `H2code::TUI::App` (или в `run_interactive`) поле:

```crystal
@bash_tool : H2code::Tools::Bash?
```

Присваивается после создания инструмента (см. п. 4). Затем:
- `src/tui/command_controller.cr:243,246,249` — заменить
  `Tools::Bash.sudo_mode = X` на `@app.bash_tool.try(&.sudo_mode=(X))`
  (или через метод-обёртку `App#set_sudo_mode`);
- `src/tui/input_controller.cr:1001` — аналогично для инкрементального ввода;
- `src/tui/input_controller.cr:981`, `src/tui/ui_panels.cr:620` — чтение
  `Tools::Bash.sudo_mode` → `@app.bash_tool.try(&.sudo_mode)` с запасным
  значением `SudoMode::Off`.

### 3. Единый конструктор

`src/tools/bash.cr:69-73` — оставить один конструктор с опциональными
зависимостями (уже такой). Никаких отдельных форм.

### 4. Одна точка регистрации в `run`

В `src/h2code.cr` перенести создание полного Bash из `run_interactive`
(`h2code.cr:798-803`) в общий путь `run`, сразу после создания `task_service`
(`h2code.cr:398-399`):

```crystal
task_service = H2code::Tools::InMemoryTaskService.new(store)
H2code::Tools::Task.service = task_service
# ...
delivery = nil # headless: авто-доставка уведомлений о завершении фоновых
               # задач не нужна; пользователь опрашивает через TaskList/TaskOutput
bash_tool = Tools::Bash.new(work_dir, task_service, store.session_dir, delivery)
tools.register(bash_tool)   # заменяет tools.register(Tools::Bash.new(work_dir))
```

Удалить `tools.register(Tools::Bash.new(work_dir))` в `h2code.cr:292`.

В `run_interactive` (`h2code.cr:798-803`) удалить повторное создание и
перерегистрацию. Вместо этого — дополнить уже зарегистрированный экземпляр
TUI-мостами:

```crystal
bash_tool = agent.tools[Names::Bash].as(Tools::Bash)
bash_tool.delivery = ->(text : String) { app.deliver_external_prompt(text) }
bash_tool.terminal_exec = AppTerminalExecService.new(app)
bash_tool.sudo_approval = ->(command : String) { app.request_sudo_approval(command) }
@app.bash_tool = bash_tool   # для /sudo и UI
```

Для этого добавить инстансный сеттер `delivery=` в `Bash`. `terminal_exec=` и
`sudo_approval=` уже вводятся в п. 1.

> Альтернатива — пересоздать экземпляр в `run_interactive` (как сейчас), но
> тогда нужен `agent.tools.register(...)` поверх. Это сохраняет «двойную
 регистрацию» — противоречит цели. Выбран путь «дополнить существующий».

### 5. Доступность фонового режима — в схему параметров

В `src/tools/bash.cr` сделать `parameters` зависящим от наличия
`@task_service`:

```crystal
def parameters : JSON::Any
  props = {
    "command"     => ...,
    "cwd"         => ...,
    "timeout"     => ...,
    "description" => ...,
  }
  if @task_service
    props["run_in_background"] = { ... }
    props["disable_timeout"]   = { ... }
  end
  JSON.parse(props.to_json)
end
```

Рантайм-проверка `@task_service.nil?` в `execute` (`bash.cr:155-162`)
остаётся как защита, но модель больше не увидит параметр, когда он
недоступен. `background_available?`-предикат — опционально, для тестов.

### 6. Субагенты

`src/loop/subagent_registry.cr:122` — оставить `Bash.new(work_dir)` без
`task_service` (субагенты не должны порождать фоновые процессы, разделяя
состояние с родителем). После п. 5 `run_in_background` автоматически
исчезнет из схемы инструмента субагента. После п. 1 sudo-режим субагента
по умолчанию `Off` и не зависит от родителя — это правильно.

## Пошаговый план изменений

1. **`src/tools/bash.cr`**
   - Заменить `@@sudo_mode`, `@@sudo_approval`, `@@terminal_exec` на
     инстансные `@`-поля (39-40, 59) + инстансные аксессоры; удалить
     классовые `self.`-аксессоры (42-67).
   - Поправить обращения внутри класса: 186, 249, 255, 260.
   - Добавить `def delivery=(...)` сеттер.
   - Сделать `parameters` условным по `@task_service` (112-146).
   - Дефолт `@sudo_mode` → `SudoMode::Off`.

2. **`src/h2code.cr`**
   - `run`: после `task_service` (398) создавать `bash_tool` с полным набором
     зависимостей и регистрировать его; удалить `Bash.new(work_dir)` (292).
   - `run_interactive`: удалить блок 798-803 (пересоздание/перерегистрация);
     вместо него — извлечь `bash_tool` из реестра и навесить `delivery`,
     `terminal_exec`, `sudo_approval`; сохранить ссылку для `/sudo`/UI.
   - Убрать мёртвые `app_work_dir`, `ts_value`, `delivery_value`,
     `session_dir_value` (798-801).

3. **`src/tui/app.cr`** (или модуль-расширение)
   - Добавить `@bash_tool : Tools::Bash?` + аксессор; метод-обёртку
     `#set_sudo_mode(mode)` / `#sudo_mode`.

4. **`src/tui/command_controller.cr`** (243-249), **`src/tui/input_controller.cr`**
   (981, 1001), **`src/tui/ui_panels.cr`** (620)
   - Перевести `Tools::Bash.sudo_mode=/sudo_mode` на инстансный доступ через
     `@app.bash_tool`.

5. **Спецификации**
   - `spec/tools/bash_spec.cr` — существующие `Bash.new("/tmp")` остаются
     валидны (дефолты). Добавить кейсы:
     - `parameters` без `task_service` не содержит `run_in_background`;
     - `parameters` с `task_service` содержит;
     - sudo-режим изолирован между двумя экземплярами `Bash`;
     - `terminal_exec`/`sudo_approval` — инстансные.
   - `spec/loop/agent_spec.cr:41,194` — без изменений.

## Изменения поведения

1. **Headless получает `run_in_background`.** Раньше падало — теперь фоновая
   команда запускается, пишет лог в `session_dir/tasks/`, статус виден через
   `TaskList`/`TaskOutput`. Авто-доставка уведомления в TUI отсутствует
   (`delivery = nil`). Это намеренное расширение возможностей headless.

2. **Дефолт sudo меняется `Request → Off`.** Сегодня классовый дефолт
   `Request`, но без `sudo_approval` (в headless) он всё равно denies —
   фактически `Off`. Инстансный дефолт `Off` делает это явным и безопасным для
   субагентов. В interactive режим по-прежнему выставляется через `/sudo`.

3. **Субагенты больше не наследуют `sudo always` родителя.** Каждый экземпляр
   Bash имеет свой `@sudo_mode = Off`. Это устраняет утечку привилегий в
   субагенты. Если потребуется явное наследование — вводить через
   `ProfileRegistry.build`, но текущее поведение (наследование через
   глобал) считать багом и не воспроизводить.

4. **Двойная регистрация убрана.** `agent.tools[Names::Bash]` стабилен на
   весь жизненный цикл агента; TUI-мосты добавляются на тот же экземпляр.

## Риски / открытые вопросы

- `agent.tools[Names::Bash]` — проверить, что `Tools::Registry` даёт доступ по
  имени (`[]?`/`[]`). Если нет — хранить ссылку `bash_tool` локально в `run` и
  прокидывать в `run_interactive` параметром (как сейчас `task_service`).
- Headless-доставка уведомлений о завершении фоновой задачи: согласовать,
   достаточно ли опроса через `TaskOutput`, или нужен `delivery`, печатающий
   уведомление в `STDERR`. Решение оставить за реализацией; в плане — `nil`.
- `@sudo_mode = Off` по умолчанию может сломать тест, рассчитывающий на
  `Request`. Прогнать `spec/tools/bash_spec.cr` после правок.
