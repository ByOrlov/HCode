# Тест-кейсы для отрисовки зон (LogZone + ActiveZone)

## Абстракции

### TerminalPort

Интерфейс терминала, через который зоны общаются с экраном. Зоны не пишут ANSI
напрямую — они вызывают методы порта.

```
interface TerminalPort
  # Курсор / позиционирование
  def cursor_down(n)    # сдвинуть курсор вниз на n строк (без скролла)
  def cursor_up(n)      # сдвинуть курсор вверх на n строк
  def carriage_return   # курсор в начало строки (\r)

  # Запись
  def clear_line        # очистить текущую строку (\e[2K)
  def write(str)        # записать строку в позиции курсора
  def newline           # \r\n — перевод строки (вызывает скролл, если курсор внизу)

  # Геометрия
  def rows : Int32      # высота терминала
end
```

**Правило available_rows:** оркестратор вычисляет
`available_rows = viewport - 2` перед передачей в `ActiveZone#render`.
Минимум 2 строки резервируются под LogZone — это гарантирует неразрывность:
пользователь всегда видит хотя бы 2 строки истории над активной зоной.
```

### TerminalMock

Тестовая реализация `TerminalPort`. Хранит массив строк `output` — логическое
состояние экрана. Поддерживает:
- **append** — добавить строку в конец (рост экрана);
- **rewrite** — перезаписать строку по индексу (перерисовка активной зоны);
- **blank** — заменить строку на `""` (очистка);
- **scroll** — сдвинуть массив: верхние строки уходят в `scrollback`, низ
  заполняется новыми.

В режима без viewport `output` не ограничен по длине (растёт сколько нужно).
В режиме с viewport `output` ограничен до `rows` строк; при превышении верхние
строки уходят в `scrollback`.

### Соглашения для массивов

- `L1`, `L2`, … — строки, отправленные в LogZone («Log1», «Log2»).
- `A1`, `A2`, … — строки активной зоны («Active1», «Active2»).
- `""` — пустая строка (blank), оставшийся след от сжатия зоны.
- Массив показывает финальное состояние экрана **после** шага.
- Стрелка `→` обозначает переход от предыдущего шага.

---

## Тест 0: Пустой LogZone + ActiveZone

Ловит баг «при нулевом LogZone кривая отрисовка» — зона должна рисоваться
с самого верха, без смещений.

### Шаг 0.1: log=[], active=[A1]

```
→ initial: []
→ operations: active.set([A1]); active.render(available_rows=∞)
→ output: [A1]
```

### Шаг 0.2: log=[], active=[A1, A2, A3]

```
→ prev: [A1]
→ operations: active.set([A1, A2, A3]); active.render(available_rows=∞)
→ output: [A1, A2, A3]
```

### Шаг 0.3: log=[], active=[A1] (сжатие с 3 → 1)

```
→ prev: [A1, A2, A3]
→ operations: active.set([A1]); active.render(available_rows=∞)
→ output: [A1, "", ""]
```

Зона была 3, стала 1 → дорисованы 2 blank-строки.

---

## Тест 1: Итеративные логи + рост/сжатие зоны (без viewport)

Терминал неограничен. Шаги добавляют логи по одному, затем меняют размер
активной зоны.

### Шаг 1.1: Добавить L1..L10 по одному, active=[A1] постоянно

После каждого Log-zone flush + active render:

```
→ after L1:  [L1, A1]
→ after L2:  [L1, L2, A1]
→ after L3:  [L1, L2, L3, A1]
→ after L4:  [L1, L2, L3, L4, A1]
→ after L5:  [L1, L2, L3, L4, L5, A1]
→ after L6:  [L1, L2, L3, L4, L5, L6, A1]
→ after L7:  [L1, L2, L3, L4, L5, L6, L7, A1]
→ after L8:  [L1, L2, L3, L4, L5, L6, L7, L8, A1]
→ after L9:  [L1, L2, L3, L4, L5, L6, L7, L8, L9, A1]
→ after L10: [L1, L2, L3, L4, L5, L6, L7, L8, L9, L10, A1]
```

Каждый новый лог вставляется перед активной зоной; зона сдвигается вниз на 1
и перерисовывается.

### Шаг 1.2: Расширить active до [A1, A2]

```
→ prev: [L1, L2, L3, L4, L5, L6, L7, L8, L9, L10, A1]
→ operations: active.set([A1, A2]); active.render(available_rows=∞)
→ output: [L1, L2, L3, L4, L5, L6, L7, L8, L9, L10, A1, A2]
```

Зона выросла — просто дорисована A2.

### Шаг 1.3: Сжать active до [A1]

```
→ prev: [L1, L2, L3, L4, L5, L6, L7, L8, L9, L10, A1, A2]
→ operations: active.set([A1]); active.render(available_rows=∞)
→ output: [L1, L2, L3, L4, L5, L6, L7, L8, L9, L10, A1, ""]
```

Зона была 2, стала 1 → 1 blank на месте A2. Общее число строк не изменилось
(12). Все логи на месте.

### Шаг 1.4: Расширить active до [A1..A10]

```
→ prev: [L1, L2, L3, L4, L5, L6, L7, L8, L9, L10, A1, ""]
→ operations: active.set([A1, A2, A3, A4, A5, A6, A7, A8, A9, A10]); active.render(available_rows=∞)
→ output: [L1, L2, L3, L4, L5, L6, L7, L8, L9, L10, A1, A2, A3, A4, A5, A6, A7, A8, A9, A10]
```

Blank с шага 1.3 перезаписан A2; A3..A10 добавлены. Всего 20 строк.

### Шаг 1.5: Сжать active до [A1]

```
→ prev: [L1, L2, L3, L4, L5, L6, L7, L8, L9, L10, A1, A2, A3, A4, A5, A6, A7, A8, A9, A10]
→ operations: active.set([A1]); active.render(available_rows=∞)
→ output: [L1, L2, L3, L4, L5, L6, L7, L8, L9, L10, A1, "", "", "", "", "", "", "", "", ""]
```

Зона была 10, стала 1 → 9 blank-строк (A2..A10 очищены). Общее число строк
не изменилось (20). Blanks сохраняются до следующего log-push (см. Тест 6).

---

## Тест 2: Перемежающиеся логи и активная зона (без viewport)

Проверяет, что добавление лога в середине корректно сдвигает активную зону.

### Шаг 2.1: log=[L1, L2], active=[A1]

```
→ operations: log.flush([L1, L2]); active.set([A1]); active.render(available_rows=∞)
→ output: [L1, L2, A1]
```

### Шаг 2.2: active растёт до [A1, A2]

```
→ prev: [L1, L2, A1]
→ operations: active.set([A1, A2]); active.render(available_rows=∞)
→ output: [L1, L2, A1, A2]
```

### Шаг 2.3: Добавить L3 (log растёт, active перерисовывается)

```
→ prev: [L1, L2, A1, A2]
→ operations: log.flush([L1, L2, L3]); active.set([A1, A2]); active.render(available_rows=∞)
→ output: [L1, L2, L3, A1, A2]
```

L3 встал между L2 и активной зоной. Зона сдвинулась на 1 вниз и
перерисовалась на новых позициях (A1: ряд 2→3, A2: ряд 3→4).

### Шаг 2.4: Сжать active до [A1]

```
→ prev: [L1, L2, L3, A1, A2]
→ operations: active.set([A1]); active.render(available_rows=∞)
→ output: [L1, L2, L3, A1, ""]
```

### Шаг 2.5: Добавить L4 (log растёт, active на 1 строку, shift поглощает blank)

```
→ prev: [L1, L2, L3, A1, ""]
→ operations: active.consume_blank; log.flush([L1, L2, L3, L4]); active.set([A1]); active.render(available_rows=∞)
→ output: [L1, L2, L3, L4, A1]
```

С включённым shift (Тест 6) blank с шага 2.4 поглощается: L4 встаёт в ряд 3
(где была A1), A1 сдвигается в ряд 4 (где был blank). Высота не растёт (5).

---

## Тест 3: Viewport (viewport=10 → available_rows=8)

**Главное ограничение:** активная зона никогда не может занимать весь
терминал. Минимум 2 строки лога всегда должны быть видимы — иначе логический
разрыв. Формула:

```
available_rows = viewport - 2
```

При viewport=10 → available_rows=8. Зона всегда рисуется с `A1` сверху; если
зона виртуально больше 8 — рисуются первые 8 строк, хвост (A9..AX)
отсекается. Blank-паддинг при сжатии тоже клампится к available_rows.

### Шаг 3.1: log=[L1..L5], active=[A1]

```
→ operations: log.flush([L1..L5]); active.set([A1]); active.render(available_rows=8)
→ output: [L1, L2, L3, L4, L5, A1]
```

Зона 1 ≤ 8 — рисуется целиком.

### Шаг 3.2: active растёт до [A1..A5]

```
→ prev: [L1, L2, L3, L4, L5, A1]
→ operations: active.set([A1, A2, A3, A4, A5]); active.render(available_rows=8)
→ output: [L1, L2, L3, L4, L5, A1, A2, A3, A4, A5]
```

Зона 5 ≤ 8 — рисуется целиком.

### Шаг 3.3: active растёт до [A1..A15] (превышает available_rows)

```
→ prev: [L1, L2, L3, L4, L5, A1, A2, A3, A4, A5]
→ operations: active.set([A1..A15]); active.render(available_rows=8)
→ output: [L1, L2, L3, L4, L5, A1, A2, A3, A4, A5, A6, A7, A8]
```

Зона виртуально 15, available_rows = 8 → рисуются **первые** 8 строк зоны
(A1..A8), всегда с `A1` сверху. Хвост A9..A15 отсечён (вне видимой области).

### Шаг 3.4: Сжать active до [A1]

```
→ prev: [L1, L2, L3, L4, L5, A1, A2, A3, A4, A5, A6, A7, A8]
→ operations: active.set([A1]); active.render(available_rows=8)
→ output: [L1, L2, L3, L4, L5, A1, "", "", "", "", "", "", ""]
```

Предыдущая видимая высота = 8 (A1..A8), новая = 1 → 7 blank-строк.
Всего 13 строк (5 log + 1 active + 7 blank).

### Шаг 3.5: Добавить L6..L10 (shift поглощает 5 из 7 blanks)

```
→ prev: [L1, L2, L3, L4, L5, A1, "", "", "", "", "", "", ""]
→ operations: shift ×5; log.flush([L1..L10]); active.set([A1]); active.render(available_rows=8)
→ output: [L1, L2, L3, L4, L5, L6, L7, L8, L9, L10, A1, ""]
→ trailing_blanks: 2
```

5 новых log-строк (L6..L10) поглощают 5 из 7 trailing blanks. Каждый push
сдвигает A1 на 1 ряд вниз, blank исчезает. Высота экрана не растёт: 7→13
шло за счёт 5 log-строк, но 5 blanks закрылось, итого +0 высоты от blanks
(5 добавлено, 5 поглощено) → 13 строк. Осталось 2 blanks.

### Шаг 3.6: active растёт до [A1..A12] (превышает available_rows)

```
→ prev: [L1..L10, A1, ""]
→ operations: active.set([A1..A12]); active.render(available_rows=8)
→ output: [L1, L2, L3, L4, L5, L6, L7, L8, L9, L10, A1, A2, A3, A4, A5, A6, A7, A8]
```

Зона виртуально 12, available_rows = 8 → рисуются первые 8 (A1..A8), всегда
с `A1` сверху. A9..A12 отсечены. Blank-строка перезаписана A2. Всего 18 строк.

### Шаг 3.7: Сжать active до [A1..A3]

```
→ prev: [L1..L10, A1, A2, A3, A4, A5, A6, A7, A8]
→ operations: active.set([A1, A2, A3]); active.render(available_rows=8)
→ output: [L1, L2, L3, L4, L5, L6, L7, L8, L9, L10, A1, A2, A3, "", "", "", "", "", ""]
```

Предыдущая видимая высота = 8, новая = 3 → 5 blank-строк. Всего 18 строк.

---

## Тест 4: Рост и сжатие при пустом логе + viewport

Ловит баг «ActiveZone рисуется снизу при пустом LogZone». Viewport=10,
available_rows=8 (viewport − 2).

### Шаг 4.1: log=[], active=[A1..A5], available_rows=8

```
→ operations: active.set([A1, A2, A3, A4, A5]); active.render(available_rows=8)
→ output: [A1, A2, A3, A4, A5]
```

### Шаг 4.2: active=[A1..A12] (превышает available_rows)

```
→ prev: [A1, A2, A3, A4, A5]
→ operations: active.set([A1..A12]); active.render(available_rows=8)
→ output: [A1, A2, A3, A4, A5, A6, A7, A8]
```

Зона рисуется всегда с `A1` сверху; первые 8 строк отрисованы, A9..A12
отсечены (вне видимой области).

### Шаг 4.3: active=[A1] (сжатие)

```
→ prev: [A1, A2, A3, A4, A5, A6, A7, A8]
→ operations: active.set([A1]); active.render(available_rows=8)
→ output: [A1, "", "", "", "", "", "", ""]
```

Предыдущая видимая высота = 8, новая = 1 → 7 blank. Всего 8 строк.

### Шаг 4.4: active=[] (полностью пустая зона)

```
→ prev: [A1, "", "", "", "", "", "", ""]
→ operations: active.set([]); active.render(available_rows=8)
→ output: ["", "", "", "", "", "", "", ""]
```

Зоны нет вообще — 7 blank (на основе prev_height=8, новая 0, разница 8, но
клампится к available_rows=8; 8−0=8, но prev_visible=8, visible=0, pad=8,
max_pad=8−0=8 → 8 blank).

---

## Тест 5: Синхронизация LogZone и ActiveZone

Проверяет инвариант: каждый flush LogZone вызывает перерисовку ActiveZone.
С включённой shift-логикой (Тест 6) blank-строки, оставшиеся от сжатия зоны,
поглощаются следующим log-push, поэтому экран не копит их.

### Шаг 5.1: log=[L1], active=[A1]

```
→ output: [L1, A1]
```

### Шаг 5.2: log=[L1, L2], active=[A1] (log растёт → active перерисовывается)

```
→ output: [L1, L2, A1]
```

### Шаг 5.3: active меняется на [A1, A2] одновременно с log=[L1, L2, L3]

```
→ output: [L1, L2, L3, A1, A2]
```

### Шаг 5.4: log не меняется, active=[A1] (сжатие → 1 blank)

```
→ output: [L1, L2, L3, A1, ""]
→ trailing_blanks: 1
```

### Шаг 5.5: log=[L1..L5], active=[A1..A3] (shift поглощает 1 blank)

```
→ prev: [L1, L2, L3, A1, ""]
→ operations: shift ×2 (L4, L5); log.flush([L1..L5]); active.set([A1..A3]); active.render(available_rows=∞)
→ output: [L1, L2, L3, L4, L5, A1, A2, A3]
→ trailing_blanks: 0
```

2 новых log-строки (L4, L5). Первая поглощает 1 trailing blank (shift),
высота не растёт. Второй shift невозможен (blanks=0) → экран растёт на 1.
Затем активная зона выросла с 1 до 3 — дорисованы A2, A3. Итого 8 строк.

---

## Тест 6: Log shift — поглощение trailing blanks

Когда активная зона сжалась, за ней остаются пустые строки (blank). При
следующем пуше в LogZone каждая новая log-строка **поглощает** одну blank:
активная зона сдвигается вверх на экране, blank удаляется, общая высота экрана
не растёт. Это продолжается, пока blanks не закончатся — дальше экран растёт
нормально (или скроллит).

**API:** `ActiveZone#trailing_blanks : Int32` — сколько blank-строк за зоной
можно поглотить. `ActiveZone#shift_available? : Bool` — алиас для
`trailing_blanks > 0`. После каждого log-push, если `shift_available?`,
оркестратор уменьшает `trailing_blanks` на 1 (через `consume_blank`).

