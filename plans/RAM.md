# RAM: TUI Memory Growth Fix

## Problem

`h2code` RSS grows linearly with chat length. Idle usage is ~3–4 MB, but long
sessions easily reach 100+ MB. Initial suspicion pointed to context history /
LLM request serialization, but benchmarks show that the real culprit is the
TUI transcript.

### Benchmark evidence

`tmp/realistic_memory_benchmark.cr` simulates 2000 turns with compaction:

```text
Baseline:                  RSS 3.96 MB
After 500 turns:           RSS 35.29 MB   (context 19 msgs, TUI 1503 msgs, JSON 0.32 MB)
After 1000 turns:          RSS 66.76 MB   (context 34 msgs, TUI 3003 msgs, JSON 0.58 MB)
After 1500 turns:          RSS 97.26 MB   (context 49 msgs, TUI 4503 msgs, JSON 0.84 MB)
After all turns:           RSS 125.49 MB  (context ~60 msgs, TUI 6003 msgs)
After Context::Memory cleared: RSS 125.49 MB
After TUI cleared:             RSS 142.3 MB  (heap free 134 MB)
```

| Component | Peak live memory | Growth |
|-----------|------------------|--------|
| `Context::Memory` with compaction | ~10–15 MB | Bounded |
| JSON request body (`request.to_json`) | 0.84 MB | Bounded |
| TUI transcript (`@messages`) | ~105 MB raw → 125 MB RSS | **Linear, unbounded** |
| Markdown render | +17 MB transient | Freed after render |
| Boehm GC heap after clearing all objects | RSS 142 MB, free 134 MB | GC hoards pages |

Conclusion: the TUI keeps a full duplicate of the conversation history even
though only the visible screen + small scrollback is needed.

## Root Causes

1. **`TUI::App` stores every message forever.**
   `src/tui/app.cr:68`:
   ```crystal
   @messages : Array(Message) = [] of Message
   ```
   Old turns are never removed.

2. **`merge_turn_steps` only collapses intermediate blocks inside the current turn.**
   `src/tui/app.cr:2039` shrinks `thinking`/`tool` blocks within one turn but
   leaves previous turns intact.

3. **`build_rendered_lines` rebuilds the entire transcript every frame.**
   `src/tui/app.cr:1315`:
   ```crystal
   @messages.each do |msg|
     new_lines.concat(render_message(msg, cols))
   end
   ```
   `diff_render` then only sends changed lines to the terminal, but the full
   `new_lines` array is allocated on every render.

4. **Old tool results are kept in full.**
   Each tool card stores its `tool_result` string, which can be up to
   `Context::Budget.MAX_RESULT_CHARS = 50_000` (`src/context/budget.cr:4`).
   Old tool cards therefore retain large strings indefinitely.

## Proposed Fixes

### 1. Cap the TUI transcript size

Keep only the most recent N messages or M total rendered lines. When the limit
is exceeded, drop the oldest messages (or their heavy `tool_result` payloads).

Suggested initial limit: **200 messages** or **2000 rendered lines**, whichever
is smaller. This is configurable via an env var, e.g. `H2CODE_TUI_MAX_HISTORY`.

### 2. Prune old tool result payloads

Even if we keep old tool cards for display, we can drop their `tool_result`
content after they scroll off the visible screen. The card can show only the
header (“Read: path”) without the 50 KB body.

### 3. Render only the viewport

Replace full-transcript rebuild with viewport-aware rendering:

- Track the visible line range based on terminal rows and scroll offset.
- Render only messages that intersect the visible range (plus a small buffer).
- Diff only the visible lines, not the entire history.

This removes both the memory spike from `new_lines` and the CPU cost of
rendering off-screen messages.

### 4. Cache rendered lines per message

Store `Message#rendered_lines : Array(String)?` and invalidate it only when the
message content or terminal width changes. This avoids re-rendering unchanged
old messages on every frame.

### 5. Lower `Context::Budget.MAX_RESULT_CHARS`

Reduce from 50_000 to a smaller value (e.g. 8_000–12_000). This is the JS
reference value, but it is too generous for long sessions. The model can always
request the next chunk via `Read` with `line_offset`.

### 6. Reduce `Bash` capture buffer

`src/tools/bash.cr:16`:
```crystal
MAX_OUTPUT_BYTES = 10 * 1024 * 1024
```
Lower to 1 MB and/or apply truncation inside `capture` instead of buffering up
to 10 MB before `Context::Budget` runs.

## Implementation Plan

### Phase 1: Bound `@messages`

1. Add constants/env var:
   ```crystal
   DEFAULT_MAX_TRANSCRIPT_MESSAGES = 200
   DEFAULT_MAX_TRANSCRIPT_LINES    = 2000
   ```
2. After every `add_message` / `load_transcript_from`, call `prune_transcript`.
3. Implement `prune_transcript`:
   - If message count > max, drop oldest messages.
   - Alternatively, if total estimated lines > max, drop oldest until under limit.
4. When dropping old tool messages, also clear their `tool_result` to free the
   large strings.

This alone should cap RSS growth.

### Phase 2: Per-message rendered-line cache

1. Add `Message#rendered_lines : Array(String)?` and `Message#rendered_cols : Int32`.
2. In `render_message`, return cached lines if `cols == rendered_cols` and the
   message content did not change.
3. Invalidate cache when `tool_result`, `content`, or `expanded` changes.

### Phase 3: Viewport-only rendering

1. Precompute line offsets for messages (using cached rendered lines).
2. In `build_rendered_lines`, include only messages whose line range overlaps
   `[scroll_offset - buffer, scroll_offset + rows + buffer]`.
3. Keep diff rendering against `@previous_lines`, but `@previous_lines` now
   represents only the visible screen, not the full transcript.

### Phase 4: Lower tool-result budget and Bash buffer

1. Change `MAX_RESULT_CHARS` to 8_000 (tune after testing).
2. Change `Bash::MAX_OUTPUT_BYTES` to 1_048_576.
3. Optionally stream-truncate Bash output inside `capture`.

## Files Changed

| File | Change |
|------|--------|
| `src/tui/app.cr` | Add transcript pruning, per-message render cache, viewport-aware render |
| `src/context/budget.cr` | Lower `MAX_RESULT_CHARS` |
| `src/tools/bash.cr` | Lower `MAX_OUTPUT_BYTES`, optional inline truncation |
| `spec/tui/app_spec.cr` (if exists) or new `spec/tui/memory_spec.cr` | Tests for pruning and memory bounds |

## Acceptance Criteria

- [ ] Running the realistic benchmark (`tmp/realistic_memory_benchmark.cr`) with
      2000 turns shows RSS capped below ~30 MB after the transcript limit is
      reached.
- [ ] Long-running headless mode (`h2code -p`) does not exhibit the same growth
      (confirms the issue is TUI-specific).
- [ ] TUI scrollback still works for at least the configured limit.
- [ ] Streaming markdown and tool cards render correctly after pruning.
