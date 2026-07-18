# Fix Edit — план доработки до паритета с JS

> Источник: `packages/agent-core-v2/src/app/edit/tools/edit.ts` + `edit.md`,
> `app/edit/editService.ts`, `app/edit/fileEdit.ts`, `app/edit/fileEditService.ts`,
> `app/edit/textModel.ts`.
> Текущий Crystal: `hcode.cr/src/tools/edit.cr`.

## Текущее состояние

- Имена параметров уже aligned через fallback (`path || filePath`,
  `old_string || oldString`, `new_string || newString`,
  `replace_all || replaceAll`).
- Базовая функциональность (exact-string match + optional replace-all)
  близка к паритету.
- **Нет** dynamic description с явными LF/CRLF / `\r` escape hints.
- **Нет** line-endings preservation (pure-CRLF файлов: matching на
  normalized LF, write-back в CRLF).
- **Нет** `TextModel` / `EditService` разделения (в JS это отдельные
  домены для multi-line editing и undo/redo).

## Целевой паритет (JS `EditTool`)

### 1. `parameters` — уже соответствует

```json
{
  "type": "object",
  "properties": {
    "path": { "type": "string", "description": "Path to the text file to edit. Relative paths resolve against the working directory; a path outside the working directory must be absolute." },
    "old_string": { "type": "string", "minLength": 1, "description": "Exact content to replace from the Read output view, without the line-number prefix. Use LF for pure CRLF files; use actual \\r escapes where Read shows \\r." },
    "new_string": { "type": "string", "description": "Replacement text in the same Read output view. LF is written back as CRLF only for pure CRLF files." },
    "replace_all": { "type": "boolean", "description": "Set true only when every occurrence of old_string should be replaced." }
  },
  "required": ["path", "old_string", "new_string"],
  "additionalProperties": false
}
```

### 2. `description` (verbatim, `edit.md`)

JS description включает явные hints:

- "Use LF for pure CRLF files" — для `old_string`.
- "use actual `\\r` escapes where Read shows `\\r`" — для mixed/lone-CR.
- "LF is written back as CRLF only for pure CRLF files" — для `new_string`.
- "If old_string occurs multiple times and replace_all is false, the
  edit fails" — behavior contract.

### 3. Path access policy

```crystal
safe_path = resolve_path_access_path(args.path, env: @env, workspace: @workspace, operation: "write")
accesses: ToolAccesses.write_file(safe_path)
approval_rule: literal_rule_pattern("Edit", safe_path)
matches_rule: matches_path_rule_subject(rule_args, safe_path, { cwd, home_dir, path_class })
```

### 4. `IFileEditService` delegation

В JS EditTool делегирует фактическую модификацию в App-scope
`IFileEditService`:

```crystal
result = @editor.edit(safe_path, old_string, new_string, replace_all)
```

`FileEditResult` variants:

- `:ok` — success, return new content snapshot.
- `:no_match` — `old_string` not found.
- `:multiple_matches` — `replace_all=false` но > 1 occurrence.
- `:io_error` — file not found / permission denied / etc.

### 5. Line-endings preservation (TextModel)

JS `TextModel`:

1. Читает raw bytes.
2. Определяет line-ending style (как в Read — CRLF/LF/mixed).
3. **Normalizes to LF** для matching: EOL в `old_string` (LF) match'ит
   как CRLF в файле.
4. Применяет replacement на normalized представлении.
5. При write-back — re-materializes в исходном style:
   - pure-CRLF → CRLF output.
   - mixed/lone-CR → raw bytes preserved except для exact replaced span.

В Crystal нужно либо:

- Полный port `TextModel` (over-engineered для MVP).
- Упрощённая реализация: detect style, if CRLF — transcode `old_string`
  и `new_string` под CRLF перед match, transcode результат обратно.

### 6. Simplified Crystal algorithm

