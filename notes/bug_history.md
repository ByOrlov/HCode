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
