# TUI Fixes — Plan of Implementation

План фиксов багов из `TUI_BUGS.md`. Каждый фик — отдельный шаг: код, тест,
проверка сборки. Шаги упорядочены по критичности и зависимостям: фундамент
(width infrastructure) → consumer fixes → edge cases.

---

## Phase 1 — Width safety net (фундамент)

Эти фиксы дают инфраструктуру, на которую опираются остальные.

### Step 1.1 — Overwide-line truncation в `diff_render` / `full_render`

**Баг:** `TUI_BUGS.md` №1 — строки шире терминала выводятся как есть.

**Подход:** Перед выводом в `full_render` и `diff_render` транкаем каждую строку
до `cols` через `CharWidth.slice_by_column`. Повторяет JS `doRender`
(tui.ts:1296-1303), но без Kitty-image логики (её нет в Crystal).

**Файлы:**
- `src/tui/app.cr` — `build_rendered_lines` (app.cr:1942): добавить транкацию
  `new_lines` в конце метода, перед return. Это покрывает оба пути
  (`full_render` и `diff_render`) одной точкой.
- Использовать fast path: `CharWidth.ascii_visible_width(line, cols) ??
  CharWidth.visible_width(line)` → если `> cols`, то
  `CharWidth.slice_by_column(line, 0, cols, strict: true)`.

**Тест** (`spec/tui/app_spec.cr`):
- Сгенерировать `new_lines` со строкой шире `cols` (например ANSI + CJK),
  вызвать `build_rendered_lines`, проверить что ни одна строка не шире `cols`.
- Замечание: `build_rendered_lines` приватный — тестировать через
  `render_message` или через ivar-доступ как в существующих тестах.

**Риски:** `slice_by_column` с `strict: true` может разрезать wide-графем на
границе. JS делает то же самое — это приемлемо для защитного барьера.

---

### Step 1.2 — `applyLineResets` — гарантия `\e[0m` на конце строк

**Баг:** `TUI_BUGS.md` №7 — нет гарантии сброса SGR.

**Подход:** Добавить приватный метод `apply_line_resets(lines : Array(String))`
который добавляет `ANSI.reset` в конец каждой строки, если его ещё нет. Вызывать
в `build_rendered_lines` сразу после Step 1.1 (транкации), перед возвратом.

**Файлы:**
- `src/tui/app.cr` — новый `private def apply_line_resets`, вызов в
  `build_rendered_lines`.

**Тест** (`spec/tui/app_spec.cr`):
- Вручную создать `Message` с контентом, который рендерится без завершающего
  `ANSI.reset` (если такой сценарий существует), либо проверить что
  `build_rendered_lines` всегда оканчивается на reset.

---

## Phase 2 — Consumer fixes (исправляют видимые баги)

### Step 2.1 — `wrap_text` использовать `visible_width` вместо `.size`

**Баг:** `TUI_BUGS.md` №2 — CJK/эмодзи строки не переносятся.

**Подход:** В `wrap_text` (app.cr:3413) заменить `line.size` на
`CharWidth.visible_width(line)`, а `word.size` — на
`CharWidth.visible_width(word)`. Добавить hard-break для слов длиннее `max_width`
(через `CharWidth.truncate_to_width` или посимвольный разрез).

**Файлы:**
- `src/tui/app.cr:3413` — `wrap_text`.

**Тест** (`spec/tui/app_spec.cr`):
- `wrap_text` приватный — тестировать через `render_message` с CJK-контентом:
  строка из 20 японских символов при `cols=40` должна дать 2+ строки, каждая не
  шире `cols - bullet_w`.

---

### Step 2.2 — `title_visible` учитывать ANSI

**Баг:** `TUI_BUGS.md` №3 — расчёт ширины план-бокса с ANSI.

**Подход:** В `title_visible` (app.cr:2458) вернуть `title`, но в вызывающем
коде (app.cr:2440) использовать `CharWidth.visible_width(title)` вместо
`.size`. Метод `title_visible` можно удалить или сделать его возвращающим
`visible_width` напрямую.

**Файлы:**
- `src/tui/app.cr:2458` — `title_visible` → использовать `visible_len`.
- `src/tui/app.cr:2440` — `title_display.size` → `visible_len(title)`.

**Тест** (`spec/tui/app_spec.cr`):
- Проверить `render_plan_box` с Rejected-бейджем: ширина верхней рамки равна
  нижней.

---

### Step 2.3 — Single-grapheme guard в `wrap_editor_line`

**Баг:** `TUI_BUGS.md` №4 — неделимый графем шире `max_w` вызывает смещение.

**Подход:** В `wrap_editor_line` (app.cr:2827), в force-break ветке, проверить:
если чанк состоит из одного кластера и его ширина `> max_w`, оставить как есть
(не разрезать). Аналог editor.ts:172-181.

Конкретно: после строк 2834-2840 добавить проверку — если `chunk_start == idx`
(то есть чанк начнётся с этого кластера) и `w > max_w`, пропустить force-break,
просто добавить кластер в текущий чанк.

**Файлы:**
- `src/tui/app.cr:2791` — `wrap_editor_line`.

