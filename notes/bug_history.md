# Bug History — TUI Rendering

## Blank-line cleanup bugs after active-zone shrink (2026-08-05)

**Files**: `src/tui/active_zone.cr`, `src/tui/app.cr`
**Tests**: `spec/tui/zone_behaviour_spec.cr` (Test 9, Test 10)

### Scenario

During agent streaming the active zone grows (e.g. from 6 to 8 lines:
live thinking preview + streaming text + spinner). When the streaming
finalizes, the thinking block migrates to the log zone, the live preview
disappears, and the active zone shrinks (e.g. back to 5). Two bugs
caused visual artefacts — stale content left on screen.

### Bug 1: `clear_below` wipes the last active line at screen bottom

`ActiveZone#render` issued `cursor_down(1)` + `clear_below` when the zone
shrank (`prev_visible > visible`). But when the active zone occupied the
bottom row of the screen, `cursor_down(1)` was clamped (it cannot move
past the last row), so `clear_below` erased from the current position —
wiping the last active line instead of clearing rows below the zone.

**Fix**: removed `clear_below` from `ActiveZone#render` entirely. The
cleanup is now done by `incremental_render`, which knows the absolute
screen geometry and only clears below the active zone when content
doesn't fill the entire screen (`screen_end < rows`).

### Bug 2: insufficient cleanup on viewport shrink (`scroll_delta < 0`)

When `viewport_top` decreased (content shrank — thinking finalized,
modal dismissed, spinner gone), the old cleanup only cleared `stale`
rows in the middle of the screen. But every visible row now mapped to
different content, and the old pixels stayed on screen. This caused the
artefact where stale lines from the previous frame (e.g. the top of the
active zone) appeared where the thinking block used to be.

**Root cause**: the terminal cannot scroll back down on its own. When
`viewport_top` decreases, every row shifts down by `|scroll_delta|`, but
the terminal has no way to know this — the old content stays at the same
pixel positions.

**Fix**: when `scroll_delta < 0`, `incremental_render` performs a full
repaint of the visible area — `cursor_home`, rewrite every visible line
with `\e[2K`, then `clear_below` any leftover rows. This is the only
safe recovery; incremental patching of individual rows is unreliable
because the shift affects the entire visible region.

## Shadow-cursor elimination (2026-08-05, branch retained-grid-render-v2)

### Shadow cursor removed

`@hardware_cursor_row` and `move_cursor_to` (relative cursor-up/down deltas
from a shadow position) replaced with absolute CUP (`cursor_to_row`,
`\e[<row>;1H`). The shadow cursor could desynchronize at the screen edge
(after a clamp) or when a branch forgot to update it — the root cause of
Bug 1. CUP addresses only the visible screen, never scrolls, and needs no
tracking of the current position.

### `shrank?` now checked as full-repaint trigger

`LogZone#shrank?` is now checked alongside `scroll_delta < 0` as a full-repaint
trigger, so compaction (log shrinks while active grows, keeping total flat)
no longer leaves stale log rows on screen.

### Blank-row bug from @max_viewport_top (fixed)

An initial fix added `@max_viewport_top` to prevent scrollback duplicates:
log lines below this boundary were cleared (not rewritten) during full
repaint. But this caused a **blank-row bug**: when the viewport grew
temporarily (e.g., thinking preview +2 rows) and then shrank back, the full
repaint cleared the temporarily-scrolled rows instead of rewriting them —
leaving visible blank lines in the transcript output (e.g., between plan
steps 131 and 132).

The `@max_viewport_top` barrier was removed. The full repaint now rewrites
ALL visible lines unconditionally. This accepts a known limitation: a line
that was scrolled into scrollback, rewritten during full repaint, and later
scrolled off again may appear twice in scrollback. This is an inherent
limitation of the terminal's immutable scrollback — the alternative (blank
rows) is a worse user-visible bug.

### Tests

`spec/tui/zone_invariant_spec.cr` — property-based fuzzer (500×25 random
sequences) that after every frame asserts the visible screen matches a dumb
unconditional recompute, including grow+shrink sequences (no blank rows
where content should be). Plus a targeted regression test for the
viewport grow-then-shrink pattern.
