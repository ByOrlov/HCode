# Markdown table phantom column from escaped pipes

## Summary
A GFM table with an escaped pipe (`\|`) inside a cell rendered a phantom
third column one display column wide, wrapping its content vertically —
one character per line. The row ballooned to dozens of screen lines with
package names like `libwebkit2gtk-4.0-37` spelled out letter by letter.

## Reproduction

```bash
crystal run tmp/repro_md_table.cr
```

Input:

```markdown
| Каноническое | Примеры правил |
|---|---|
| webkit2gtk | debian ≤11 → \|`libwebkit2gtk-4.0-37`; debian ≥13 → \|`libwebkit2gtk-4.1-0` |
```

Before the fix, each `\|` split the row into an extra cell, and the extra
column rendered vertically.

## Root cause

Two bugs combined:

1. `Markdown#parse_table_row` split rows on every `|`, including escaped
   `\|`. Per GFM, `\|` inside a table cell is a literal pipe, not a column
   separator, so each `\|` produced a phantom cell.
2. The column count comes from the header row (`num_cols = header.size`),
   and `Markdown#render_table_cells` sizes unknown columns with
   `col_widths[i]? || 1`. An excess cell therefore got width 1, and
   `wrap_line` at width 1 hard-broke the text one character per line.

## Fix

- `parse_table_row` now shields `\|` with a placeholder before splitting
  and restores the literal `|` in each cell afterwards.
- `flush_table` normalizes data rows to the header's column count: excess
  cells (e.g. from a raw unescaped pipe inside inline code) are merged back
  into the last column joined by `|`, and short rows are padded with empty
  cells. Content is never dropped and can no longer land in a width-1
  column.

The change is localized to table parsing/normalization in
`src/tui/markdown.cr`; non-table rendering is unchanged.

### Files changed

- `src/tui/markdown.cr` — escaped-pipe handling in `parse_table_row`;
  row normalization (merge/pad) in `flush_table`.
- `spec/tui/markdown_spec.cr` — regression tests: `\|` stays a literal,
  excess cells merge into the last column instead of rendering vertically.
- `bugs/markdown_table_pipe.md` — this report.

## Verification

- `crystal spec spec/tui/markdown_spec.cr` — 76 examples, 0 failures
  (includes the two new regression tests).
- `crystal spec spec/tui/streaming_markdown_spec.cr` — 10 examples,
  0 failures.
- Manual repro at widths 60 and 100: borders stay aligned, the cell wraps
  horizontally, no vertical column.
- The 2 failures in `spec/tui/voice_recording_zone_spec.cr` are
  pre-existing and unrelated (they fail with these changes stashed).
