# ACP MCP Server Passthrough Design

## Context

[Issue #657](https://github.com/mrmans0n/alas/issues/657) identifies that
Alas sends an empty `mcpServers` array on every ACP session lifecycle request.
The current wire model supports only the stdio fields `name`, `command`, and
`args`; `initialize` does not decode the agent's MCP transport capabilities;
and projects have no MCP configuration surface.

The current branch also supports `session/resume` and `session/fork`, both of
which carry `mcpServers`. The implementation must therefore cover
`session/new`, `session/load`, `session/resume`, and `session/fork`, rather than
leaving newly added lifecycle paths hardcoded to an empty list.

Stable ACP v1 defines these server transports:

- stdio: `name`, `command`, required `args`, and required `env`
- HTTP: `type: "http"`, `name`, `url`, and required `headers`
- SSE: `type: "sse"`, `name`, `url`, and required `headers`

HTTP and SSE are gated by `agentCapabilities.mcpCapabilities`. Stdio is
required by ACP v1 and has no capability flag. Contrary to the original issue
description, the stable v1 stdio server shape has no per-server `cwd`; the
session lifecycle request already carries the active worktree `cwd`.

References:

- [ACP v1 session setup and MCP servers](https://agentclientprotocol.com/protocol/v1/session-setup)
- [Issue #657](https://github.com/mrmans0n/alas/issues/657)

## Goals

- Let each Alas project define one MCP server list shared by every ACP agent.
- Support the complete stable ACP v1 stdio, HTTP, and SSE wire shapes.
- Filter optional transports using capabilities returned by `initialize`.
- Resolve secret-bearing references from the app's launch environment without
  persisting the resolved values.
- Recompute the server list from current project configuration on every
  attach, including load, resume, and fork flows.
- Skip attributable per-server configuration problems without blocking the
  remaining session.
- Show an honest per-attachment `requested` and `skipped` summary in the ACP
  toolbar.
- Verify real stdio MCP use with both `claude-agent-acp` and `codex-acp`.

## Non-Goals

- No per-agent MCP lists or per-agent enablement.
- No automatic discovery or import from `.mcp.json`, Claude settings, or other
  external formats.
- No global MCP server catalog.
- No Keychain or encrypted literal-secret storage. Alas cannot reliably
  classify arbitrary user-entered literals; the editor directs users to
  environment references for secret-bearing values.
- No automatic reconnect when project MCP configuration changes.
- No per-server stdio working-directory wrapper.
- No attempt to infer whether an agent successfully connected to an individual
  server; ACP v1 does not report that result.
- No generalized integration-provider framework.

## Architecture

Use a dedicated, pure `MCPAttachmentPlanner` between project persistence and
the ACP wire layer.

The responsibilities remain separated:

1. `ProjectConfig` persists user-authored MCP definitions and reference
   expressions.
2. The MCP server manager edits and structurally validates a project draft.
3. `ACPConnection.initialize()` decodes the agent's MCP capabilities.
4. `ACPSessionManager.attach` asks an injected project-context provider for the
   current configuration, then calls `MCPAttachmentPlanner` with that context,
   the sanitized ACP process environment, and the initialized capabilities.
5. The planner returns resolved ACP wire servers plus safe status entries for
   requested and skipped definitions.
6. `ACPConnection` sends the resolved servers on the selected lifecycle
   request.
7. `ACPSession` retains only the safe, runtime attachment summary needed by the
   toolbar.

`AppState` already creates one `ACPSessionManager` per worktree. Add a narrow
provider closure at that construction point. The closure resolves the owning
project each time it is called and returns:

```swift
struct MCPProjectContext: Equatable {
    let projectPath: String
    let servers: [ProjectMCPServer]
}
```

This avoids making `ACPSessionManager` depend on `AppState` or
`ProjectsManager`, while ensuring a reattach does not use configuration copied
when the manager was first created.

## Persisted Model

Extend `ProjectConfig` with:

```swift
var mcpServers: [ProjectMCPServer] = []
```

Older `projects.json` files decode the missing field as an empty array.

Suggested configuration types:

```swift
struct ProjectMCPServer: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var transport: ProjectMCPTransport
}

enum ProjectMCPTransport: Codable, Equatable {
    case stdio(command: String, args: [String], environment: [MCPKeyValue])
    case http(url: String, headers: [MCPKeyValue])
    case sse(url: String, headers: [MCPKeyValue])
}

struct MCPKeyValue: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var value: String
}
```

The IDs are stable Alas editing identities and are never sent over ACP. Server
names are trimmed, non-empty, and unique within a project. Environment names
must be valid environment identifiers and unique within one server. HTTP
header names must be non-empty and case-insensitively unique.

Stdio commands must be non-empty. Do not require an absolute command path:
Alas already supports launching agent commands through `/usr/bin/env`, and MCP
configurations commonly rely on PATH-resolved tools such as `npx`.

HTTP and SSE URLs must use `http` or `https`. Empty argument, environment, and
header lists are valid in project configuration. The ACP v1 encoder still emits
the required arrays when they are empty.

## ACP Wire Model and Capabilities

Move the shared lifecycle MCP wire type out of `ACPSessionNewParams` and model
it as a custom Codable union:

- stdio omits `type` and encodes `name`, `command`, `args`, and `env`
- HTTP encodes `type: "http"`, `name`, `url`, and `headers`
- SSE encodes `type: "sse"`, `name`, `url`, and `headers`

ACP v1 represents environment variables and headers as arrays of
`{ "name": ..., "value": ... }`, not dictionaries. Preserve ordering so the
wire encoding and editor behavior are deterministic.

Extend `ACPInitializeResult.ACPAgentCapabilities` with conservatively decoded
MCP capabilities:

```swift
struct ACPMCPServerCapabilities: Codable, Equatable {
    let http: Bool
    let sse: Bool
}
```

Missing capability objects or fields decode to `false`. Stdio remains
supported without a capability check under ACP v1.

Change the lifecycle connection methods to accept `[ACPMCPServer]` rather than
constructing an empty list internally:

- `newSession(cwd:mcpServers:)`
- `loadSession(cwd:sessionId:mcpServers:)`
- `resumeSession(cwd:sessionId:mcpServers:)`
- `forkSession(cwd:sessionId:mcpServers:)`

An empty project list must preserve today's encoded requests exactly.

## Attachment Planning

The planner is a synchronous, side-effect-free unit. Its inputs are:

```swift
struct MCPAttachmentPlannerInput {
    let configuredServers: [ProjectMCPServer]
    let projectDirectory: String
    let worktreeDirectory: String
    let environment: [String: String]
    let capabilities: ACPMCPServerCapabilities
}
```

Its output separates resolved wire data from safe presentation data:

```swift
struct MCPAttachmentPlan {
    let wireServers: [ACPMCPServer]
    let statuses: [MCPAttachmentServerStatus]
    let configurationFingerprint: String
}
```

`MCPAttachmentServerStatus` contains only server name, transport, and either
`requested` or a typed skipped reason. It must never contain resolved commands,
arguments, URLs, environment values, or header values.

The fingerprint is deterministic over the wire-relevant, non-resolved project
MCP definitions. Exclude Alas-only editing IDs so an identity-only change does
not mark the attachment stale. The toolbar compares the fingerprint with the
current saved project configuration to show that changes will apply on
reconnect. It is runtime state, not session persistence.

### Interpolation

Expand `${NAME}` references at attachment time in:

- stdio command
- each stdio argument
- each stdio environment value
- HTTP/SSE URL
- each HTTP/SSE header value

Do not expand server names, environment names, or header names.

The environment input is the same sanitized ACP process environment used to
launch the selected adapter, including the adapter's configured extra
environment. Add two reserved built-ins:

- `${PROJECT_DIR}`: the registered project's root path
- `${WORKTREE_DIR}`: the active session worktree path

The built-ins override launch-environment entries with those names. Values may
contain more than one reference. A missing reference skips only that server and
produces a status naming the missing variable, never any resolved value.

Projects persist reference expressions exactly as authored. Resolved values
exist only in the in-memory attachment plan used for the lifecycle call. Do not
write them to `projects.json`, SQLite, logs, mirrored session metadata, error
messages, or toolbar state.

Plain literals remain valid for non-secret values such as `LOG_LEVEL=warn` or
`Content-Type: application/json`. The editor does not offer a separate secret
field and instructs users to use environment references for tokens, passwords,
authorization values, and other credentials.

### Capability and Validation Results

The planner requests:

- every structurally valid stdio server
- each valid HTTP server only when `mcpCapabilities.http` is true
- each valid SSE server only when `mcpCapabilities.sse` is true

Unsupported transports, missing variables, and invalid persisted definitions
produce skipped statuses. The editor prevents new structural errors, but the
planner remains defensive because users may edit `projects.json` externally.

## Session Lifecycle Flow

Build one attachment plan after `initialize` and before selecting the lifecycle
RPC. Use that same plan throughout one attach attempt:

- fresh session: `session/new`
- persisted Alas or imported session with replay: `session/load`
- imported or resumed session without replay: `session/resume`
- forked session: `session/fork`
- existing load/resume recovery to a new session: reuse the same plan for the
  fallback `session/new`

Do not silently retry a lifecycle request with an empty MCP list. If the agent
rejects the request, ACP v1 does not identify which server caused the failure;
an MCP-free retry would silently remove expected tools and could duplicate
lifecycle side effects.

Every later attach calls the project-context provider again and builds a fresh
plan. Configuration changes therefore affect the next reconnect but never
interrupt an existing session.

## Project Configuration UI

MCP configuration is available when editing an existing project. New projects
start with an empty list and can be configured after creation.

Add an `Integrations` section to Edit Project with an `MCP servers` summary:

- `No servers configured`, or
- `<count> configured for ACP sessions`

A `Manage...` button opens a dedicated MCP server manager. The manager edits
the parent Edit Project draft. `Done` returns to Edit Project; `Cancel` discards
changes made since the manager opened. The parent `Save changes` persists the
MCP draft atomically with the other project fields. Canceling Edit Project
discards all MCP changes.

The manager shows one row per server with name, transport, a safe endpoint
summary, and an overflow menu for Edit and Delete. A stdio summary shows only
the authored command, never arguments or environment values. A remote summary
shows scheme, host, and path while stripping user information, query, and
fragment. Delete requires confirmation. There is no enable toggle in this
scope: configured entries participate in the next plan, while temporary
suppression can be achieved by removing the entry.

`Add` and `Edit` use one adaptive sheet:

- a segmented transport control for `stdio`, `HTTP`, and `Legacy SSE`
- common name field
- command and ordered argument rows for stdio
- ordered environment name/value rows for stdio
- URL and ordered header name/value rows for HTTP and SSE
- inline structural validation
- a note that `${ENV_VAR}` references resolve when attaching
- a Legacy SSE deprecation note

Missing environment references may be warned about using the current app
environment, but they do not block saving because a later app launch may supply
them.

## ACP Toolbar Status

Add a compact MCP control to `ACPToolbar` only when the current plan has at
least one requested or skipped server.

Presentation rules:

- all requested and none skipped: `MCP <requested count>` with no warning
- any skipped: the same count plus a warning mark
- no requested and no skipped: hide the control
- configuration fingerprint differs from the current saved project
  configuration: keep the current attachment counts and show a stale-settings
  footer

The popover lists each server as:

- `Requested for this session`, or
- `Skipped: <safe reason>`

Use `requested`, not `attached` or `connected`. ACP v1 does not provide a
per-server success result. If a server fails after the lifecycle request is
accepted, the agent owns reporting that through its normal messages and tool
flow.

After a project save, existing sessions remain attached. Their popover shows:

`Project MCP configuration changed. New settings apply when this session reconnects.`

## Error Handling

| Condition | Behavior |
|---|---|
| HTTP/SSE capability absent | Skip that server and show the unsupported transport. |
| Environment reference missing | Skip that server and show the missing variable name. |
| Invalid persisted server | Skip that server and point the editor to the invalid field. |
| Lifecycle RPC rejects the request | Use the existing ACP attach failure and retry UI; do not retry without MCP. |
| Server fails after request acceptance | Leave status as requested; render agent-reported errors normally. |
| Project configuration changes | Keep the live session and mark its status stale until reconnect. |

## Testing

### Protocol

- Encode stdio, HTTP, and SSE exactly as ACP v1, including empty required
  arrays and the absence of `type` for stdio.
- Decode missing `mcpCapabilities` and missing fields as unsupported optional
  transports.
- Verify `session/new`, `session/load`, `session/resume`, and `session/fork`
  receive and encode their supplied server arrays.

### Attachment Planner

- Cover every stdio/HTTP/SSE capability combination.
- Cover environment interpolation, multiple references, and reserved built-in
  precedence.
- Cover missing variables, invalid URLs, duplicate names, and malformed
  persisted values.
- Verify skipped status is attributable and resolved values never enter status.
- Verify deterministic configuration fingerprints use persisted references,
  not resolved secrets.

### Persistence and Project Editing

- Round-trip all project MCP variants.
- Decode older projects with an empty MCP list.
- Verify the project dialog preserves MCP fields when editing unrelated values.
- Verify manager Done/Cancel and parent Save/Cancel draft semantics.

### Session Manager

- Build the plan only after `initialize` returns capabilities.
- Pass the same plan through fresh, load, resume, fork, and recovery-to-new
  paths.
- Verify a later attach reads current project configuration.
- Verify project changes do not reconnect existing sessions.

### UI Policies

- Cover hidden, requested-only, skipped-warning, all-skipped, and stale toolbar
  states with pure policy tests.
- Cover transport-specific editor validation and Legacy SSE labeling.
- Verify resolved environment and header values never appear in status models.

### Adapter Smoke Verification

Use a deterministic local stdio MCP server exposing one identifiable tool:

1. Configure it for a project using `${WORKTREE_DIR}` and one environment
   reference.
2. Start a fresh `claude-agent-acp` session and verify the agent lists and uses
   the tool.
3. Start a fresh `codex-acp` session and verify the same behavior.
4. Reconnect each session and verify the tool remains available.
5. Configure an unsupported remote transport and verify it is skipped without
   preventing session attachment.

Final repository verification uses:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

## Acceptance Criteria

- A configured stdio MCP server is listed and usable by both
  `claude-agent-acp` and `codex-acp` in fresh sessions.
- HTTP and SSE definitions are sent only when the initialized agent advertises
  the matching capability.
- Missing variables or unsupported transports skip only the affected server and
  produce safe toolbar status.
- The current project configuration is re-sent on load, resume, and fork.
- Existing sessions are not automatically reconnected after project edits.
- The toolbar distinguishes requested from skipped servers without claiming
  connection success.
- Tests cover all three wire shapes, capability gating, interpolation,
  persistence compatibility, lifecycle propagation, and UI state policies.