### Шаг 6.1: log=[L1..L4], active=[A1..A3] (без viewport)

```
→ operations: log.flush([L1..L4]); active.set([A1, A2, A3]); active.render(available_rows=∞)
→ output: [L1, L2, L3, L4, A1, A2, A3]
→ trailing_blanks: 0, shift_available?: false
```

### Шаг 6.2: Сжать active до [A1] → 2 trailing blanks

```
→ prev: [L1, L2, L3, L4, A1, A2, A3]
→ operations: active.set([A1]); active.render(available_rows=∞)
→ output: [L1, L2, L3, L4, A1, "", ""]
→ trailing_blanks: 2, shift_available?: true
```

### Шаг 6.3: Добавить L5 (поглощается 1 blank)

```
→ prev: [L1, L2, L3, L4, A1, "", ""]
→ operations: active.consume_blank; log.flush([L1..L5]); active.set([A1]); active.render(available_rows=∞)
→ output: [L1, L2, L3, L4, L5, A1, ""]
→ trailing_blanks: 1, shift_available?: true
```

L5 встал в ряд 4 (где была A1). A1 сдвинулась в ряд 5 (где был blank).
Один blank поглощён. Высота экрана не изменилась (7).

### Шаг 6.4: Добавить L6 (поглощается последний blank)

