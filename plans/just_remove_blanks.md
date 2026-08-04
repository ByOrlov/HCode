# План: убрать blank-строки и shift-логику из зон TUI

## Цель

Сделать модель `LogZone + ActiveZone` устойчивой к багам, убрав ручную
симуляцию скролла через `trailing_blanks` / `consume_blank` / `height_log`.

Активная зона каждый кадр перерисовывается целиком у нижнего края видимой
области. Освободившиеся строки очищаются ANSI-командами (`\e[2K`, `\e[J`), а не
хранятся как blank-строки в логическом представлении. `TerminalMock` учится
"удалять" очищенные trailing-строки из `visible_rows`, чтобы тесты проверяли
контент, а не пустые ячейки экрана.

## Принцип работы после изменений

```
Кадр N:
  [L1] [L2] [L3] [A1] [A2] [A3] [A4] [A5]

Кадр N+1 (active сжалась до 2 строк):
  [L1] [L2] [L3] [A1] [A2] [__] [__] [__]
       └── clear_below ──┘

В TerminalMock visible_rows теперь:
  [L1, L2, L3, A1, A2]
```

## Файлы, которые тронем

- `src/tui/active_zone.cr`
- `src/tui/log_zone.cr`
- `src/tui/app.cr`
- `src/tui/terminal_mock.cr`
- `src/tui/ansi_terminal_port.cr` (возможно, добавить `clear_below` уже есть)
- `spec/tui/active_zone_spec.cr`
- `spec/tui/zone_behaviour_spec.cr`
- `spec/tui/zone_test_cases.md`
- `spec/tui/editor_cursor_sync_spec.cr`

---

## Шаг 1. TerminalMock: поддержка "удаления" trailing-строк

### Что меняем

Сейчас `visible_rows` возвращает `scrollback + screen[0..max_touched]`. После
очистки нижних строк они остаются в виде `""` внутри `screen`, и
`visible_rows` всё равно их отдаёт.

Нужно, чтобы `clear_below` уменьшал логический конец контента.

### Как

- В `TerminalMock#clear_below` после очистки строк ниже курсора сделать:
  ```crystal
  @max_touched = @cursor_row if @cursor_row < @max_touched
  ```
- Добавить метод `clear_below` в `TerminalPort` (уже есть) и убедиться, что
  `AnsiTerminalPort` пишет `\e[J`.
- Убедиться, что `visible_rows` не дополняет экран до `@rows`, если контент
  короче.

### Тесты

- Новый/обновлённый тест: после `clear_below` `visible_rows` не содержит
  trailing `""`.

---

## Шаг 2. Упростить ActiveZone

### Что удаляем

- `@height_log`
- `@trailing_blanks`
- `@planned`
- `@last_painted`
- `consume_blank`
- `shift_available?`
- `available_blanks`
- `blanks_count`
- `plan`
- `seed_baseline`

### Что оставляем

- `@lines : Array(String)`
- `set(lines)`
- `render(port, available_rows)` — рисует первые
  `min(@lines.size, available_rows)` строк и, если предыдущий кадр занимал
  больше строк, очищает остаток `\e[J`.

### Как отслеживать предыдущую видимую высоту

`ActiveZone` больше не хранит историю. `App` сама передаёт `prev_active_visible`
в `render` (или ActiveZone возвращает текущую видимую высоту, а App хранит её
между кадрами).

Рекомендуемый вариант:

```crystal
# App
@prev_active_visible : Int32 = 0

# в render
active_visible = @active_zone.render(port, active_lines, available_rows, @prev_active_visible)
@prev_active_visible = active_visible
```

`ActiveZone#render` рисует контент, затем:

```crystal
if prev_visible > visible
  # очистить строки от visible до prev_visible
  port.clear_below
end
```

---

## Шаг 3. Упростить LogZone

### Что оставляем

- `@flushed` — сколько log-строк уже выведено.
- `flush(port, log_lines)` — эмитит только `log_lines[@flushed..]`.
- `reset` / `mark_flushed`.
- `MAX_FLUSH_PER_FRAME` — защита от огромного лога за один кадр.

### Что удаляем/упрощаем

- `reveal_limit` можно заменить на простое ограничение:
  ```crystal
  limit = Math.min(log_lines.size, @flushed + rows)
  ```
  Если осталось больше — `@dirty = true` на следующий кадр.
- `pending?` оставляем, но реализация упрощается.

---

## Шаг 4. Переписать App#incremental_render

### Состояние, которое App хранит между кадрами

Убрать:
- `@active_zone.trailing_blanks` (шаг 2)
- `@previous_lines` больше не нужен для diff-логики, можно оставить только для
  `/memory` профайлера
- `@previous_viewport_top` оставляем
- `@hardware_cursor_row` оставляем

Добавить/оставить:
- `@prev_log_count : Int32 = 0`
- `@prev_active_visible : Int32 = 0`
- `@prev_viewport_top : Int32 = 0`
- `@hardware_cursor_row : Int32 = 0`

