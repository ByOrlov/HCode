# Fix Read — план доработки до паритета с JS

> Источник: `packages/agent-core-v2/src/os/backends/node-local/tools/read.ts`
> + `read.md`, `_base/text/line-endings.ts`, `agent/media/file-type.ts`.
> Текущий Crystal: `hcode.cr/src/tools/read.cr`, `hcode.cr/src/tools/line_endings.cr`.

## Текущее состояние

- Имена параметров уже aligned через fallback (`path || filePath`,
  `line_offset || offset`, `n_lines || limit`) — обратная совместимость
  сохранена.
- Стартовый `offset` положительный.
- Нет tail-offset (negative `line_offset`).
- Нет binary/NUL detect.
- Нет detect-image/video redirect.
- Нет line-endings обработки (CRLF normalisation, lone-CR render).
- Нет line-length truncation (`MAX_LINE_LENGTH` = 2000).
- Нет `<system>` note side-channel.

## Целевой паритет (JS `ReadTool`)

### 1. Константы

| Имя                 | Значение       |
|---------------------|----------------|
| `MAX_LINES`         | `1000`         |
| `MAX_LINE_LENGTH`   | `2000`         |
| `MAX_BYTES`         | `100 * 1024`   |
| `MEDIA_SNIFF_BYTES` | `4096`         |

### 2. `parameters` — расширить `line_offset`

```json
"line_offset": {
  "type": "number",
  "description": "The line number to start reading from. Omit to start at line 1. Negative values read from the end of the file; the absolute value cannot exceed 1000."
}
```

`line_offset` union:

- positive: `>= 1`.
- negative: `>= -MAX_LINES && <= -1`.

### 3. `description` — расширить hint

В текущем Crystal description — короткий. JS `read.md` — развёрнутый,
с явным упоминанием:

- line-numbered `<n>\t<content>` format.
- `MAX_LINES = 1000`, `MAX_LINE_LENGTH = 2000`, `MAX_BYTES` cap.
- Binary/NUL → redirect на ReadMediaFile / Bash.
- Line-ending normalization hint.
- Дляpaging — использовать `line_offset`/`n_lines`.

### 4. `execute` — алгоритм

#### 4.1. Path resolve

`resolve_path_access_path(path, env, workspace, "read")` через shared
resolver. `accesses = ToolAccesses.read_file(path)`.

#### 4.2. File-type detect (новое)

Прочитать первые `MEDIA_SNIFF_BYTES` байт:

```crystal
header = fs.read_bytes(safe_path, 0, MEDIA_SNIFF_BYTES)
file_type = detect_file_type(safe_path, header, "text")

case file_type.kind
when .image?
  return ToolResult.error("\"#{path}\" is an image file. Use ReadMediaFile to read images.")
when .video?
  return ToolResult.error("\"#{path}\" is a video file. Use ReadMediaFile to read videos.")
when .text?
  # continue — это текстовый файл (включая UTF-8 с BOM и т.п.)
when .unknown?
  return ToolResult.error("\"#{path}\" is not a UTF-8 text file. Use Bash or an appropriate tool for binary formats.")
end
```

`detect_file_type` — shared helper из `read_media.cr` /
`file_type.cr`.

#### 4.3. NUL-byte detect

При чтении проверять первые (например) 8 KiB на NUL:

```crystal
if content[0, 8192].includes?('\0')
  return ToolResult.error("\"#{path}\" appears to be a binary file (NUL byte detected). Use Bash or an appropriate tool for binary formats.")
end
```

#### 4.4. Negative `line_offset` (tail mode)

```crystal
start_line =
  if line_offset && line_offset < 0
    # negative: read last |offset| lines
    total = count_lines(safe_path)
    from_end = {-line_offset, MAX_LINES}.min
    [1, total - from_end + 1].max
  else
    line_offset || 1
  end
```

Абсолют `|line_offset|` не больше `MAX_LINES`.

#### 4.5. Line-ending flags

При streaming-чтении собирать 3 флага:

```crystal
struct LineEndingFlags
  property has_crlf : Bool = false
  property has_lf : Bool = false
  property has_lone_cr : Bool = false
end
```

Для каждого символа в потоке:

- `\r` за которым следует `\n` → `has_crlf = true`.
- `\n` без предшествующего `\r` → `has_lf = true`.
- `\r` без последующего `\n` → `has_lone_cr = true`.

Style определяется так:

| has_crlf | has_lf | has_lone_cr | style              |
|----------|--------|-------------|--------------------|
| true     | false  | false       | `"crlf"`           |
| any      | any    | true        | `"mixed"`          |
| иначе    | true   | false       | `"lf"`             |
| иначе    | false  | false       | `"lf"` (default)   |

#### 4.6. Render line

Каждая строка рендерится как `<line-number>\t<content>`:

```crystal
rendered = "#{line_no}\t#{maybe_truncate_line(strip_lf(raw))}"
```

