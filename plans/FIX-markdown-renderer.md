# FIX: Markdown Renderer — Feature Parity with TS pi-tui

## Problem

The Crystal markdown renderer (`src/tui/markdown.cr`, 240 lines, line-by-line regex)
is missing features and has bugs compared to the TS reference
(`packages/pi-tui/src/components/markdown.ts`, 858 lines, `marked` AST parser).

### Confirmed bugs (verified by test run)

| # | Bug | Location | Impact |
|---|-----|----------|--------|
| B1 | `__bold__` not rendered — checks `_*` instead of `__` | `markdown.cr:114` | `__text__` shows as literal |
| B2 | `width` param accepted but never used | `render()` :9 | Long lines overflow terminal |
| B3 | No italic (`*text*`, `_text_`) | — | Italic markers show as literal |

### Missing features (vs TS)

| # | Feature | TS impl | Crystal status |
|---|---------|---------|----------------|
| F1 | ANSI-aware text wrapping | `wrapTextWithAnsi()` | Missing (B2) |
| F2 | Visible width calculation | `visibleWidth()` | Missing |
| F3 | Horizontal rules (`---`, `***`) | `─`.repeat(width) | Missing |
| F4 | Nested lists (depth indent) | `"    ".repeat(depth)` | Missing |
| F5 | Task lists (`- [x]`, `- [ ]`) | `[x]`/`[ ]` marker | Missing |
| F6 | Tables | Full Unicode border renderer | Missing |
| F7 | Paragraph spacing | `""` between paragraphs | Missing |
| F8 | H1 underline, H3+ `#` prefix | depth-based style | Missing |
| F9 | Multi-paragraph blockquotes | nested block render | Partial (single-line only) |
| F10 | Escape sequences (`\*` etc) | `marked` handles natively | Missing |

## Architecture Decision

**Enhanced line-by-line parsing** (not a full AST parser).

Rationale:
- The PLAN.md scope is "basic markdown" — LLM output is simple enough for line-by-line.
- Adding `markd` shard is heavy; the PLAN notes "can optimize or write custom".
- Tables are the only truly multi-line construct; handled with a stateful accumulator.
- Streaming-friendly: line-by-line naturally handles partial input.

## Implementation Plan

### Phase 1: Infrastructure (prerequisite for all wrapping)

**1a. `visible_width(str) : Int32`** — private method on `Markdown`

Strip ANSI escape sequences (`\e[...m`), then count visible characters.
ASCII fast path: if string contains no `\e`, return `.size`.

Reference: `packages/pi-tui/src/utils.ts:216` (`visibleWidth`).

**1b. `wrap_line(styled_line : String, width : Int32) : Array(String)`** — private method

Word-wrap a single styled line to `width` visible columns, preserving ANSI codes.
Split on spaces, accumulate words, break when exceeding width.
Preserve active ANSI color by re-emitting the last seen SGR prefix after each break.

Reference: `packages/pi-tui/src/utils.ts:720` (`wrapTextWithAnsi`).

Simplified vs TS: no grapheme segmentation (Crystal `String#size` counts codepoints,
good enough for ASCII/CJK), no `AnsiCodeTracker` class (track last color prefix inline).

**1c. Wire `width` into `render()`**

After building each output line (except inside code blocks), pass it through
`wrap_line(line, width - indent)` where `indent` is the line's leading prefix
(2 spaces default, bullet width for list items, etc.).

### Phase 2: Bug fixes

**2a. Fix `__bold__`** — `markdown.cr:114`

```
# Before (bug): checks for `_*`
if c == '_' && chars[i + 1] == '*'
    close = find_double(chars, '*', i + 2)

# After: checks for `__`
if c == '_' && i + 1 < chars.size && chars[i + 1] == '_'
    close = find_double(chars, '_', i + 2)
```

**2b. Add italic** — new branch in `render_inline`

Single `*` and single `_` delimiters → `ANSI.italic`.
Must run AFTER `**`/`__` checks to avoid consuming double delimiters.
Add odd-count streaming guard for single `*` and `_`.

Guard: only treat `*` as italic opener if not preceded by alphanumeric
(intra-word emphasis like `foo*bar` should not trigger), and the closer
is not followed by alphanumeric. This matches CommonMark `intraword` rules
simplified: `*word*` → italic, `foo*bar*` → not italic.

### Phase 3: Missing block features

**3a. Horizontal rules** — new branch in `render()` line loop

Detect lines matching `^(-{3,}|\*{3,}|_{3,})\s*$` (when not in a list context).
Render as `─`.repeat(min(width, 80)) in `@theme.colors.dim`.