### Алгоритм каждого кадра

```crystal
total        = log_lines.size + active_lines.size
viewport_top = Math.max(0, total - rows)
log_delta    = log_lines.size - @prev_log_count

if @first_render || width_changed || height_changed ||
   viewport_top < @prev_viewport_top || log_lines.size < @prev_log_count
  full_render(port, log_lines, active_lines, rows)
elsif log_delta > 0
  # 1. курсор вниз экрана
  # 2. прокрутить терминал на log_delta строк (\r\n log_delta раз)
  # 3. подняться на active_visible + log_delta строк
  # 4. написать новые log-строки
  # 5. спуститься и перерисовать активную зону
  scroll_and_render(port, log_lines, active_lines, rows, log_delta)
else
  # лог не вырос — просто перерисовать активную зону у нижнего края
  render_active_only(port, log_lines, active_lines, rows)
end
```

### full_render

- `cursor_home`
- вывести все `log_lines` и `active_lines` с `\r\n`
- `clear_below`
- синхронизировать `@prev_log_count`, `@prev_active_visible`,
  `@prev_viewport_top`, `@hardware_cursor_row`
- `@first_render = false`

### render_active_only

- вычислить `active_visible = min(active_lines.size, rows)`
- `active_start = total - active_visible` (первая видимая строка активной зоны)
- спозиционировать курсор на `active_start`
- нарисовать `active_visible` строк
- если `@prev_active_visible > active_visible`, очистить освободившиеся строки
  `\e[J`
- обновить `@prev_active_visible`, `@hardware_cursor_row`

### scroll_and_render

- спозиционировать курсор на нижнюю видимую строку
- `\r\n * log_delta` — терминал прокручивается вверх
- подняться на `active_visible + log_delta` строк
- эмитить новые log-строки через `LogZone#flush`
- спуститься к активной зоне и перерисовать её
- обновить `@prev_log_count`, `@prev_active_visible`, `@hardware_cursor_row`,
  `@prev_viewport_top`

---

## Шаг 5. Починить курсор редактора

Сейчас `editor_content_line` считается до клампинга активной зоны. Нужно
использовать реальную `active_start`:

```crystal
active_visible = min(active_lines.size, rows)
active_start   = total - active_visible
editor_row     = active_start + @editor.cursor_visual_row
```

`position_cursor` должен брать `editor_row`, вычитать `viewport_top` и
клампить к `[0, rows - 1]`. Это устранит рассинхрон hardware cursor и
нарисованного блока.

---

## Шаг 6. Убрать `throttle_log` как источник рассинхрона

Текущий `throttle_log` обрезает `log_lines` и затем корректирует
`editor_content_line`. В новой модели:

- `LogZone` эмитит не больше `rows` новых строк за кадр.
- Если осталось больше — `@dirty = true`, следующий кадр доберёт.
- `active_lines` и `editor_content_line` считаются от **полного** `log_lines`,
  не от урезанного.
- Эмиссия новых log-строк происходит до отрисовки активной зоны, поэтому
  активная зона всегда рисуется относительно актуального состояния.

---

## Шаг 7. Обновить тесты

### active_zone_spec.cr

- Удалить тесты на `trailing_blanks`, `consume_blank`, `height_log`.
- Добавить тест: при сжатии зона рисует только контент, а `clear_below`
  очищает освободившиеся строки.
- Добавить тест: при пустом логе и viewport активная зона клампится к
  `available_rows`.

### zone_behaviour_spec.cr

- Убрать ожидание blank-строк из всех ассертов.
- `Test 3`, `Test 4`, `Test 6b` — снять `pending`, ожидаемое поведение:
  активная зона рисуется снизу, лог занимает оставшееся пространство.
- `Test 8` — tall modal dismiss должен работать через full_render при
  `viewport_top < prev_viewport_top`.

### zone_test_cases.md

- Переписать ожидаемые массивы без `""`.
- Убрать разделы про `trailing_blanks` и `consume_blank`.
- Обновить инварианты.

### editor_cursor_sync_spec.cr

- Убедиться, что после изменений hardware cursor совпадает с блоком.
- Если тесты всё ещё падают — донастроить `position_cursor`.

---

## Шаг 8. Валидация

```bash
crystal spec spec/tui/active_zone_spec.cr
crystal spec spec/tui/log_zone_spec.cr
crystal spec spec/tui/zone_behaviour_spec.cr
crystal spec spec/tui/editor_cursor_sync_spec.cr
crystal spec spec/tui/
```

Цель: 0 failures, 0 pending в зон-тестах.

---

## Что НЕ делаем в этом плане

- Не переделываем `@messages` в immutable finalized-лог. Это отдельная,
  полезная задача, но она увеличивает объём. В рамках этого плана оставляем
  `@messages` как есть, но упрощаем рендер.
- Не переходим к полноэкранному diff-рендереру (Путь Б). Если Путь А через
  пару месяцев снова даст трещины — тогда рассмотрим полный переход на модель
  `pi-tui`.
