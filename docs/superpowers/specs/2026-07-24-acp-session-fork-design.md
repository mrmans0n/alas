# ACP Session Fork Design

**Date:** 2026-07-24  
**Status:** Design approved, ready for implementation planning

## Context

Alas already decodes the ACP agent capability for `session/fork` and exposes a
typed `ACPConnection.forkSession` call, but it does not turn a remote fork into
an independently persisted and runnable Alas chat.

The current ACP
[session-fork RFD](https://agentclientprotocol.com/rfds/session-fork) remains a
draft. Its request forks an entire remote session at its current head. The RFD
reserves the capability object for a future message-ID checkpoint, but the
current request cannot fork at an arbitrary message.

Alas can provide the missing checkpoint behavior because it owns a durable
local transcript. It can copy the conversation through a selected message into
a new local session and supply that conversation privately to a fresh target
agent. This also enables cross-provider forks, where a provider-native remote
fork is impossible.

This design treats a fork as a conversation branch in the same worktree. It
does not rewind files or create a Git worktree.

## Goals

- Add `Fork from here` to the existing per-message `…` menu.
- Let the user fork through any completed user or agent message.
- Let the user target the current ACP agent or another enabled ACP agent.
- Use native ACP `session/fork` when it exactly implements the requested fork.
- Fall back to a portable textual transcript for arbitrary checkpoints and
  cross-provider forks.
- Show inherited conversation history in the new chat with clear provenance.
- Keep the source session unchanged.
- Persist creation and pending context durably so relaunch and retry are safe.
- Reuse the current worktree, project MCP configuration, permission policy, and
  normal target-agent setup flows.

## Non-Goals

- Rewinding Git or filesystem state to the selected message.
- Creating or selecting another worktree.
- Forking a partial streaming response.
- Copying thoughts, tool calls, tool output, file-edit cards, plans, system
  notices, pending permissions, pending questions, queued prompts, or drafts.
- Transferring binary/image attachments or embedded context.
- Preserving provider-private tool state in transcript-transfer forks.
- Synchronizing later messages between the source and fork.
- Supporting a future ACP message-ID fork extension before it is specified and
  implemented by agents.

## Product Contract

### Fork point

`Fork from here` is available on completed textual user and agent messages.
The selected message is inclusive: the target inherits eligible conversation
messages from the beginning of the source chat through that message.

The currently streaming agent response is not an eligible boundary. Completed
earlier messages remain eligible while a later turn is active.

### Worktree state

The fork opens in the source session's current worktree and sees that
worktree's current filesystem state. The conversation checkpoint and filesystem
state are intentionally independent. Both chats may continue to operate in the
same worktree.

### Snapshot contents

The inherited snapshot contains only:

- Completed user message text, without attachments.
- Completed agent message text.

It preserves message order and Markdown. The visible inherited transcript and
the privately transferred target context use the same snapshot, so the UI does
not imply that the target received omitted material.

### Initial target state

Choosing a target opens a new tab immediately. The tab:

- Uses the title `<source title> (fork)`.
- Shows the inherited conversation.
- Shows an empty, focused composer.
- Does not ask the target agent to respond automatically.

The first real user prompt begins the new branch.

## Interaction Design

The existing native message menu becomes:

```text
Copy message
────────────
Fork from here  ▸
    Claude       Same agent
    Codex
    Gemini
```

The current agent is first. Remaining enabled agents with an
`ACPLaunchCatalog` entry follow their existing configured order. The current
agent remains available even when it does not support native ACP fork because
Alas can use transcript transfer.

After the inherited messages, the target transcript shows a fork divider that
links to the source session.

- Native fork: `Forked from <agent>`
- Transcript fork: `Conversation imported from <agent>`

Transcript forks also show a compact notice:

> Provider-specific tool state, hidden context, and attachments were not
> transferred. This chat shares the source chat's current worktree.

If the source session is archived, following the divider reopens it through the
normal existing-session path.

## Mechanism Selection

One pure policy selects the mechanism.

Use `nativeACP` only when all of these are true:

- Target agent equals source agent.
- Selected message is the latest completed source message.
- Source has a non-empty remote session ID.
- The source agent advertises the ACP fork capability.

Use `transcriptTransfer` for every other case.

This lets the product expose one consistent action while retaining richer
provider context when native forking precisely matches the requested boundary.
The final mechanism is persisted and never changes after the creation phase
reaches `ready`.

## Architecture

### `ACPSessionForkCoordinator`

A dedicated coordinator owns the operation. UI code supplies:

```swift
struct ACPSessionForkRequest {
    let sourceSessionID: ACPSession.ID
    let boundary: ACPForkMessageBoundary
    let targetAgentID: String
}
```

The coordinator:

1. Resolves the selected row to a durable source-message sequence.
2. Loads the complete eligible prefix.
3. Selects a native candidate or immediate transcript transfer.
4. Atomically persists the target session, copied messages, and fork creation
   metadata.
5. Publishes the target session for `AppState` to open immediately.
6. Negotiates native fork in the new tab's connecting phase when selected,
   degrading to transcript transfer when native negotiation is unavailable.
7. Atomically finalizes the mechanism and, for native success, the remote
   session ID.
8. Hands a successful native connection to the target runner, or starts the
   normal fresh-session attach path for transcript transfer.

The coordinator does not own tabs or message-menu presentation. `AppState`
opens the returned local session using the normal ACP-session tab path.

### Durable boundary resolution

Long sessions hydrate tail-first, and the rendered list contains only a moving
window. Forking must not treat a visible array index as a durable transcript
index.

The message row passes a stable message identity in
`ACPForkMessageBoundary`. Before creating the snapshot, the manager:

1. Awaits any in-flight transcript backfill.
2. Re-resolves that stable identity in the completed full transcript.
3. Flushes source message persistence.
4. Loads persisted message rows through the resolved absolute sequence.

If the selected identity disappears or no longer resolves to the same
completed user/agent message, creation fails without modifying either session.

### Fork persistence

Fork metadata belongs with the target session in the existing per-worktree ACP
database. Conceptually it records:

```swift
struct ACPSessionForkMetadata {
    let targetSessionID: ACPSession.ID
    let sourceSessionID: ACPSession.ID
    let sourceAgentID: String
    let sourceBoundarySequence: Int64
    let inheritedMessageCount: Int
    var phase: ACPSessionForkCreationPhase
    var mechanism: ACPSessionForkMechanism?
    var contextDeliveryPending: Bool
}

enum ACPSessionForkCreationPhase: String {
    case negotiatingNative
    case ready
}

enum ACPSessionForkMechanism: String {
    case nativeACP
    case transcriptTransfer
}
```

The target session row, copied target-local message rows, and fork metadata are
inserted in one SQLite transaction. Copied messages receive target-local
storage IDs and contiguous target-local sequences.

An immediate transcript fork is inserted as `ready` with mechanism
`transcriptTransfer` and pending context. A native candidate is inserted as
`negotiatingNative` with no final mechanism, no sendable runner, and pending
context disabled. Its composer may accept a queued draft, but prompt delivery
waits until the phase becomes `ready`. Native success leaves pending context
disabled; fallback atomically enables it while finalizing
`transcriptTransfer`.

The snapshot Markdown is not stored separately. While context delivery is
pending, Alas regenerates it from the first `inheritedMessageCount` messages in
the target session. This avoids two durable copies of the same potentially
large content.

Transcript-transfer targets are ordinary Alas-created remote sessions with fork
metadata. Native targets use the existing `agentForked` origin and store the
remote session ID returned by the agent.

### Runtime session capability

`ACPSession` retains the initialized session capabilities at runtime, as it
already does for prompt and MCP capabilities. They are re-learned on attach and
are not persisted. A known missing fork capability selects transcript transfer
immediately. If capability state is unavailable but the other native
preconditions hold, the coordinator creates a `negotiatingNative` target and
learns the capability from that target's initialization. A missing capability
then finalizes the target as transcript transfer.

### Native connection handoff

Native fork must not assume that the resulting remote session can immediately
be reopened through a separate `session/resume`.

After the local target is visible, the coordinator initializes a target-agent
connection, invokes `session/fork`, atomically finalizes the local metadata and
remote ID, and hands that live connection plus `ACPSessionNewResult` to the
normal runner startup path. The source runner and connection remain unchanged.

The target runner then owns the connection exactly as if normal attach had
created it. Models, modes, configuration options, suggestions, MCP status, and
remote session ID come from the fork result and normal initialization.

The fork request uses a stable broker operation key derived from the local
target ID. Startup reconciliation consumes a durable native response when one
exists. If no unambiguous native result is available after relaunch, Alas does
not reissue the fork: it finalizes the existing local target as transcript
transfer and follows normal attach. This avoids creating duplicate remote
forks.

If finalizing local native state fails after the remote fork succeeds, the
coordinator best-effort closes the new remote session and shuts down its
connection before downgrading the still-persisted local target to transcript
transfer. Remote cleanup is not part of the local atomicity guarantee; the
source session still remains unchanged.

### Transcript context delivery

Transcript forks create a normal fresh remote session. They retain
`contextDeliveryPending` until the target's first real user prompt succeeds.

At that first send, the runner:

1. Regenerates the conversation Markdown from the inherited target prefix.
2. Prepends a private instruction explaining that it is background context and
   must not be repeated unless asked.
3. Sends that private context and the user's real prompt in the same ACP prompt
   request.
4. Records only the user's real prompt in the visible transcript.
5. Clears `contextDeliveryPending` after successful delivery.

This follows the existing durable pending-preamble pattern. A relaunch or
failed send retains the pending marker. Native forks never add transcript
context because the provider already owns the inherited context.

## Data Flow

### Transcript-transfer fork

1. User selects a completed message and target agent.
2. UI captures a stable boundary and calls the coordinator.
3. Coordinator resolves and loads the persisted conversation prefix.
4. Coordinator atomically creates the target with copied messages and pending
   context.
5. AppState opens the target tab and normal attach creates a fresh remote
   session.
6. User writes the first new prompt.
7. Runner sends private inherited context plus that prompt.
8. Successful delivery clears the pending marker.

### Native fork

1. User selects the latest completed message and current agent.
2. Coordinator resolves and loads the persisted inherited prefix.
3. Coordinator atomically persists a `negotiatingNative` target and AppState
   opens its tab.
4. Coordinator initializes a target connection and calls `session/fork` with
   the source remote session ID and current MCP attachment plan.
5. Coordinator atomically finalizes the returned remote session ID and native
   mechanism.
6. The target runner adopts the live connection.
7. The first new prompt is sent normally, without transcript injection.

## Error Handling

### Graceful native fallback

The coordinator falls back to transcript transfer in the same target operation
when:

- Fork capability is absent.
- `session/fork` returns method-not-found or explicitly unsupported.
- The agent reports that the source remote session cannot be forked.

The persisted mechanism and divider reflect the fallback. The user is not left
with a failed native placeholder when a portable fork is possible.

### Setup, authentication, and connection failures

If the target agent needs setup or authentication, or its process cannot
connect, a native candidate finalizes as transcript transfer and the local fork
remains available with inherited history. The tab uses the existing setup,
authentication, failure, and retry surfaces when its normal fresh-session
attach is attempted. Pending context remains durable.

### Persistence failure

If the atomic local transaction fails, Alas creates no target session and
opens no tab. The source chat presents a concise `Could not create fork`
error using the persistence error description.

### First-prompt failure

A failed first prompt keeps `contextDeliveryPending` and follows normal
queue/retry behavior. It must not append a second copy of the inherited
conversation or a duplicate visible user prompt.

### Source changes during creation

The source may continue receiving later messages. They are outside the captured
durable boundary and never enter the target. If the selected boundary itself
cannot be re-resolved as the same completed message, the operation fails
instead of guessing.

## Testing

### Mechanism policy

- Same agent + latest completed message + remote ID + fork capability selects
  native ACP.
- Earlier checkpoint selects transcript transfer.
- Different target agent selects transcript transfer.
- Missing capability or remote ID selects transcript transfer.
- A later streaming response means an earlier selected message is not the
  latest completed head for native selection.

### Snapshot construction

- Snapshot is inclusive of the selected boundary.
- Durable boundary resolution remains correct after tail-first hydration and
  backfill.
- Only user and agent text is copied.
- Attachments and every excluded message kind are omitted.
- Copied rows receive contiguous target-local sequence numbers and identities.
- Source messages remain byte-for-byte unchanged.

### Persistence

- Session, copied messages, and fork metadata commit atomically.
- Injected transaction failure leaves no orphan session or messages.
- Metadata and pending delivery survive manager eviction and app relaunch.
- An interrupted `negotiatingNative` phase consumes a durable native result
  when available and otherwise becomes a ready transcript fork without
  reissuing an ambiguous remote fork.
- Snapshot Markdown regenerates from exactly the inherited target prefix.

### Coordinator and protocol

- Native success calls `session/fork` with source remote ID, worktree path, and
  current MCP servers plus a stable target-derived broker operation key.
- Native result and live connection are adopted by the new runner.
- Capability absence, method-not-found, explicit unsupported, and
  non-forkable-source errors fall back to transcript transfer.
- Setup/auth/process failure preserves the local fork and exposes normal
  recovery state.

### Runner

- First transcript-fork prompt sends private context and real prompt together.
- Private context is not recorded as a visible message.
- Failed delivery retains pending context.
- Successful delivery clears pending context.
- Retry and relaunch send one inherited context payload and do not duplicate
  visible messages.
- Native fork prompts never include transcript context.

### UI policy

- Completed user and agent messages expose the submenu.
- A streaming agent message does not expose a fork action.
- Current agent is first and labeled `Same agent`.
- Other enabled ACP agents preserve configured order.
- Divider and notice text match the persisted mechanism.
- Source divider navigation reopens or focuses the source session.

### Verification

Run the focused ACP protocol, persistence, manager/coordinator, runner, and UI
policy suites. Then run:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

The repository's full required test command remains the final implementation
gate.

## Anticipated Implementation Areas

- New `ACPSessionForkCoordinator` and pure mechanism/snapshot policy types
  under `Alas/Sources/ACP/Session`.
- `Alas/Sources/ACP/Protocol/ACPConnection.swift`
  - Native fork durable-response behavior and best-effort remote close.
- `Alas/Sources/ACP/Session/ACPSession.swift`
  - Runtime session capabilities and fork presentation state.
- `Alas/Sources/ACP/Session/ACPSessionManager.swift`
  - Boundary resolution, connection handoff, runner startup, and source-link
    navigation support.
- `Alas/Sources/ACP/Session/ACPSessionPersistence.swift`
  - Snapshot loading and atomic fork creation.
- `Alas/Sources/ACP/Session/ACPSessionStore.swift`
  - Fork metadata schema and transactional writes.
- `Alas/Sources/ACP/Session/ACPSessionRunner.swift`
  - One-time private context delivery.
- `Alas/Sources/ACP/UI/ACPMessageGutter.swift`
  - Native target-agent submenu.
- `Alas/Sources/ACP/UI/ACPMessageList.swift`
  - Completed-message boundary wiring and fork divider.
- `Alas/Sources/App/AppState.swift`
  - Coordinator ownership and target-tab opening.
- New focused fork policy, coordinator, persistence, runner, and UI-policy
  tests under `AlasTests/ACP`.
