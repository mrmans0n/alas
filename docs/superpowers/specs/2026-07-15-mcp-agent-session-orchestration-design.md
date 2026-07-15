# MCP Agent Session Orchestration Design

**Status:** Design approved, ready for implementation planning

## Context

[Issue #795](https://github.com/mrmans0n/alas/issues/795) is Phase 4 of the
[MCP toolset expansion](https://github.com/mrmans0n/alas/issues/787). It adds
agent-facing session tools to the built-in `alas` MCP server so one ACP session
can delegate work to other ACP sessions, including sessions launched in fresh
linked worktrees.

The current built-in MCP server is injected into each ACP session with the
local Alas session ID, worktree path, and app socket. MCP calls therefore have
a precise originating session, and Swift remains the authority for projects,
worktrees, sessions, permissions, and UI state. The Rust `alas` CLI and MCP
server are thin, matching front ends over the same Unix-socket request model.

ACP session persistence is currently one SQLite database per worktree. That is
the correct ownership boundary for transcripts, queues, drafts, permissions,
and runner leases, but it cannot answer a cross-worktree question such as
"which session delegated this child?" without opening and scanning every
worktree database. Orchestration therefore needs a small app-level index while
leaving session content in the existing per-worktree stores.

The design is intentionally a bounded delegation model rather than a general
multi-agent workflow engine. A user-created root may fan work out to direct
children. Children may report to their parent, but cannot recursively spawn
more sessions.

## Goals

- Let a root ACP session list its delegated children, create a child, and send
  follow-up prompts to a child.
- Let a delegated child inspect its parent and send results or questions back.
- Support children in the current worktree, an existing project worktree, or a
  newly created linked worktree.
- Make fresh-worktree creation and child launch one atomic user intent, without
  racing separate `worktree_new` and `session_new` calls.
- Persist the delegation relationship and asynchronous creation state across
  UI navigation and app relaunches.
- Preserve ACP writer-lease rules when routing prompts across worktrees or Alas
  instances.
- Keep agent-created sessions and messages visibly distinct from user-created
  content in the UI.
- Keep MCP and CLI command surfaces in 1:1 parity and return stable JSON.
- Avoid changing window/worktree focus as a side effect of agent orchestration.

## Non-Goals

- No recursive delegation or configurable delegation depth.
- No messaging between unrelated sessions, even within the same project.
- No transcript reading, transcript copying, or automatic result summarizing.
- No automatic definition of "done" from an idle agent or completed turn.
- No agent-driven session close, archive, delete, or worktree cleanup.
- No prompt attachments in orchestration tools in the first version.
- No agent-selected auto-run, permission, model, or mode overrides.
- No orchestration of terminal-only or non-ACP agent sessions.
- No standalone root-session creation from an external/directory-only CLI
  context. Session commands require an originating ACP session in v1.
- No new orchestration dashboard, graph canvas, scheduler, budgets, or numeric
  concurrency controls.

## Delegation Model

Every orchestration relationship is one directed parent-child edge.

- A session with no parent edge is a root.
- A root may create any number of direct children.
- A child may not call `session_new`.
- A root may send only to its children.
- A child may send only to its parent.
- Both endpoints must remain in the project recorded on the edge.
- A session ID that is not one endpoint of an authorized edge is never exposed
  or accepted as a target.

The absence of recursive creation is the loop-prevention rule for v1. It is
enforced by Swift from persisted delegation data, not by prompt instructions or
the Rust client. The persisted model can support a deeper tree later without a
wire-format change, but v1 rejects `session_new` whenever the caller already
has a parent.

The originating session's normal ACP MCP-tool permission policy remains the
user-consent surface. Auto-run may approve these calls just as it may approve
other Alas MCP tools. Alas does not add a second confirmation dialog, but it
always performs graph authorization, project scoping, agent validation, and
worktree validation after the tool call reaches the app.

## Tool And CLI Surface

### `session_list`

MCP:

```json
{
  "name": "session_list",
  "arguments": {}
}
```

CLI:

```sh
alas session list
```

The result is a JSON array containing only the caller, its parent when one
exists, and its direct children. A root has no parent; a child has no children
under the v1 authorization model.

Each entry has this stable shape:

```json
{
  "session_id": "UUID",
  "relationship": "self",
  "title": "Investigate parser failures",
  "agent_id": "codex",
  "worktree": {
    "id": "WORKTREE_ID",
    "path": "/path/to/worktree",
    "branch": "feature/parser"
  },
  "state": "running",
  "last_activity_at": 1784149200,
  "error": null
}
```

`relationship` is `self`, `parent`, or `child`. `state` is one of:

- `creating_worktree`
- `starting`
- `idle`
- `running`
- `awaiting_input`
- `failed`
- `closed`

`awaiting_input` includes an ACP permission, question, elicitation, or other
user-input wait. `error` is present only for `failed` and contains a short safe
reason. Entries never contain prompts, transcript excerpts, tool output, or
permission details.

### `session_new`

MCP:

```json
{
  "name": "session_new",
  "arguments": {
    "prompt": "Investigate the parser failures and report back.",
    "agent": "codex",
    "new_worktree": {
      "branch": "investigate/parser",
      "base": "origin/main"
    }
  }
}
```

Supported arguments:

- `prompt` is required and must be non-blank.
- `agent` is optional. Omission inherits the parent's agent ID.
- `worktree` optionally names an existing visible worktree by the same project
  resolver used by other CLI worktree commands.
- `new_worktree` optionally contains required `branch` and optional `base`.
- `worktree` and `new_worktree` are mutually exclusive.
- Omitting both worktree arguments uses the parent's current worktree.

CLI:

```sh
alas session new --prompt "Investigate the parser failures and report back."
alas session new --prompt "Fix the tests." --agent claude --worktree feature/tests
alas session new --prompt "Try the migration." --new-worktree spike/migration --base origin/main
```

The command validates and persists the intent, allocates the child session ID,
and returns without waiting for worktree creation or an agent turn:

```json
{
  "session_id": "CHILD_UUID",
  "parent_session_id": "PARENT_UUID",
  "agent_id": "codex",
  "state": "creating_worktree",
  "worktree": {
    "id": "OPTIMISTIC_WORKTREE_ID",
    "path": "/path/to/planned-worktree",
    "branch": "spike/migration"
  }
}
```

For a current or existing worktree, the initial state is normally `starting`.
The response means the operation is durably accepted, not that worktree
creation, adapter setup, authentication, or the initial agent turn succeeded.
Callers use `session_list` for subsequent state.

The selected agent must be enabled and have an `ACPLaunchCatalog` entry. The
child uses the user's normal new-ACP-session auto-run default; the parent may
not pass or inherit a more permissive per-session setting.

### `session_send`

MCP:

```json
{
  "name": "session_send",
  "arguments": {
    "session_id": "CHILD_OR_PARENT_UUID",
    "prompt": "Please also cover malformed UTF-8 input."
  }
}
```

CLI:

```sh
alas session send CHILD_OR_PARENT_UUID "Please also cover malformed UTF-8 input."
```

Both fields are required and `prompt` must be non-blank. The target must be the
caller's direct parent or child. On success:

```json
{
  "session_id": "CHILD_OR_PARENT_UUID",
  "accepted": true,
  "delivery": "queued"
}
```

`accepted` means the prompt is durably stored for the authorized target. It
does not wait for the target agent to begin or finish the turn. Delivery uses
FIFO queue semantics while the target is busy, starting, disconnected, or
recovering. It never activates the target worktree, opens a tab, or changes
window focus.

Sending to a `failed` or `closed` target returns an error with the target's safe
failure reason where available. A transient lack of an attached runner is not
an error when the session remains recoverable.

### CLI Context Requirement

The Rust parser exposes all three commands for CLI/MCP parity. Swift requires
the request's `session_id` to resolve to an ACP session. Calls from an external
shell, directory-only dispatch, or an Alas terminal unrelated to an ACP session
fail with:

```text
alas: session commands require an originating ACP session
```

The MCP server always satisfies this requirement because Alas injects its local
ACP session ID through `ALAS_SESSION_ID`.

## App-Level Orchestration Store

Add one SQLite store under Application Support, separate from every worktree's
ACP session database:

```text
~/Library/Application Support/Alas/acp-orchestration.sqlite
```

The store contains relationship and delivery metadata only. Transcripts,
normal ACP queue state, drafts, permissions, and leases remain in the existing
per-worktree databases.

### Delegation Records

Conceptually, each child record contains:

```swift
struct ACPDelegationRecord: Equatable, Sendable {
    let childSessionId: String
    let parentSessionId: String
    let projectId: String
    let parentWorktreeId: String
    var childWorktreeId: String?
    let agentId: String
    let worktreeRequest: ACPDelegatedWorktreeRequest
    var pendingInitialPrompt: String?
    var phase: ACPDelegationPhase
    var failureMessage: String?
    let createdAt: Int64
    var updatedAt: Int64
}
```

`ACPDelegatedWorktreeRequest` records current, existing, or new-worktree intent
and enough resolved destination metadata to render progress and reconcile an
interrupted creation. `ACPDelegationPhase` persists only orchestration-owned
phases: `creatingWorktree`, `starting`, `ready`, `failed`, and `closed`.
`session_list` projects `ready` into `idle`, `running`, or `awaiting_input` from
the target session's live/persisted state.

The initial prompt remains in this store only until it is durably inserted into
the child's normal ACP queue. It is then cleared. This makes creation crash-safe
without creating a second permanent transcript.

### Delegated Message Inbox

`session_send` writes an authorized message to a short-lived durable inbox in
the orchestration database. Conceptually:

```swift
struct ACPDelegatedMessage: Equatable, Sendable {
    let id: String
    let sourceSessionId: String
    let targetSessionId: String
    let prompt: String
    let createdAt: Int64
}
```

The coordinator validates the edge before insertion. An Alas instance that can
legitimately drive the target claims the inbox item, persists it into the
target session's FIFO queue with the message ID and source provenance, and only
then removes the inbox row. The message ID makes the transfer idempotent if the
app stops between the target write and inbox cleanup.

This inbox preserves the existing per-session writer lease as the authority for
ACP queue mutation. It also lets `session_send` return after durable acceptance
when another Alas instance currently owns the target. Store changes use a
lightweight cross-process notifier plus a bounded polling fallback, following
the existing ACP persistence pattern.

Prompt text is never logged or included in orchestration errors. Once delivery
is confirmed, the orchestration database retains no copy.

## Coordinator And App Boundaries

Add an app-level `ACPSessionOrchestrationCoordinator` that owns the
orchestration store and coordinates AppState-owned capabilities. It does not
replace `ACPSessionManager`.

Responsibilities:

1. Resolve the originating ACP session and worktree.
2. Authorize list, create, and send operations from the persisted graph.
3. Validate agent selection and worktree requests against current AppState.
4. Allocate child IDs and persist delegation records.
5. Run new-worktree creation asynchronously without changing focus.
6. Lazily obtain the child worktree's `ACPSessionManager`.
7. Create the child session using the preallocated ID.
8. Persist the initial prompt with delegated provenance and start attach/queue
   flushing without requiring a visible tab.
9. Route durable inbox messages to whichever instance owns the target writer
   lease.
10. Publish relationship and state summaries for MCP responses and SwiftUI.

`AlasActionService` gains narrow injected closures for these three operations,
and `AlasCLICommandRouter` continues to resolve the origin before dispatching.
The service and router speak typed domain requests rather than reaching into
SQLite or SwiftUI.

`ACPSessionManager.createSession` gains an internal form that accepts a
preallocated local ID. Ordinary UI creation continues using its UUID-generating
convenience method. The manager also gains a delegated-prompt enqueue operation
that:

- always persists before reporting acceptance;
- records source session and message ID provenance;
- preserves FIFO order when the target is busy;
- starts or reconnects the runner when appropriate; and
- does not wait for the ACP `session/prompt` turn to finish.

The existing worktree creation path currently returns an optimistic row while
Git work continues in an unstructured task. Extract or extend its shared core
so orchestration receives a completion result without polling published UI
state. UI-created worktrees retain their current focus behavior; delegated
creation passes a no-focus policy and still reuses branch validation, path
templates, base selection, fetch behavior, startup scripts, remote handling,
project refresh, and failure cleanup.

## Creation Flow

### Current Or Existing Worktree

1. Validate root authority, prompt, agent, and target worktree.
2. Allocate the child session ID.
3. Persist a `starting` delegation record and pending initial prompt.
4. Return the accepted `session_new` response.
5. Get or create the target worktree's session manager.
6. Create the child with the preallocated ID and normal auto-run default.
7. Persist the initial prompt into the child's queue with parent provenance.
8. Clear `pendingInitialPrompt`, mark the record `ready`, and start attach/flush.
9. Publish state changes to MCP list callers and SwiftUI observers.

### New Worktree

1. Validate root authority, prompt, agent, branch, base, and destination.
2. Allocate both the optimistic worktree ID and child session ID.
3. Persist a `creatingWorktree` record and pending initial prompt.
4. Return the accepted `session_new` response.
5. Run the shared worktree creation path with no focus or tab activation.
6. Reconcile the project and bind the real worktree ID to the delegation.
7. Continue with steps 5 through 9 of the existing-worktree flow.

The delegated session starts independently of `ACPTabView`; opening a tab is a
presentation action, not the trigger for attach. Setup or authentication needs
after the child exists are represented through normal ACP state rather than
being treated as worktree-creation failure.

### Relaunch Reconciliation

At startup, reconcile nonterminal records:

- If a planned worktree now exists and resolves to the recorded project,
  continue child creation and initial-prompt delivery.
- If a `starting` child already exists in its per-worktree store, resume prompt
  transfer idempotently.
- If neither condition can be proven, mark the record `failed` with an
  interruption reason rather than repeating a Git mutation automatically.

The UI offers Retry for a failed creation. Retry reuses the same child session
ID and pending initial prompt after revalidation. There is no MCP
`session_retry` tool in v1; an agent sees the failure through `session_list` and
can inform the user or continue with another child.

## Session State Projection

The coordinator derives public state in this order:

1. Persisted orchestration `failed` or `closed` wins.
2. `creatingWorktree` maps to `creating_worktree`.
3. `starting` or an attach/setup transition maps to `starting` unless it has a
   terminal safe failure.
4. A pending permission, question, or elicitation maps to `awaiting_input`.
5. Sending or streaming maps to `running`.
6. A ready/recoverable session without active work maps to `idle`.
7. A missing or archived session/worktree that cannot be recovered maps to
   `closed`.

`last_activity_at` is the maximum of orchestration updates and the target
session's persisted activity. State projection must not hydrate or decode a
full transcript.

## Prompt Provenance And Reporting

Prompts transferred by `session_new` or `session_send` are ACP user prompts on
the wire because they instruct the target agent. They are not authored by the
human user, so Alas persists optional delegated provenance alongside the queue
item and resulting transcript message:

```swift
struct ACPDelegatedPromptSource: Codable, Equatable, Sendable {
    let messageId: String
    let sourceSessionId: String
}
```

The target transcript labels these bubbles as coming from a delegated session
rather than presenting them as ordinary user-authored text. Older rows decode
without provenance and retain current rendering.

For a delegated child, the built-in Alas MCP injection includes parent
metadata, for example `ALAS_PARENT_SESSION_ID`. The MCP `initialize`
instructions explain that the session is a delegated child, identify its
parent, and direct it to report results or blocking questions with
`session_send`. `session_list` supplies the same relationship through normal
tool data.

Alas does not rewrite the initial prompt, inject a hidden transcript message,
or automatically copy the child's final response to the parent. Reporting is
an explicit child action. If the child becomes idle without reporting, the
parent can observe `idle` through `session_list` and send a follow-up.

## UI Design

Extend existing ACP session surfaces rather than adding a dashboard.

### Parent

The existing session popover gains a **Delegated sessions** section below the
current-session header. Each child row shows:

- agent icon/name;
- worktree name or branch;
- live state;
- unread activity, awaiting-input, or failure indication; and
- a short safe error tooltip for failures.

The row appears immediately after `session_new` is accepted, including while
the worktree is being created. Clicking it switches to the child's worktree and
opens or focuses that ACP session. Creation itself never changes focus.

### Child

A child session shows a compact **Delegated by [parent title]** backlink in the
existing session/toolbar area. Activating it switches to and opens the parent.
The child does not show a creation affordance for grandchildren; server-side
authorization remains authoritative even if a stale client still attempts the
call.

### Failure And Activity

Failed child creation remains visible with Retry. Retry is a user action and
does not create a second child identity. Closing a parent tab does not stop its
children. Idle children do not auto-close, auto-archive, or delete their
worktrees.

An incoming delegated prompt uses the existing transcript bubble structure
with a compact source label/backlink. It is not placed in a new nested card.
Unread delegated activity reuses the session activity styling already used by
Alas rather than adding modal alerts or automatically activating the app.

## Lifecycle Ownership

Delegated sessions are ordinary persistent ACP sessions once created:

- The user owns their tabs, archive state, permissions, and worktrees.
- Parent archival or tab closure does not cascade.
- Child idle state is not completion and causes no cleanup.
- Agents cannot close, archive, delete, or retry sessions through these tools.
- Relationship records remain available when either endpoint is archived so
  provenance is not silently lost.
- A permanently removed endpoint projects as `closed`; the other endpoint may
  still show the historical relationship until normal user cleanup removes it.

## Rust And Swift Wire Changes

Rust changes preserve the umbrella issue's params-envelope rule:

- Add `SessionList`, `SessionNew`, and `SessionSend` to `alas_client::Command`.
- Encode all new arguments under `Request.params`; add no new legacy flat
  fields.
- Add `alas session ...` parsing and usage text.
- Add matching MCP definitions and strict argument validation.
- Keep path/worktree authority in Swift; Rust validates only shape, required
  values, mutual exclusion, and non-blank strings.
- Treat the app's JSON line as opaque command output for CLI and MCP content.

Swift changes:

- Add typed params decoding in `AlasCLIRequest`.
- Add typed commands to `AlasCLICommandRouter` and `AlasActionService`.
- Resolve and require an ACP origin before any orchestration action.
- Return one deterministic JSON line for each command.
- Keep authorization and target resolution in the coordinator/service layer,
  never in SwiftUI or the Rust front end.

## Error Handling

Errors are short, stable enough for agents, and contain no prompt or transcript
content. Expected cases include:

```text
session commands require an originating ACP session
delegated sessions cannot create child sessions
target session is not the caller's parent or child
target session is closed
agent is not enabled or ACP-capable
unknown worktree "..."
worktree and new_worktree are mutually exclusive
invalid branch name: ...
could not create worktree: ...
could not start delegated session: ...
```

Validation failures do not allocate a child record. Failures after durable
acceptance update the existing record to `failed`. A session setup/auth need is
not collapsed into a generic orchestration failure; it remains visible through
the target ACP session's normal state and UI.

## Testing

### Rust

- CLI parsing for list, new, and send forms.
- Mutual exclusion and required/non-blank argument validation.
- Command-to-params request encoding.
- MCP tool definitions and tool-call translation.
- Stable MCP errors for invalid argument shapes.

### Swift Request And Routing

- Params decoding for all session commands.
- ACP-origin requirement versus directory/terminal origins.
- Router forwarding and deterministic JSON response encoding.
- Unknown/disabled/non-ACP agent rejection.
- Current, existing, and new-worktree request resolution.

### Authorization

- A root can create direct children.
- A child cannot create a child.
- Parent-to-child and child-to-parent sends succeed.
- Sibling, unrelated, cross-project, missing, failed, and closed targets fail.
- Forged session/worktree IDs cannot widen the graph.
- Auto-run changes no server-side authorization result.

### Persistence And Concurrency

- Delegation records and pending prompts survive store reopen.
- Initial prompt transfer clears the orchestration copy only after target queue
  persistence succeeds.
- Inbox claim and message-ID deduplication prevent duplicate prompts.
- A writer takeover cannot let the stale instance mutate the target queue.
- Another Alas instance can consume a durable message after acquiring the
  legitimate target lease.
- Relaunch reconciliation continues proven worktrees/sessions and honestly
  fails ambiguous interrupted operations.

### Session And Worktree Flow

- Existing-worktree creation allocates the requested child ID, queues the
  prompt, attaches without a tab, and does not focus.
- New-worktree creation uses shared validation/startup behavior and does not
  focus.
- Worktree failure persists a retryable failed child.
- Retry reuses the same child ID and does not duplicate the prompt.
- `session_send` accepts while idle, busy, disconnected, or starting and
  preserves FIFO order.
- Delegated provenance round-trips through queue and transcript persistence.

### State And UI Policy

- Public state projection covers every persisted/runtime combination.
- List output contains only self, parent, and direct children.
- List output never includes transcript or prompt data.
- Parent rows expose creation, activity, awaiting-input, failure, and retry.
- Child backlink resolves across worktrees.
- Delegated prompt rows are visibly attributed and remain backward-compatible
  with ordinary transcript rows.

After focused tests, run the repository-required `xcodegen`, quiet macOS build,
and full test suite. Rust workspace tests cover the CLI/MCP side.

## Implementation Sequence

1. Add the orchestration store, models, graph authorization, and pure state
   projection tests.
2. Add Swift request types, action-service boundaries, and router tests.
3. Add Rust CLI/MCP commands and wire tests.
4. Add preallocated session creation, delegated queue provenance, and durable
   inbox transfer.
5. Add no-focus worktree completion plumbing and asynchronous child creation.
6. Add dynamic MCP delegation instructions.
7. Add parent/child UI surfaces, retry, navigation, and unread activity.
8. Run focused integration tests, standard project generation/build/tests, and
   manual end-to-end verification with two agents in separate worktrees.
