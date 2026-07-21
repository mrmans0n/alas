# Built-in Alas MCP: registration detection and HTTP transport

## Problem

The built-in `alas` MCP server is injected correctly into every local ACP
session (verified on live SDK process argv), yet in some environments the
harness silently drops it. Concretely: Claude Code enforces an org-pushed
`allowedMcpServers` allowlist (claude.ai enterprise policy, cached in
`~/.claude/remote-settings.json`) that permits only specific stdio commands
and URL patterns. The Alas stdio server is not on the list, so the CLI
filters it before spawn, emitting only a stderr warning the ACP adapter never
surfaces. Alas has no feedback: the MCP status control shows the server as
attached and the prompt preamble tells the agent the tools exist, while no
`alas mcp` process was ever started.

Two facts make this fixable:

- The observed allowlist includes `http://localhost:*` and
  `http://localhost:*/*` — a localhost HTTP MCP server passes policy.
- The CLI env injection (`alas` on PATH + `ALAS_*` env) is unaffected, so
  agents can always fall back to the `alas` CLI in a shell.

## Design

Three layered pieces; each is useful on its own. Default behavior is
unchanged: stdio stays the default transport. Non-goals: per-agent or
per-project transport, auto-fallback without consent, parsing
harness-specific policy files, and changing gg-mcp in this iteration (the
same pattern can follow later). Remote sessions remain excluded exactly as
today (`remoteHost == nil` guard); the HTTP endpoint is localhost on the Mac
running Alas.

### 1. Global transport setting

`harness.alasMCPTransport: stdio | http`, default `stdio`. A missing key
decodes as `stdio`, so existing configs are untouched. UI: a transport picker
("Standard I/O (default)" / "HTTP (localhost)") in the Agents pane, under the
existing "Expose Alas tools (MCP)" toggle. The setting only changes how the
built-in server is wired into sessions; the tool surface, socket protocol,
and session scoping are identical.

### 2. HTTP endpoint

- **Hosting:** in the app process, alongside the existing unix-socket server —
  a second front door to the same action dispatch. (Considered and rejected:
  an HTTP→socket proxy child under `alas-helper`; it adds a process to
  supervise and buys nothing, since the app is running whenever sessions
  attach.)
- **Binding:** loopback only, random ephemeral port. Started lazily — only
  when the transport is `http` — so stdio users never open a port. The
  advertised URL uses the literal hostname `localhost` (allowlist entries are
  string patterns like `http://localhost:*`; do not advertise `127.0.0.1`).
- **Protocol:** MCP streamable-HTTP, minimum viable subset: `POST` JSON-RPC,
  single JSON response. No SSE, no resumability — all alas tools are quick
  request/response. `initialize`/`tools/list`/`tools/call` reuse the same
  handlers the stdio shim serves today.
- **Session identity & auth:** per-session URL
  `http://localhost:<port>/mcp/<session-uuid>` plus an
  `Authorization: Bearer <token>` header with a per-session random token
  generated at injection time. Unlike the unix socket (filesystem-permission
  protected), a localhost TCP port is reachable by any local process; the
  token prevents arbitrary local software from driving the UI.
- **Wire entry:** `BuiltInAlasMCP.injection` gains an `.http` variant emitting
  `ACPMCPServer.http(name:url:headers:)`. The claude ACP adapter already
  converts http entries correctly (verified in adapter source).

### 3. Registration detection

Positive signal, not policy sniffing: the server announces itself per
session; silence means dropped.

- **stdio:** on startup, `alas mcp` sends a one-shot `mcp_hello` event over
  the unix socket carrying its `ALAS_SESSION_ID` (it already has socket path
  and session id in env).
- **http:** the app is the server — the first authenticated `initialize` for
  a session id is the hello.

Both feed an in-app registry: session id → registered-at, reset on each
reattach (a reconnect respawns MCP servers, so each attach epoch needs its
own hello).

**Trigger:** not a bare timer after `session/new` — some harnesses spawn MCP
servers lazily. The anchor is turn activity: once the first prompt of an
attach epoch is running, the harness has finished tool registration. No hello
by then plus a short grace (~10 s) flips the status entry from `requested` to
`notRegistered`. A hello arriving later heals the state back — the warning is
advisory, never load-bearing.

**Status model:** `MCPAttachmentServerStatus` gains a registration field
alongside disposition: `unknown` → `registered` / `notRegistered`. Only
built-in servers populate it; user-configured servers stay `unknown` and
render as today.

**Preamble honesty:** the claude-path preamble gains the CLI-fallback
sentence the pi path already has, so even a blocked session's agent knows
`alas review resolve` works in a shell.

### 4. Status UI and guided switch

The alas row in `ACPMCPStatusControl` renders registration state:

- `registered` → normal row (now truthful).
- `notRegistered` + stdio → warning: "The agent harness didn't start this
  server — possibly blocked by an enterprise MCP policy (stdio servers are
  commonly restricted)." with a **Switch to HTTP transport** button.
- `notRegistered` + http → warning without the button; hint suggests checking
  org policy for `http://localhost` entries.

The button flips the global setting, then offers to reconnect the current
session so it applies now (the transport change alters the wire `mcpServers`;
the adapter's session fingerprint check tears down and recreates the query).
Other sessions pick it up on their next natural reattach. No modal, no
notification — detection only decorates the status control.

## Error handling

- **Listener can't bind** with transport `http`: injection falls back to
  stdio for that attach (same guard shape as today's nil `socketPath`); the
  status row notes the fallback.
- **Bad auth / unknown session:** uniform empty-body `401` — unknown-session
  is indistinguishable from bad-token to local port scanners. Request bodies
  capped (1 MB); idle connections closed.
- **App relaunch:** port changes; injection is recomputed per attach, so
  reattached sessions get the fresh URL. Query processes orphaned from a
  previous app instance hold stale URLs and fail — the same situation stdio
  has today with stale socket paths, healed the same way on reattach.
- **Detection false positives:** `notRegistered` heals to `registered` on any
  late hello; nothing gates on the warning.

## Testing (Swift Testing)

- `BuiltInAlasMCP.injection`: http variant URL/headers/token shape; stdio
  unchanged; user-override suppression and enabled/nil guards hold for both
  transports.
- Config decode: missing `alasMCPTransport` → `stdio`.
- Registration registry: hello before/after turn start, reattach epoch reset,
  late-hello healing.
- `ACPMCPStatusPolicy`: pure mapping of (registration, transport) → row state
  and button visibility.
- HTTP handler: loopback round-trip of `initialize`/`tools/list`/`tools/call`,
  401 on bad token, body-cap rejection.
- Preamble: claude path contains the CLI-fallback sentence.

Manual end-to-end: switch transport in a policy-restricted environment and
confirm the session registers (hello observed, `mcp__alas__*` tools appear in
the harness).
