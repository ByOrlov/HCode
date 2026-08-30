# DEBUG-MODE Plan

## Goal

Remove interactive tool-output expansion from the normal TUI and move the full
history view to an explicit `/debug` command. The normal TUI will store and
render only a small preview of each tool result, which eliminates the main
source of unbounded memory growth.

## Motivation

- `Ctrl+O` is rarely used and currently expands tool output only from 10 to 200
  lines, which is not enough for real tool results anyway.
- The full conversation is already persisted in
  `~/.h2code/sessions/<id>/wire.jsonl` by `Session::Store`.
- Storing every full `tool_result` in `TUI::App.@messages` is what makes RSS
  grow linearly with chat length.

## Design

### Normal TUI mode

- Tool results are always rendered collapsed.
- The TUI stores only a short preview of each tool result (e.g. first 10 lines
  plus a truncation marker).
- The footer hint under a truncated tool result says:
  `... (load session in /debug mode to expand)`.
- `Ctrl+O` is removed entirely.
- `Message#expanded` is no longer used for tool results.

### `/debug` mode

- Slash command `/debug` loads the current session's `wire.jsonl`.
- It renders the full transcript to the terminal, including:
  - complete tool results,
  - full thinking blocks,
  - full assistant messages.
- It is intentionally simple: dump to stdout, no TUI event loop.
- It can be used headless:
  ```sh
  ./h2code --session <id> /debug
  ```
  or from the TUI by typing `/debug`.

## Implementation

### Files to change

1. `src/tui/app.cr`
   - Remove `.ctrl_o?` handler in `handle_key`.
   - In `on_event(EventType::ToolResult)`, truncate `event.text` before storing
     it in `Message#tool_result` and in `ReadGroupEntry#tool_result`.
   - In `render_message` for `role == "tool"`, always use a fixed preview line
     count and replace the old `Ctrl+O to expand` hint.
   - Add `on_debug` callback property.

2. `src/tui/commands.cr`
   - Register `/debug` in the slash command registry.
   - Add handler that calls `app.on_debug.try(&.call)`.

3. `src/h2code.cr`
   - Wire `app.on_debug` to a function that:
     - reads the current session's `wire.jsonl` via `Session::Store`,
     - prints a full human-readable transcript to stdout,
     - exits.

### Tool result preview format

Stored preview (max 10 lines, max 1000 chars):

```text
<first 10 lines of output>
[... truncated; load session in /debug mode to expand ...]
```

The exact numbers (10 lines, 1000 chars) are tunable.

### Debug renderer

A simple renderer in `src/h2code.cr` or a new `src/tui/debug_renderer.cr`:

```crystal
def render_debug_transcript(store : Session::Store)
  store.read_events.each do |event|
    case event[:type]
    when "turn.prompt"
      puts "\n## User\n#{event[:data]["prompt"]?}\n"
    when "assistant.text"
      puts "\n## Assistant\n#{event[:data]["content"]?}\n"
    when "tool.call"
      puts "\n### Tool: #{event[:data]["tool_name"]?}\n```json\n#{event[:data]["arguments"]?}\n```\n"
    when "tool.result"
      puts "\n#### Result\n```\n#{event[:data]["content"]?}\n```\n"
    end
  end
end
```

## Acceptance Criteria

- [ ] `Ctrl+O` does nothing in the TUI.
- [ ] Tool results in the normal TUI are always collapsed.
- [ ] The hint under a truncated tool result reads
      `... (load session in /debug mode to expand)`.
- [ ] After a long session with many large tool results, RSS stays bounded
      because TUI no longer stores full outputs.
- [ ] `/debug` prints the full session transcript to stdout.
- [ ] Existing `/export-md` still works and uses `Context::Memory`, not TUI.