```
→ prev: [L1, L2, L3, L4, L5, A1, ""]
→ operations: active.consume_blank; log.flush([L1..L6]); active.set([A1]); active.render(available_rows=∞)
→ output: [L1, L2, L3, L4, L5, L6, A1]
→ trailing_blanks: 0, shift_available?: false
```

L6 в ряд 5 (где была A1). A1 сдвинулась в ряд 6 (где был последний blank).
Blanks исчерпаны. Высота 7.

### Шаг 6.5: Добавить L7 (blanks кончились — экран растёт)

```
→ prev: [L1, L2, L3, L4, L5, L6, A1]
→ operations: log.flush([L1..L7]); active.set([A1]); active.render(available_rows=∞)
→ output: [L1, L2, L3, L4, L5, L6, L7, A1]
→ trailing_blanks: 0, shift_available?: false
```

Shift невозможен → обычный рост. Высота 8.

### Шаг 6.6: Расширить active до [A1..A4], затем сжать до [A1] (4 blanks)

```
→ prev: [L1, L2, L3, L4, L5, L6, L7, A1]
→ operations: active.set([A1, A2, A3, A4]); active.render(available_rows=∞)
→ output: [L1, L2, L3, L4, L5, L6, L7, A1, A2, A3, A4]
→ trailing_blanks: 0

→ operations: active.set([A1]); active.render(available_rows=∞)
→ output: [L1, L2, L3, L4, L5, L6, L7, A1, "", "", ""]
→ trailing_blanks: 3, shift_available?: true
```

