# TUI Rendering: Two-Zone Model

## Problem

The main terminal screen buffer has no scrollback API. The program cannot
detect when the user scrolls up, cannot rewrite lines that have scrolled into
the scrollback, and cannot move the viewport up. Any attempt to diff the
entire line array and rewrite changed lines — including lines that already
scrolled off — causes visual corruption when the user scrolls during active
LLM output.

## Solution: two zones

Split the rendered output into two independent zones with different
lifecycle rules:

```
┌──────────────────────────────────────┐
│  LOG (append-only)                   │   Written once, never rewritten.
│  - user message                      │   Grows downward; the terminal
│  - thinking block                    │   pushes old lines into scrollback
│  - tool result                       │   naturally as the active zone
│  - assistant message                 │   below it grows.
│  - tool result                       │
│  - step summary                      │
│  ...                                 │
├──────────────────────────────────────┤
│  ACTIVE ZONE (repainted every frame) │   Finite set of lines (5–15).
│  ⠹ Running Edit...                   │   Only this region is ever
│  ● streaming text...                 │   diffed and rewritten with
│  ┌──────────────────────────────┐    │   cursor moves + \e[2K.
│  │ editor input                │    │
│  └──────────────────────────────┘    │
└──────────────────────────────────────┘
```

### LOG zone

Append-only. Every finalized piece of output — user messages, assistant
messages, tool results, thinking blocks, step summaries — is appended here
once and never touched again.

The log grows downward. When the total line count exceeds the terminal
height, the terminal scrolls naturally: each `\r\n` at the bottom of the
visible area pushes the top log line into the scrollback. The program does
not control this and does not need to — lines in the scrollback are
immutable history.

### ACTIVE zone

The bottom N lines of the rendered output. This is the only region that
changes between frames. It contains:

- **Spinner + status line** — animated (`⠋`→`⠙`→`⠹`), updates every 80 ms.
- **Live thinking preview** — last 2 lines of the streaming thinking text.
- **Streaming assistant text** — the in-progress assistant response.
- **Editor box** — the input field, cursor, command hints.

The active zone is bounded: 5–15 lines depending on state. Because it is
always at the bottom of the visible area, all cursor moves stay within the
visible region and never reach into the scrollback.

## Transitions

When a streaming element finalizes, its lines migrate from the active zone
to the log:

| Event | Log | Active zone |
|---|---|---|
| `thinking_delta` stream finalizes | Thinking block appended | Live preview removed |
| `assistant_text` (stream ends) | Assistant message appended | Streaming text cleared |
| `tool_result` arrives | Tool result appended | Spinner/status updated |
| `tool_call_start` | (nothing) | Spinner/status updated |
| `turn_end` | (nothing) | Spinner stopped, status cleared |

After each transition, the active zone is rewritten from scratch (its
content fully changed), while the log simply grew by appending. No
already-written log line is ever modified.

## Rendering algorithm

```
render(new_lines, rows):
  active_height = size of active zone (spinner + streaming + editor)
  log_height    = new_lines.size - active_height
  active_start  = log_height

  # The active zone is always at the bottom of the visible area.
  # Lines above it are log lines that scrolled into the terminal buffer.

  # 1. Scroll the terminal so that the active zone bottom aligns
  #    with the terminal's last row.
  scroll_delta = max(0, new_lines.size - prev_lines.size)
  if scroll_delta > 0:
    move cursor to bottom row of visible area
    emit \r\n * scroll_delta

  # 2. Diff only the active zone [active_start, new_lines.size)
  #    against the previous active zone.
  first_changed = first index in [active_start, new_lines.size) where
                  new_lines[i] != prev_lines[i]
  last_changed  = last such index

  # 3. Move cursor to first_changed (relative to current cursor position)
  #    and rewrite changed lines with \e[2K + new content.

  # 4. If active zone shrank (fewer lines than before), clear the
  #    leftover rows below it with \e[J (no \r\n — never scroll here).
```

## Why this eliminates scroll bugs

1. **Log is immutable** — lines pushed into the scrollback are never
   rewritten, so no duplicates or corrupted content appears when scrolling up.
2. **Active zone is always visible** — all cursor moves are relative to the
   bottom of the visible area and stay within a small range (5–15 lines).
3. **No full-array diff** — only the active zone is compared, so
   `merge_turn_steps` or message finalization cannot trigger a false
   "everything changed" repaint.
4. **No high-water mark or viewport tracking** — the program does not track
   where the terminal's scrollback starts; it only knows the active zone is
   at the bottom and the log grows above it.
5. **Scroll is natural** — growth is handled by `\r\n` at the bottom row,
   which is standard terminal scroll behavior. No artificial scroll logic.