`maybe_truncate_line(line)`:

```crystal
def truncate_line(line : String, max_length = MAX_LINE_LENGTH) : String
  return line if line.size <= max_length
  marker = "..."
  target = {max_length, marker.size}.max
  line[0, target - marker.size] + marker
end
```

CRLF normalize для отображения: pure-CRLF файлы показываются с LF
(в output); lone-CR показываются как `\r` (literal).

`make_carriage_returns_visible(text)`:

- pure CRLF style → replace `\r\n` → `\n`.
- mixed / lone-CR → replace lone `\r` на literal `\r` (3-char).

#### 4.7. Caps — `MAX_LINES` / `MAX_BYTES`

- После `MAX_LINES` строк — stop, `max_lines_reached = true`.
- После `MAX_BYTES` байт — stop, `max_bytes_reached = true`.
- `requested_lines = n_lines || MAX_LINES`.
- `total_lines` — precount через быстрый scan.

#### 4.8. `<system>` note (side channel)

После рендера строится `<system>` блок:

```crystal
note = build_read_system_note(
  line_count: rendered_lines.size,
  truncated_line_numbers: ...,
  max_lines_reached: ...,
  max_bytes_reached: ...,
  line_ending_style: style,
  start_line: start_line,
  total_lines: total_lines,
  requested_lines: requested_lines
)
```

Содержание `<system>...</system>`:

- Read summary:
  - `Read lines #{start_line}-#{start_line + n - 1} (of #{total_lines}).`
  - Если запрошено больше — `Requested #{requested} lines.`
- Truncation:
  - `Lines truncated to #{MAX_LINE_LENGTH} chars: #{truncated_numbers.join(", ")}.`
- Caps hit:
  - `Reached the #{MAX_LINES}-line cap; use line_offset to continue.`
  - `Reached the #{format_bytes(MAX_BYTES)} byte cap; use line_offset to continue.`
- Line-endings:
  - `"This file uses CRLF line endings; displayed with LF."` для crlf-only.
  - `"This file uses mixed line endings; lone carriage returns shown as \\r."` для mixed.

Join через `" "`. Обернуть в `<system>...</system>`.

В Crystal `ToolResult` нужно расширить полем `note : String?`.

---

## 5. План реализации (чек-лист)

- [ ] Прочитать JS: `read.ts` (полностью), `read.md`,
      `_base/text/line-endings.ts`, `agent/media/file-type.ts`.
- [x] Описать фикс-план в `md-tools/fix-read.md`.
- [ ] Расширить `Tools::Read#parameters`: `line_offset` с negative range,
      description с caps hint.
- [ ] Реализовать `detect_file_type` (shared с `read_media.cr`):
      magic-byte sniffing PNG/JPEG/GIF/WebP/MP4/WebM и UTF-8 text.
- [ ] Реализовать NUL-byte detect.
- [ ] Реализовать tail-offset (`line_offset < 0`).
- [ ] Реализовать `LineEndingFlags` + style resolver.
- [ ] Реализовать `truncate_line` (`MAX_LINE_LENGTH = 2000`).
- [ ] Реализовать `make_carriage_returns_visible`.
- [ ] Реализовать caps enforcement (`MAX_LINES`, `MAX_BYTES`).
- [ ] Расширить `ToolResult` полем `note : String?`.
- [ ] Реализовать `build_read_system_note` (формат verbatim из JS).
- [ ] Тесты в `spec/tools/read_spec.cr`:
  - [ ] basic read с line numbers.
  - [ ] tail-offset (negative).
  - [ ] CRLF-only → LF render + note.
  - [ ] Mixed line-endings → lone CR visible.
  - [ ] Long line → truncation marker.
  - [ ] > MAX_LINES → cap reached note.
  - [ ] Binary/NUL → reject.
  - [ ] Image file → redirect to ReadMediaFile.
  - [ ] `<system>` note content checks.
- [ ] Обновить `FIX-TOOLS.md`: отметить Read-строку выполненной.

---

## 6. Расхождения / дополнения

- `extendWorkspaceWithSkillRoots` — Crystal workspace не имеет
  skill-roots концепции; опускается.
- Path access policy уже есть в `src/tools/path_access.cr` — переиспользовать.
- `ISessionSkillCatalog` не нужен (skills пока не подключены).
- `unwrapErrorCause` — Crystal `ex.cause` chain.
- `MAX_BYTES` — это per-call byte cap, не per-line. На уровне IO
  reading-loop проверять накопленный размер.
- `total_lines` precount — отдельный fast-scan, либо сканировать
  во время чтения и обновлять note после (но тогда нужен второй pass).
- `<system>` блок — добавляется в `Context::Memory` через injection
  mechanism (не в основной output).
- BOM (UTF-8/16 BOM) — detect и strip в JS. В Crystal — `Bytes[0xEF,
  0xBB, 0xBF]` для UTF-8.