Зона была 4, стала 1 → 3 blanks.

### Шаг 6.7: Добавить L8, L9, L10 (поглощаются все 3 blanks по очереди)

```
→ after L8:  [L1, L2, L3, L4, L5, L6, L7, L8, A1, "", ""]
→ after L9:  [L1, L2, L3, L4, L5, L6, L7, L8, L9, A1, ""]
→ after L10: [L1, L2, L3, L4, L5, L6, L7, L8, L9, L10, A1]
→ trailing_blanks: 0
```

Каждый push поглощает 1 blank. Высота экрана остаётся 11 на протяжении всех
трёх шагов. После L10 blanks исчерпаны.

### Шаг 6.8: Добавить L11 (рост)

```
→ output: [L1..L11, A1]
→ trailing_blanks: 0
```

Высота 12 — обычный рост.

---

## Тест 6b: Log shift + viewport (available_rows=8)

Те же правила shift, но зона клампится к available_rows.

### Шаг 6b.1: log=[L1..L4], active=[A1..A8] (заполняет viewport)

```
→ operations: log.flush([L1..L4]); active.set([A1..A8]); active.render(available_rows=8)
→ output: [L1, L2, L3, L4, A1, A2, A3, A4, A5, A6, A7, A8]
→ trailing_blanks: 0
```

