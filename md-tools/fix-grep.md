# Fix Grep — план доработки до паритета с JS

> Источник: `packages/agent-core-v2/src/os/backends/node-local/tools/grep.ts`
> + `grep.md`, `runRg.ts`, `rgLocator.ts`.
> Текущий Crystal: `hcode.cr/src/tools/grep.cr`, `hcode.cr/src/tools/run_rg.cr`,
> `hcode.cr/src/tools/sensitive.cr`.

## Текущее состояние (уже в паритете на 95%)

Реализовано:

- `pattern`, `path`, `glob`, `type`, `output_mode` (3 значения).
- `-i`, `-n`, `-A`, `-B`, `-C`.
- `head_limit` (default 250, 0=unlimited), `offset`.
- `multiline`, `include_ignored`.
- Sensitive-file filtering (`Sensitive.sensitive?`) + отображение
  "Filtered N sensitive file(s): ..." messages.
- VCS metadata (`.git`) skipping.
- mtime-sorting для `files_with_matches`.
- DEFAULT_TIMEOUT_S = 20, MAX_OUTPUT_BYTES = 10 MiB.

## Оставшиеся расхождения (минорные)

### 1. Description text

JS `grep.md` — более развёрнутый, с явным упоминанием:

- "Matched against each file's full absolute path, so a path-anchored
  pattern like `src/**/*.ts` silently matches nothing — use a basename
  pattern (`*.ts`), or anchor with `**/` (`**/src/**/*.ts`)".
- "Prefer this over `glob` when filtering by language" — для `type`.
- Для `output_mode` — детальное описание трёх вариантов с примерами.
- `head_limit`: "Pass 0 for unlimited."
- `include_ignored`: "Sensitive files (such as `.env`) remain filtered
  out for safety. VCS metadata directories (`.git` and similar) are
  always skipped, even when this is true."

### 2. Дополнительные параметры-флаги (опционально)

В JS также есть:

- `glob` — может быть массивом (`z.array(z.string()).optional()`),
  но в текущей форме string — это норма.

Текущая Crystal-схема принимает string-only, что соответствует
большинству usage. Если нужна multi-glob поддержка — расширить.

### 3. Sorting behavior для `count_matches`

JS:

- `count_matches` — sorted by path ascending (после offset/head_limit).
- `files_with_matches` — sorted by mtime descending (most-recent first).

Текущий Crystal — проверить, какой порядок у `count_matches`.
Если такой же — ОК.

### 4. `count_matches` aggregate line

JS `count_matches` output:

```
total:42
src/foo.ts:30
src/bar.ts:12
```

Первая строка — aggregate `total:N`. Crystal — проверить наличие.

### 5. `-C` precedence

JS: `"-C"` takes precedence over `-A` and `-B`. Crystal должен тоже
применять `-C` в `rg` call только если не заданы `-A`/`-B`, либо
всегда передавать `-C` (rg сам разрешает конфликт).

### 6. RG unavailable message

JS `rgUnavailableMessage` — fallback text если `rg` не найден.
В Crystal — соответствующая проверка `ensure_rg_path` /
`rg_unavailable_message`.

### 7. `normalize` path

JS использует `pathe/normalize`. Crystal — `File.expand_path` или
эквивалент.

### 8. Retry on EAGAIN

JS `shouldRetryRipgrepEagain` — повторяет запуск `rg` при EAGAIN.
Crystal — нужно добавить retry-loop для `run_rg_once`.

---

## 9. План реализации (чек-лист)

- [ ] Прочитать JS: `grep.ts` (полностью), `grep.md`, `runRg.ts`,
      `rgLocator.ts`.
- [x] Описать фикс-план в `md-tools/fix-grep.md`.
- [ ] **Аудит текущего `src/tools/grep.cr`** — отметить, какие из
      пунктов §1–§8 уже реализованы:
  - [ ] description verbatim из `grep.md`.
  - [ ] mtime-sort для `files_with_matches`.
  - [ ] path-sort для `count_matches`.
  - [ ] aggregate `total:N` line для `count_matches`.
  - [ ] `-C` precedence над `-A`/`-B`.
  - [ ] Sensitive filtering + message.
  - [ ] VCS-metadata skip even with `include_ignored`.
  - [ ] Retry on EAGAIN.
  - [ ] RG-unavailable fallback message.
- [ ] Заполнить недостающие элементы (если есть).
- [ ] Тесты в `spec/tools/grep_spec.cr` — дополнить для:
  - [ ] `count_matches` output format (aggregate line + per-file).
  - [ ] `-C` precedence.
  - [ ] `include_ignored=true` + sensitive files still filtered.
  - [ ] `.git` directory always skipped.
  - [ ] mtime-sort (touch a file, verify ordering).
- [ ] Обновить `FIX-TOOLS.md`: отметить Grep-строку выполненной
      (или близкой к паритету с минорными правками).

---

## 10. Расхождения / дополнения

- Текущий Crystal Grep уже **очень близок** к паритету —大部分
      работы сделано.
- Основное отличие — описание в `description` (verbose vs terse).
- EAGAIN retry — минорная robustness-фича; может быть опущена в MVP.
- Path-class aware filtering — Crystal предполагает POSIX.
- Sensitive-file list — см. `src/tools/sensitive.cr`. Должен
      включать `.env`, `.npmrc`, `id_rsa`, `*.pem`, `*.key`, etc.
- `MAX_OUTPUT_BYTES` — 10 MiB совпадает с JS.
- `DEFAULT_TIMEOUT_S` — 20s в Crystal; в JS — эквивалентный cap.
- Pagination — `head_limit=0` → unlimited. Crystal должен трактовать 0
  specially (а не как "0 lines").
