# Fix Glob — план доработки до паритета с JS

> Источник: `packages/agent-core-v2/src/os/backends/node-local/tools/glob.ts` + `glob.md`.
> Текущий Crystal: `kimi.cr/src/tools/glob.cr`.

## Текущее состояние

- Glob близок к паритету.
- Поддерживаются `pattern`, `path` (cwd-default), `limit`, `offset`.
- Возвращает `<path>` lines, отсортированные lexicographically.

## Оставшиеся расхождения (минорные / низкий приоритет)

### 1. Windows path handling — out-of-scope

JS `glob.ts`:

- `windowsPathToPosix` — конвертирует `C:\foo\bar` → `/c/foo/bar`.
- Path separator normalization.

В Crystal:

- Linux-first MVP — не требуется.
- На macOS/Windows — `File::SEPARATOR` уже корректен.

FIX-TOOLS помечает это как **низкий приоритет** — отложить.

### 2. Description verbatim из `glob.md`

JS `glob.md`:

```
Fast file pattern matching using glob patterns.

Supports standard glob patterns:
- `*` matches any sequence of non-separator characters
- `**` matches any sequence of characters (including separators)
- `?` matches any single non-separator character
- `{abc,def}` matches either `abc` or `def`
- `[abc]` matches one of the characters listed

Use this tool when you need to find files by name pattern. For content search, use Grep instead.

Paths are returned as absolute paths, one per line, sorted lexicographically. The `path` argument specifies the root directory to search from; if omitted, the current working directory is used.

`limit` caps the number of results (default 100); `offset` skips the first N results for pagination.

Hidden files (starting with `.`) are included in the results by default.
```

Текущий Crystal description — короче. Можно расширить для parity.

### 3. Hidden files inclusion

JS включает dotfiles by default (без `.git` directory). Crystal —
проверить поведение `Dir.glob`:

- `Dir.glob("#{root}/**/*")` исключает dotfiles.
- `Dir.glob("#{root}/**/.*")` включает только dotfiles.

Нужно использовать оба паттерна или явный флаг.

### 4. `.git` directory skip

JS не обходит `.git`, `node_modules` (последнее — опционально).

Crystal — добавить skip-list:

```crystal
SKIP_DIRS = [".git", ".hg", ".svn"]
```

### 5. Symlinks

JS — `followSymlinks: false` (default). Crystal `Dir.glob` — по
умолчанию не следует symlinks (но зависит от platform).

### 6. `limit` / `offset` defaults

| Parameter | JS default | Crystal current |
|-----------|------------|-----------------|
| `limit`   | `100`      | проверить       |
| `offset`  | `0`        | проверить       |

---

## 7. План реализации (чек-лист)

- [ ] Прочитать JS: `glob.ts`, `glob.md`.
- [x] Описать фикс-план в `md-tools/fix-glob.md`.
- [ ] **Аудит `src/tools/glob.cr`** — отметить, какие пункты уже
      реализованы.
- [ ] Расширить `description` до verbatim `glob.md`.
- [ ] Подтвердить inclusion dotfiles (добавить явный `.*` glob if needed).
- [ ] Подтвердить `.git` skip.
- [ ] Подтвердить defaults `limit=100`, `offset=0`.
- [ ] (Опционально, low-priority) Windows path normalization.
- [ ] Тесты в `spec/tools/glob_spec.cr`:
  - [ ] Basic pattern.
  - [ ] Recursive `**`.
  - [ } Brace expansion `{a,b}`.
  - [ ] Character class `[abc]`.
  - [ ] Hidden files included.
  - [ ] `.git` directory excluded.
  - [ ] `limit` cap.
  - [ ] `offset` pagination.
- [ ] Обновить `FIX-TOOLS.md`: отметить Glob-строку выполненной (или
      "near-parity, Windows paths out-of-scope").

---

## 8. Расхождения / дополнения

- Glob — наименее проблемный тул. FIX-TOOLS явно помечает "низкий
  приоритет", "при необходимости добавить Windows-специфичную
  обработку".
- На Linux/Unix платформах — паритет достигается минорными правками
  (description + hidden-files + `.git` skip).
- `Dir.glob` vs `Find.find` — glob быстрее для pattern-based search,
  но не поддерживает inline-dotfile inclusion. Возможные подходы:
  - Запустить два glob'а (для обычных и dotfiles).
  - Использовать `crystal-glob` shard с extended semantics.
  - `Find.find` + ручная фильтрация по pattern.
- Symlinks — Crystal `Dir.glob` не следует symlinks по умолчанию.
- Absolute path output — `File.expand_path` нормализует.