### Шаг 6b.2: Сжать active до [A1] → 7 blanks

```
→ prev: [L1, L2, L3, L4, A1, A2, A3, A4, A5, A6, A7, A8]
→ operations: active.set([A1]); active.render(available_rows=8)
→ output: [L1, L2, L3, L4, A1, "", "", "", "", "", "", ""]
→ trailing_blanks: 7, shift_available?: true
```

### Шаг 6b.3: Добавить L5..L11 (поглощаются все 7 blanks)

```
→ after L5:  [L1, L2, L3, L4, L5, A1, "", "", "", "", "", ""]
→ after L6:  [L1, L2, L3, L4, L5, L6, A1, "", "", "", "", ""]
→ after L7:  [L1, L2, L3, L4, L5, L6, L7, A1, "", "", "", ""]
→ after L8:  [L1, L2, L3, L4, L5, L6, L7, L8, A1, "", "", ""]
→ after L9:  [L1, L2, L3, L4, L5, L6, L7, L8, L9, A1, "", ""]
→ after L10: [L1, L2, L3, L4, L5, L6, L7, L8, L9, L10, A1, ""]
→ after L11: [L1, L2, L3, L4, L5, L6, L7, L8, L9, L10, L11, A1]
→ trailing_blanks: 0
```

Высота экрана остаётся 12 на протяжении всех 7 шагов. Каждый push поглощает
1 blank, A1 сдвигается на 1 ряд вниз, blank исчезает.