**Тест** (`spec/tui/editor_spec.cr` или `app_spec.cr`):
- Вызвать `wrap_editor_line` с одним CJK-символом при `max_w=1`, проверить что
  возвращается один чанк (а не краш/пустота).

---

## Phase 3 — Robustness (нижний приоритет)

### Step 3.1 — Width cache: O(1) eviction через индекс-очередь

**Баг:** `TUI_BUGS.md` №5 — FIFO eviction O(n) на Hash.

**Подход:** Заменить `Hash#first_key?` + `delete` на связный список или
двухструктурный подход: `Hash(String, {width, order_index})` +
`Deque(String)` для FIFO-порядка. eviction берёт `Deque#shift` (O(1)) и удаляет
из Hash.

Альтернатива (проще): ограничить кэш мягко — при достижении лимита очищать весь
кэш (`clear`) вместо逐个 удаления. Это амортизирует eviction O(n) до O(1)
на_insert (n операций по O(1), потом одна O(n) очистка, снова n по O(1)).

**Файлы:**
- `src/tui/char_width.cr:27-40` — `cache_put`, `@@width_cache`.

**Тест** (`spec/tui/char_width_spec.cr`):
- Существующий тест cache уже есть (строка 75). Добавить тест на заполнение
  >4096 записей и проверку что кэш не растёт бесконечно.

**Приоритет:** Низкий. Реальный impact только при стриминге тысяч строк.

---

### Step 3.2 — `@max_lines_rendered` сброс при усадке

**Баг:** `TUI_BUGS.md` №6 — фантомные строки при усадке контента.

**Подход:** В `full_render` (app.cr:2129) `@max_lines_rendered` уже
устанавливается в `new_lines.size`. Проблема в том, что `content_shrunk`
проверяется через `<` (строка 1991), а после `full_render` максимум
сбрасывается. Это **уже корректно** при повторном вызове.

Перепроверить: если `content_shrunk` не сработает (равные размеры), diff_render
оставит фантомы. Добавить в `diff_render` (после строки 2218) проверку: если
`new_size < @max_lines_rendered`, вызвать `full_render` вместо продолжения.

**Файлы:**
- `src/tui/app.cr:2135` — `diff_render`, ранняя проверка `content_shrunk`.

**Тест** (`spec/tui/app_spec.cr`):
- Сценарий: контент растёт до N строк, потом усаживается до N-2 без смены
  размера терминала. Проверить что `@max_lines_rendered` сбросился.

---

### Step 3.3 — `render_welcome_box` clamp на узкую ширину

**Баг:** `TUI_BUGS.md` №10 — лого выходит за границу при `cols < 14`.

**Подход:** В `render_welcome_box` (app.cr:2606) добавить `box_w = {14, cols}.max`
(минимальная ширина для лого) или скрывать лого при `cols < 14`.

**Файлы:**
- `src/tui/app.cr:2606`.

**Приоритет:** Низкий — welcome-экран при ширине <14 — экзотика.

---

### Step 3.4 — `break_long_token` использовать `grapheme_width`

**Баг:** `TUI_BUGS.md` №9 — VS16/ZWJ не учитываются при разрыве токенов.

**Подход:** В `break_long_token` (markdown.cr:655) заменить
`CharWidth.codepoint_width(c)` на walk по графем-кластерам. Однако это
усложняет метод. Альтернатива: оставить как есть (edge-case), зафиксировать в
комментарии.

**Файлы:**
- `src/tui/markdown.cr:637`.

**Приоритет:** Низкий — узкий случай.

---

### Step 3.5 — `extract_last_color` поддержка OSC/APC

**Баг:** `TUI_BUGS.md` №8 — только CSI.

**Подход:** Использовать `CharWidth.extract_ansi_code` вместо ручного скана.
Однако `extract_last_color` возвращает последнее SGR-значение, а не любой
escape — OSC не несёт цвет. Оставить как есть, зафиксировать ограничение.

**Приоритет:** Низкий — OSC в тексте сообщений почти не встречается.

---

## Порядок выполнения

```
Step 1.1 (truncate overwide)  ← фундамент, разовая точка
Step 1.2 (applyLineResets)    ← фундамент, зависит от 1.1
Step 2.1 (wrap_text width)    ← высокий impact
Step 2.2 (title_visible)      ← простой, изолированный
Step 2.3 (grapheme guard)     ← изолированный
Step 3.1 (cache eviction)     ← по желанию
Step 3.2 (max_lines_rendered) ← проверить, возможно уже ок
Step 3.3-3.5                  ← низший приоритет
```

## Тестирование после каждого шага

```sh
crystal spec spec/tui/              # все TUI-тесты
crystal build src/hcode.cr          # сборка
./hcode -p "test"                   # smoke-тест (headless)
```

После Phase 1+2 — полный прогон в реальном терминале:
```sh
./hcode   # проверить CJK, эмодзи, длинные строки, узкий терминал
```

---

## Что НЕ делать

- Не добавлять Kitty-image поддержку (нет в Crystal-версии).
- Не переписывать diff-рендер целиком — только точечные фиксы.
- Не менять `CharWidth` API без обратной совместимости (его используют
  markdown, editor, app).
- Не трогать JS-версию в `kimi-code/`.