**3b. Nested lists** — enhance list branch

Count leading spaces to determine depth: `depth = leading_spaces // 2`.
Apply indent: `"  " * depth` before the bullet.
Track current depth to decide spacing between items.

**3c. Task lists** — enhance list branch

Before extracting bullet content, check for `[x]`, `[X]`, `[ ]` after the marker.
Render as `☑` / `☐` (or `[x]`/`[ ]`) in accent/error color.

**3d. Tables** — new stateful branch in `render()` line loop

Accumulator state:
```
@in_table : Bool
@table_rows : Array(Array(String))
```

When a line matches `^\|.*\|`:
- If not in table: start accumulating.
- If in table: keep accumulating.

When a non-table line arrives after table rows:
- Flush the table: parse header, separator (`|---|---|`), data rows.
- Render with Unicode borders (`┌─┬─┐`, `│ │ │`, `├─┼─┤`, `└─┴─┘`).
- Calculate column widths, wrap cells to fit `width`.
- Reset accumulator.

At end of `render()`: if still in table, flush what we have (streaming support).

Column width algorithm (simplified from TS):
1. Parse each row by splitting on `|`, trimming.
2. Compute natural width per column (max across all rows).
3. If total + borders > `width`, shrink proportionally.
4. Wrap cell text to column width.

**3e. Paragraph spacing** — track block transitions

After each block element (paragraph, list, code block, table, blockquote),
insert a blank line `""` unless the next line is also part of the same block
(e.g., consecutive list items).

Implementation: in the main loop, track `last_block_type`.
When block type changes, emit `""` separator.

### Phase 4: Polish

**4a. Heading depth styling** — match TS

- H1: `heading(bold(underline(text)))`, no prefix
- H2: `heading(bold(text))`, no prefix
- H3-H6: `heading(bold(text))`, prefix `#`.repeat(level) + ` `

**4b. Multi-line blockquotes** — enhance blockquote branch

Currently only handles single `> ` lines. Enhance to:
- Group consecutive `>` lines.
- Strip `> ` prefix from each, render inner content recursively.
- Apply `│ ` border + italic + dim to each line.
- Width for inner content: `width - 2` (for the border).

**4c. Escape sequences** — new branch in `render_inline`

When encountering `\` followed by a punctuation char (`*`, `_`, `~`, `` ` ``,
`[`, `]`, `(`, `)`, `\`, `#`, `+`, `-`, `.`, `!`), emit the literal char
without markdown interpretation.

### Phase 5: Streaming safety

Verify all features handle partial input gracefully:
- Partial code fence: already works (in_code_block stays true).
- Partial inline delimiters: already works (odd count → plain text).
- Partial table: flush whatever rows we have.
- Partial heading/list: works naturally (line-by-line).

No additional code needed — just verify in tests.

### Phase 6: Tests

Write `spec/tui/markdown_spec.cr` covering:

```
describe "Markdown" do
  # Inline
  it "renders **bold**"
  it "renders __bold__"           # B1 fix
  it "renders *italic*"           # B3 new
  it "renders _italic_"           # B3 new
  it "renders ~~strikethrough~~"
  it "renders `inline code`"
  it "renders [link](url)"
  it "renders escaped asterisks"  # 4c
  it "handles streaming partial ** "  # odd count → plain

  # Block
  it "renders headings H1-H6"     # 4a depth styling
  it "renders horizontal rules"   # 3a
  it "renders unordered lists"
  it "renders ordered lists"
  it "renders nested lists"       # 3b
  it "renders task lists"         # 3c
  it "renders tables"             # 3d
  it "renders blockquotes (multi-line)"  # 4b
  it "renders code blocks with lang"
  it "renders paragraphs with spacing"   # 3e

  # Infrastructure
  it "wraps long lines to width"  # 1c
  it "preserves ANSI codes during wrap"
  it "calculates visible width correctly"
end
```

## Files Changed

| File | Change |
|------|--------|
| `src/tui/markdown.cr` | Rewrite: infrastructure + all fixes + features |
| `spec/tui/markdown_spec.cr` | New: comprehensive test coverage |

## Out of Scope

- OSC 8 hyperlinks (requires terminal capability detection — not worth the complexity)
- Full CommonMark spec compliance (setext headings, reference links, etc.)
- Grapheme-based width calculation (CJK double-width — Crystal String#size is sufficient for now)
- Syntax highlighter improvements (existing keyword-based highlighter stays as-is)
- Caching rendered output (not needed at current performance level)