### Шаг 6b.4: Добавить L12 (рост, blanks исчерпаны)

```
→ output: [L1..L12, A1]
→ trailing_blanks: 0
```

Высота 13.

---

## Тест 6c: Shift + рост зоны в процессе поглощения

Проверяет, что рост активной зоны во время shift перезаписывает blanks.

### Шаг 6c.1: log=[L1..L3], active=[A1..A5] → сжать до [A1] (4 blanks)

```
→ output: [L1, L2, L3, A1, "", "", "", ""]
→ trailing_blanks: 4
```

### Шаг 6c.2: Добавить L4 (shift, consume 1 blank)

```
→ output: [L1, L2, L3, L4, A1, "", "", ""]
→ trailing_blanks: 3
```

### Шаг 6c.3: Расширить active до [A1..A3] (рост перезаписывает blanks)

```
→ prev: [L1, L2, L3, L4, A1, "", "", ""]
→ operations: active.set([A1, A2, A3]); active.render(available_rows=∞)
→ output: [L1, L2, L3, L4, A1, A2, A3, ""]
→ trailing_blanks: 1
```

Зона выросла с 1 до 3 → A2 и A3 перезаписали 2 blanks. Остался 1 blank.
`trailing_blanks` пересчитан: было 3, 2 заняты ростом зоны → осталось 1.

### Шаг 6c.4: Добавить L5 (shift, consume последний blank)

```
→ output: [L1, L2, L3, L4, L5, A1, A2, A3]
→ trailing_blanks: 0
```

L5 поглотил последний blank. Высота 8.

---

## Сводка проверяемых инвариантов

| № | Инвариант |
|---|-----------|
| 0 | При пустом LogZone активная зона рисуется с ряда 0, без смещения |
| 1 | Рост зоны: дорисовка без blank; сжатие: blank = prev_visible − new_visible |
| 1 | Общее число строк экрана не уменьшается при сжатии зоны (blank заполняют) |
| 1 | Blank перезаписываются при следующем росте зоны или росте лога |
| 2 | Добавление лога перерисовывает активную зону; если есть trailing blanks — сдвигает её вверх (shift), иначе вниз |
| 3 | **available_rows = viewport − 2**: минимум 2 строки лога всегда видимы |
| 3 | Зона рисуется с `A1` сверху; при превышении available_rows рисуются первые available_rows строк, хвост отсекается |
| 3 | Blank-паддинг при сжатии клампится к available_rows |
| 4 | Зона выше viewport отсекается хвостом (A9..AX невидимы при X>available_rows) |
| 5 | Каждый flush LogZone → обязательная перерисовка ActiveZone |
| 6 | При сжатии зоны `trailing_blanks = prev_visible − new_visible` |
| 6 | Каждый push в LogZone поглощает 1 blank, если `shift_available?` |
| 6 | Пока есть blanks, высота экрана не растёт при добавлении логов |
| 6 | Рост активной зоны перезаписывает blanks, уменьшая `trailing_blanks` |
| 6 | Когда blanks исчерпаны — экран растёт (или скроллит) нормально |
