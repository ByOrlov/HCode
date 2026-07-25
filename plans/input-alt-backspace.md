# Fix: Alt+Backspace wipes the whole input instead of deleting one word

## Symptom

In the input editor, pressing `Alt+Backspace` deletes the entire field at
once instead of deleting the word to the left of the cursor (the standard
terminal/editor behavior — "delete previous word").

## Root cause

Terminals send `Alt+Backspace` as a two-byte sequence: `ESC` (`0x1b`)
followed by the Backspace byte `DEL` (`0x7f`) or, on some terminals,
`BS` (`0x08`). The parser in `src/tui/input.cr` does not recognize this
combination, so the event is misclassified.

Trace through `Input#parse_escape` (`src/tui/input.cr:181`):

1. `parse_one` (`src/tui/input.cr:140`) sees the leading `0x1b` (27) and
   dispatches to `parse_escape`.
2. `parse_escape` reads `b2 = bytes[1]`, which is `127` (or `8`).
3. The `case b2` in `parse_escape` (`src/tui/input.cr:189`) only handles
   `91` (`[`), `79` (`O`), and `10` (LF). It then falls through to the
   `else` branch, which accepts printable bytes in the range `32..126`:
   ```crystal
   if b2 >= 32 && b2 < 127
     ev = KeyEvent.char(b2.chr)
     ev.alt = true
     {ev, 2}
   else
     {KeyEvent.new(Key::Escape), 2}   # ← 127 / 8 land here
   end
   ```
   Both `127` and `8` are outside `32..126`, so the function returns a
   bare `Key::Escape` event and **silently consumes the Backspace byte**.

4. In `App#handle_input_key` (`src/tui/app.cr:636`), `Key::Escape` with a
   non-empty editor calls `@editor.clear`:
   ```crystal
   when .escape?
     if @agent_busy
       ...
     elsif @pasted_block
       cancel_pasted_block
     elsif !@editor.empty?
       @editor.clear      # ← wipes the whole field
     end
   ```

So the user presses `Alt+Backspace`, the parser turns it into `Escape`,
and the app interprets that `Escape` as "clear the input". That is why
the field disappears all at once.

## Fix

Two layers, both required.

### 1. Recognize `Alt+Backspace` in the key parser

In `src/tui/input.cr`, `parse_escape`, extend the `case b2` so that an
`ESC` followed by a Backspace byte (`0x7f` or `0x08`) becomes an
`alt`-flagged `Key::Backspace` event instead of a bare `Key::Escape`:

```crystal
when 127, 8
  ev = KeyEvent.new(Key::Backspace)
  ev.alt = true
  {ev, 2}
```

Place this clause alongside the existing `when 10` (`Alt+Enter`) branch
so all `Alt+<control>` cases stay together. After this change the
Backspace byte is no longer swallowed, and the event carries `alt =
true` so the editor can distinguish `Backspace` from `Alt+Backspace`.

### 2. Delete one word in the editor

`Editor#handle_input` (`src/tui/editor.cr:63`) currently handles
`.backspace?` uniformly — one character (or join lines at column 0).
Add an `Alt+Backspace` path that deletes the word to the left of the
cursor.

Implement a private `delete_word_back` helper and dispatch to it when
`key.alt` is set on a `.backspace?` event:

```crystal
when .backspace?
  if key.alt
    delete_word_back
  else
    backspace
  end
  true
```

Word-deletion semantics (standard terminal behavior, matches readline
`backward-kill-word`):

- Skip whitespace left of the cursor.
- Then delete the contiguous run of non-whitespace characters to the
  left.
- Keep cursor row/col clamped via the existing `clamp_cursor_col`.
- If the run starts at column 0 and there is a previous line, do **not**
  join lines (mirrors single-char `backspace` boundary behavior); simply
  stop. The primary fix is the in-line word kill; line-joining on word
  kill can be revisited later if desired.

A minimal implementation operating on the current line:

```crystal
private def delete_word_back : Nil
  return if @cursor_col == 0 && @cursor_row == 0

  line = @lines[@cursor_row]
  col = @cursor_col

  # If at start of a (non-first) line, fall back to joining lines like
  # ordinary backspace — no word to kill on this line.
  if col == 0
    if @cursor_row > 0
      prev_line = @lines[@cursor_row - 1]
      @cursor_col = prev_line.size
      @lines[@cursor_row - 1] = prev_line + line
      @lines.delete_at(@cursor_row)
      @cursor_row -= 1
    end
    return
  end

  # Skip whitespace to the left.
  i = col - 1
  while i > 0 && line[i].ascii_whitespace?
    i -= 1
  end
  # i now points at the last non-whitespace char of the word (or 0).
  word_start = i
  while word_start > 0 && !line[word_start - 1].ascii_whitespace?
    word_start -= 1
  end

  @lines[@cursor_row] = line[0...word_start] + line[col..]
  @cursor_col = word_start
end
```

### Why not just treat it as Escape

The current accidental behavior (whole-field clear) happens to "work"
as a destructive shortcut, but it is not what users expect from
`Alt+Backspace` in any terminal or editor, and it collides with the
actual `Escape` key. The fix gives `Alt+Backspace` its conventional
word-delete meaning while leaving `Escape`'s clear-field behavior
untouched.

## Files touched

- `src/tui/input.cr` — recognize `ESC + {0x7f | 0x08}` as
  `Key::Backspace` with `alt = true`.
- `src/tui/editor.cr` — add `delete_word_back` and dispatch to it from
  `handle_input` when a `.backspace?` event has `alt` set.

## Verification

1. `crystal build` / existing build target compiles.
2. Manual test in the TUI input:
   - Type `hello world foo`, place cursor at end, press `Alt+Backspace`
     → `foo` removed, cursor after `hello world `.
   - Press again → trailing space + `world` removed (i.e. whitespace is
     skipped before the next word).
   - Press `Backspace` (no Alt) → still deletes one character.
   - Press `Escape` on a non-empty field → still clears the whole field
     (unchanged).
3. Add a spec under `spec/tui/` covering `Input#parse_one` for the
   bytes `[0x1b, 0x7f]` and `[0x1b, 0x08]`, asserting a
   `Key::Backspace` event with `alt == true`, and an `Editor` spec
   asserting that an `alt` `Backspace` event deletes the preceding word.
