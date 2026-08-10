# Markdown list streaming bug

## Summary
When markdown is streamed in broken chunks, a list marker (`-`) split across
tokens can be rendered as a transient paragraph line. This adds a blank line
that disappears as soon as the next token completes the list item, causing the
Active zone to shrink and `SyncBugsCount` to increment.

## Reproduction

```bash
rake mock:markdown_tokens
```

The mock script streams a 10-item markdown list so that each new marker is
delivered in two chunks: `\n-` followed by ` Item N`. Before the fix the debug
status line showed `SyncBugsCount: 9`; after the fix it stays at `0`.

## Root cause

`MessageRenderer#render_streaming_text` passes the accumulated `@streaming_text`
to `Markdown#render` unchanged. When a chunk ends with a bare `\n-` (or `\n*`,
`\n+`, `\nN.`) the renderer parses the isolated `-` as a plain paragraph and
inserts a separator blank line. When the next token completes the marker into a
real list item, the blank line vanishes and the Active zone height drops.

## Fix

Strip trailing incomplete markdown block markers before rendering the streaming
buffer:

- Remove trailing newlines that would create transient blank separators.
- Remove a trailing list/ordered-list marker (`-`, `*`, `+`, `N.`) that starts
  its own line and has no content after it.

The change is localized to `MessageRenderer#render_streaming_text`; the final
message is still rendered normally through `render_message`, so the completed
output is unchanged.

### Files changed

- `src/tui/message_renderer.cr` — added `strip_streaming_incomplete` helper and
  applied it before markdown rendering.
- `src/llm/mock_provider.cr` — added `MARKDOWN_TOKENS_DEMO_SCRIPT`.
- `Rakefile` — added `rake mock:markdown_tokens` task.
- `spec/tui/app_spec.cr` — regression test asserting `SyncBugsCount == 0`.
- `bugs/markdown_render.md` — this report.

## Verification

1. Build the project: `rake build`
2. Run the repro: `rake mock:markdown_tokens`
3. Observe the debug status line: `SyncBugsCount` should remain `0`.
4. Run the regression test:
   ```bash
   crystal spec spec/tui/app_spec.cr --warnings none --no-color
   ```

## Status

Fixed in the working tree. Pending further regression testing with other
markdown streaming edge cases (blockquotes, code fences, tables, etc.).
