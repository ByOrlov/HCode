# MCP minor fixes — Crystal parity with JS

> Corrective fixes identified by comparing `src/mcp/` (Crystal) against
> `kimi-code/packages/agent-core/src/mcp/` (JS). Each is self-contained
> and individually testable.

## Fix 1 — Tool naming: collapse `_+` runs

**JS:** `sanitizeMcpNamePart` replaces non-word chars with `_` then collapses
`_+` → `_`, guaranteeing neither part contains the `__` separator
(`tool-naming.ts:18`).

**Crystal:** `sanitize` (`tool_naming.cr:36`) skips the collapse, so a server
name containing `_` collides with `__` and `split` becomes ambiguous.

**Fix:** add `.gsub(/_+/, "_")` after the char replacement in `sanitize`.

## Fix 2 — Wire `stderr_tail` into error reporting

**JS:** stdio close reason includes the last 4 KB of stderr
(`client-stdio.ts:177-180` → `UnexpectedCloseReason.stderr`).

**Crystal:** `StdioTransport#stderr_tail` exists (`transport.cr:105-107`) but
`format_error` (`manager.cr:489-496`) never reads it — the TODO comment says
"no stderr surface on Client yet".

**Fix:** expose `stderr_tail` through `Client`, thread it into `format_error`
and `watch_for_close` error messages.

## Fix 3 — Protocol version negotiation

**JS:** SDK negotiates inside `client.connect()`; kimi wrapper supplies name/
version.

**Crystal:** `PROTOCOL_VERSION` is hardcoded and sent verbatim
(`client.cr:10,37`); the server's returned `protocolVersion` is **ignored**
(`client.cr:44`).

**Fix:** capture the `protocolVersion` from the `initialize` response and store
it on the client; warn on mismatch but do not fail (servers may legitimately
negotiate an older version).

## Fix 4 — Config: resolve relative stdio `cwd` against project root

**JS:** `normalizeStdioCwd` (`config-loader.ts:135-139`) resolves relative
`cwd` against the project root directory that contained the `.mcp.json`.

**Crystal:** `cwd` is stored as-is (`config.cr:160`); a relative `cwd` in a
project-root `.mcp.json` resolves against the wrong directory.

**Fix:** after loading, resolve relative `cwd` for stdio servers against the
directory of the file that declared them.

## Fix 5 — Config: surface parse errors

**JS:** read/parse failure raises `KimiError(CONFIG_INVALID)`
(`config-loader.ts:98-120`).

**Crystal:** `read_mcp_json_file` rescues **all** exceptions to `[] of
McpServerConfig` (`config.cr:146-148`), making a corrupt file
indistinguishable from an empty one.

**Fix:** log parse errors to `STDERR` instead of silently swallowing them.

## Fix 6 — Auth tool: include auth URL in result + pass config OAuth params

**JS:** the auth URL is streamed to the model via `onUpdate` and included in
the tool result text so the model can show it to the user (`auth-tool.ts:116-
132`). Config-level `oauth_client_id` / `oauth_client_secret` / `oauth_scopes`
are threaded through.

**Crystal:** `McpAuthTool` only `STDERR.puts` the URL (`auth_tool.cr:52-54`)
and passes `nil` for all OAuth config params (`auth_tool.cr:50-51`), ignoring
the server-configured values.

**Fix:** (a) thread config OAuth params into `McpAuthTool`; (b) run
`OAuth.authorize` in two phases — first get the URL and return it as a partial
result, then block — OR simpler: since Crystal's `execute` is synchronous and
blocking, at minimum include the auth URL in the *error* result when the flow
fails, and capture the URL for the success message via the block callback.

## Fix 7 — Content blocks: handle `resource_link` with `uri` field

**JS:** `resource_link` is treated as a URL reference (not inline blob) —
remote image/audio/video URLs are emitted as data URIs or notices
(`output.ts:137-158`).

**Crystal:** `resource_link` falls into the same branch as `resource`
(`client.cr:109`), tries to read `block["resource"]`, and produces
`[resource: <uri>]` — losing the URL.

**Fix:** separate `resource` and `resource_link` handling. For
`resource_link`, emit the URI text directly so the model sees the URL.

## Fix 8 — Output: propagate `truncated` flag to `ToolResult`

**JS:** `mcpResultToExecutableOutput` returns `{ truncated?: true }`
(`output.ts:221`); the agent loop uses it.

**Crystal:** `Output.post_process` returns a bare `String`; the `truncated`
information is lost. `ToolResult` already has a `truncated?` field
(`tool.cr:45`).

**Fix:** make `Output.post_process` return a named tuple `{text, truncated}`,
set `ToolResult#truncated` accordingly.

## Fix 9 — Manager: attempt-id race guard on `connect_one`

**JS:** `beginConnectAttempt` / `isCurrent` (`connection-manager.ts:341-344,
424`) discards results from stale connection attempts.

**Crystal:** a late `connect_one` from a superseded `reconnect` can stomp live
state.

**Fix:** add a monotonic `@attempt_id` counter; tag each spawned connect with
its id; bail if the current id has advanced by the time the attempt finishes.

## Fix 10 — `needs_auth_like?`: headers bypass

**JS:** `shouldMarkNeedsAuth` explicitly skips the OAuth flow when
`config.headers` is set and `auth !== 'oauth'`
(`connection-manager.ts:389`).

**Crystal:** `needs_auth_like?` (`manager.cr:483-487`) always returns true for
401-like messages regardless of `config.headers`, hijacking servers that use
static headers.

**Fix:** return `false` from `needs_auth_like?` when `config.headers` contains
an `Authorization` entry.

## Fix 11 — Assert `inputSchema` is an object

**JS:** `assertMcpInputSchema` (`types.ts:97-104`) rejects non-object schemas.

**Crystal:** `list_tools` (`client.cr:56`) passes `inputSchema` through
unchecked — a `null` or array produces a malformed tool definition.

**Fix:** validate that `inputSchema` is a JSON object; default to `{}` when
not.