```crystal
def execute(args, safe_path) : ToolResult
  raw = File.read(safe_path)
  style = detect_line_ending_style(raw)

  # Normalize file content + old/new strings под matching style.
  normalized = raw
  old_str = args.old_string
  new_str = args.new_string

  if style.crlf_only?
    # Если пользователь передал LF в old_string, транскодим в CRLF для match.
    normalized = raw.gsub("\r\n", "\n")
  else
    # mixed/lone-CR — match в raw виде.
  end

  count = normalized.scan(old_str).size
  when :no_match
    return ToolResult.error("old_string not found in file. Make sure it matches exactly, including whitespace and newlines.")
  when .multiple
    return ToolResult.error("old_string occurs #{count} times. Pass replace_all=true to replace all, or make old_string unique (e.g. include more surrounding context).") unless args.replace_all
  end

  updated = args.replace_all ? normalized.gsub(old_str, new_str) : normalized.sub(old_str, new_str)

  # Re-materialize в исходном style.
  final = style.crlf_only? ? updated.gsub("\n", "\r\n") : updated

  File.write(safe_path, final)
  ToolResult.success("Edited #{args.path}")
rescue ex : File::NotFoundError
  ToolResult.error("File not found: #{args.path}")
rescue ex
  ToolResult.error(ex.message || ex.to_s)
end
```

### 7. `detect_line_ending_style(content)`

Возвращает struct:

```crystal
struct LineEndingStyle
  property crlf_only : Bool
  property has_lone_cr : Bool

  def crlf_only? : Bool
    @crlf_only && !@has_lone_cr
  end

  def mixed? : Bool
    @has_lone_cr || (@crlf_only && has_lf_only?)
  end
end
```

См. `md-tools/fix-read.md` §4.5 — общий алгоритм.

---

## 8. План реализации (чек-лист)

- [ ] Прочитать JS: `edit.ts`, `edit.md`, `editService.ts`,
      `fileEdit.ts`, `fileEditService.ts`, `textModel.ts`.
- [x] Описать фикс-план в `md-tools/fix-edit.md`.
- [ ] Убедиться, что `parameters` уже соответствует (§1).
- [ ] Расширить `description` (§2) — hints для LF/CRLF / `\r` escape.
- [ ] Подключить `resolve_path_access_path(operation: "write")` +
      `accesses: ToolAccesses.write_file`.
- [ ] Реализовать `detect_line_ending_style` (shared с Read).
- [ ] Реализовать CRLF-transcoding для matching (§6).
- [ ] Реализовать no-match / multiple-matches / replace_all semantics.
- [ ] Реализовать re-materialization в исходном style.
- [ ] Тесты в `spec/tools/edit_spec.cr`:
  - [ ] Simple replace.
  - [ ] replace_all = false → multiple match reject.
  - [ ] replace_all = true → all replaced.
  - [ ] No-match → error.
  - [ ] Pure-CRLF file: LF в old_string match'ит CRLF в файле,
        write-back в CRLF.
  - [ ] Mixed line-endings: lone-CR сохраняется.
  - [ ] Path access policy reject.
  - [ ] File-not-found error.
- [ ] Обновить `FIX-TOOLS.md`: отметить Edit-строку выполненной.

---

## 9. Расхождения / дополнения

- JS делит на `EditService` (pure logic, без IO) + `FileEditService`
  (IO adapter). В Crystal — один класс `Tools::Edit`, делающий и logic,
  и IO. Можно отрефакторить позже.
- `TextModel` в JS — полноценная модель для multi-line text editing с
  undo/redo. В Crystal MVP не нужно — простого String#scan/sub/gsub
  достаточно для контракта.
- "no-op pre-check": если `old_string == new_string` — early-return без
  IO. В JS это отдельная ветка. В Crystal добавить:
  ```crystal
  return ToolResult.error("old_string and new_string are identical; nothing to do.") if args.old_string == args.new_string
  ```
- Skill-roots workspace extension — опускается.
- `replace_all=false` default — уже соблюдается через
  `read_bool(default: false)`.
- BOM preservation — если файл начинается с UTF-8 BOM, preserve его
  при write-back. Crystal `File.read` не strip'ает BOM автоматически —
  он остаётся в `raw`. ОК.
