# Fix Write — план доработки до паритета с JS

> Источник: `packages/agent-core-v2/src/os/backends/node-local/tools/write.ts` + `write.md`.
> Текущий Crystal: `h2code.cr/src/tools/write.cr`.

## Текущее состояние

- Имена параметров уже aligned (`path`, `content`) — обратной
  совместимости не требуется (JS тоже использует `path` / `content`).
- **Нет `mode: append`** — только overwrite.
- **Нет проверки "родитель — не директория"** — если `path` указывает на
  путь, чей родитель — файл, упадёт с системной ошибкой вместо
  осмысленного сообщения.
- **Нет path access policy** — не использует `resolve_path_access_path`
  для write-операции (см. `src/tools/path_access.cr`).

## Целевой паритет (JS `WriteTool`)

### 1. `parameters` — добавить `mode`

```json
"mode": {
  "type": "string",
  "enum": ["overwrite", "append"],
  "description": "Write mode. Defaults to overwrite. append adds content to the end exactly as provided and does not add a newline."
}
```

### 2. `description` (verbatim, `write.md`)

JS `write.md` — расширенный текст про:

- "Raw full file content to write exactly as provided."
- Append mode: "does not add a newline".
- "Missing parent directories are created automatically."

### 3. Path access policy

```crystal
def resolve_execution(args)
  safe_path = resolve_path_access_path(args.path, env: @env, workspace: @workspace, operation: "write")
  {
    accesses: ToolAccesses.write_file(safe_path),
    description: "Writing #{args.path}",
    display: { kind: "file_io", operation: "write", path: safe_path, content: args.content },
    approval_rule: literal_rule_pattern("Write", safe_path),
    matches_rule: matches_path_rule_subject(rule_args, safe_path, { cwd, home_dir, path_class }),
    execute: ->execution(args, safe_path),
  }
end
```

### 4. `ensure_parent_directory(safe_path) : String?`

Возвращает `nil` если ОК, иначе error message.

```crystal
private def ensure_parent_directory(safe_path : String) : String?
  parent = File.dirname(safe_path)

  begin
    stat = File.stat(parent)
  rescue ex : File::NotFoundError
    # Родителя нет — создаём рекурсивно.
    begin
      Dir.mkdir_p(parent)
      return nil
    rescue mkdir_ex
      return mkdir_ex.message || mkdir_ex.to_s
    end
  end

  # Родитель есть, но это не директория.
  return "Parent path is not a directory: #{parent}." unless Dir.exists?(parent)
  nil
end
```

### 5. `execute` — алгоритм

```crystal
def execute(args, safe_path) : ToolResult
  parent_error = ensure_parent_directory(safe_path)
  return ToolResult.error(parent_error) if parent_error

  mode = args.mode || "overwrite"
  begin
    case mode
    when "append"
      File.write(safe_path, args.content, mode: "a")
    else  # "overwrite"
      File.write(safe_path, args.content)
    end

    bytes_written = args.content.bytes.size
    verb = mode == "append" ? "Appended" : "Wrote"
    ToolResult.success("#{verb} #{bytes_written} bytes to #{args.path}")
  rescue ex : File::NotFoundError
    ToolResult.error("Failed to write #{args.path}: parent directory does not exist.")
  rescue ex
    ToolResult.error(ex.message || ex.to_s)
  end
end
```

### 6. Append semantics

- `File.write(path, content, mode: "a")` — `O_APPEND` semantics
  (atomic относительно concurrent writers).
- Не добавляет trailing newline.
- Если файла нет — он создаётся.

---

## 7. План реализации (чек-лист)

- [ ] Прочитать JS: `write.ts` (полностью), `write.md`.
- [x] Описать фикс-план в `md-tools/fix-write.md`.
- [ ] Расширить `Tools::Write#parameters` (§1): добавить `mode`.
- [ ] Расширить `description` (§2): дописать append + auto-mkdir параграф.
- [ ] Подключить `resolve_path_access_path` (write-операция) из
      `src/tools/path_access.cr`.
- [ ] Реализовать `ensure_parent_directory` (§4) с `Dir.mkdir_p` для
      отсутствующего родителя и reject для non-directory родителя.
- [ ] Реализовать append-mode через `File.write(..., mode: "a")`.
- [ ] В output сообщать `bytesWritten` (UTF-8 bytes от `content.bytes.size`).
- [ ] Добавить `accesses: ToolAccesses.write_file(path)` в tool execution
      descriptor.
- [ ] Тесты в `spec/tools/write_spec.cr`:
  - [ ] Overwrite существующего файла.
  - [ ] Создание нового файла.
  - [ ] Append в существующий файл (без добавления newline).
  - [ ] Append в несуществующий файл → создаётся.
  - [ ] `ensure_parent_directory` — parent отсутствует → auto-mkdir.
  - [ ] `ensure_parent_directory` — parent это файл → reject с
        `"Parent path is not a directory: ..."`.
  - [ ] Path access policy — relative path escaping workspace → reject.
  - [ ] `bytesWritten` correct (UTF-8 byte count, не char count).
- [ ] Обновить `FIX-TOOLS.md`: отметить Write-строку выполненной.

---

## 8. Расхождения / дополнения

- `dirname` (pathe) vs `File.dirname` — Crystal использует host OS
  semantics. На Linux/Mac разницы нет; на Windows `\\` vs `/`.
- `HostFileStat.isDirectory` — Crystal `Dir.exists?` (более прямой путь).
- Skill-catalog workspace extension (`extendWorkspaceWithSkillRoots`) —
  опускается (skill-roots пока не подключены).
- В JS `fs.appendText` — native O_APPEND. Crystal `File.write(..., mode: "a")`
  тоже использует append-mode. Атомарность на той же уровне.
- `Buffer.byteLength(content, "utf8")` → Crystal `content.bytes.size`.
- Path access policy — текущий `src/tools/path_access.cr` уже
  реализует `resolve_path_access_path`; нужно просто вызвать с
  `operation: "write"`.
