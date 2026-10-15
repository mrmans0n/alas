# AlasCore Host API Design

Tracking: #1915 (umbrella), #1923 (headless host).

## Goal

Give the core one deliberate API that every front end goes through: the Mac app, the CLI and MCP tools, Alas Remote, plugins, and a headless `alas-host` process. Each domain operation has exactly one implementation, behind a boundary the compiler enforces.

## Non-goals

- Turning the Mac app into a client of a separate daemon. The app keeps the core in-process, as #1915 says.
- A Linux build. `alas-host` targets macOS until a concrete Linux client exists.
- Making views read through the wire model. In-process UI may keep binding to core `@Observable` stores; what must be single is how state is *changed*.

## Where we are

The core is extracted, but the front ends do not share it. There are four facades, and each reaches into `AppState` its own way:

| Surface | Used by | Shape |
|---|---|---|
| `AlasCoreContext` | tests | Domain verbs (`addProject`, `createWorktree`, `runScript`, `archiveWorktree`, `unarchiveWorktree`, `deleteWorktree`, `sessionManager(for:)`) with **no app callers**. The app keeps parallel versions in `AppState` (`createWorktree`, `archiveWorktree`, `unarchiveWorktree`, `deleteWorktree`). The rest of the public surface is app plumbing (run observation and settlement, `removeWorktree(request)`, repo-hook preparation), live state (`projects`, `sessionManagers`, `runRecords`) and seven mutable hook closures. |
| `AlasActionService` + `AlasCLICommandRouter` | CLI and MCP (MCP tools are mapped to the same socket commands in `AlasCLI/crates/alas/src/mcp.rs`) | Closures filled in by `AppState.makeCLICommandRouter`. `workspace`, `preview` and `visual_show` bypass the service as router closures. Caller origin (session id or cwd to worktree/owner) is resolved from `AppState` lookups. |
| `RemoteSessionsProvider` | Alas Remote (web and peers) | About 40 requirements implemented by `AppState` (~1,600 lines). Returns live `ACPSession` and `ACPPermissionPolicy`. Session lists are polled every 15 s; only one session's transcript, queue and config are pushed. No worktree lifecycle beyond create-with-session, no projects, runs or workspaces. |
| `PluginHostActions` | JavaScriptCore plugins | Closures built in `AppState+Plugins`. Runs start through the terminal path, reviews come from the right pane's loaded state, and the snapshot includes the UI selection. |

The same operation therefore has up to four entry points with slightly different semantics. Worktree creation, for example, selects the new worktree from the CLI, focuses and opens a tab from Remote, and launches a surface from plugins.

## Principles

1. **One implementation per verb.** A domain operation lives in the core once. Front ends adapt it; they do not reimplement it.
2. **Values at the boundary.** Inputs, results, snapshots and events are `Sendable`, `Codable` values with typed errors. No `ProjectsManager`, `ACPSession`, `ACPSessionManager` or request-with-closure types cross it.
3. **Domain and presentation are separate.** Opening, focusing, selecting and showing are presentation. The host never does them; a front end may do them after a verb returns.
4. **The app is the host's richest environment, not its owner.** Behavior the app adds (killing terminals before removal, prompting for repo hooks, terminal-backed runs) arrives through one environment protocol. Headless gets defaults that never prompt.
5. **Lists are pushed.** Every snapshot has an event stream that keeps it current, so no client polls.

## Shape

### Host

```swift
@MainActor
public final class AlasHost {
    public init(storage: AlasHostStorage, environment: any AlasHostEnvironment)

    public var projects: ProjectsAPI { get }
    public var worktrees: WorktreesAPI { get }
    public var workspaces: WorkspacesAPI { get }
    public var sessions: SessionsAPI { get }
    public var runs: RunsAPI { get }
    public var reviews: ReviewsAPI { get }
    public var attention: AttentionAPI { get }

    /// Current state plus the cursor its events continue from.
    public func snapshot() -> (HostSnapshot, HostCursor)
    /// One subscriber's stream. List-level events always flow; transcript
    /// events only for the sessions the subscription follows.
    public func subscribe(after cursor: HostCursor) -> HostSubscription
}

@MainActor
public final class HostSubscription {
    public var events: AsyncStream<HostEvent> { get }
    public func follow(_ session: SessionID, from revision: TranscriptRevision?)
    public func unfollow(_ session: SessionID)
    /// Ends the stream and releases every followed session.
    public func cancel()
}
```

`AlasHost` is the public entry point. `AlasCoreContext` stays as the engine behind it.

The domain APIs are thin structs over the engine. Indicative signatures:

```swift
public struct WorktreesAPI {
    public func list(projectID: String?) -> [WorktreeSnapshot]
    public func create(_ request: WorktreeCreateRequest, caller: HostCaller) async throws -> WorktreeSnapshot
    public func delete(_ ref: WorktreeRef, options: WorktreeDeleteOptions, caller: HostCaller) async throws
    public func archive(_ ref: WorktreeRef, caller: HostCaller) async throws
    public func unarchive(_ ref: WorktreeRef, caller: HostCaller) throws
}

public struct SessionsAPI {
    public func list(_ filter: SessionFilter) -> [SessionSummary]
    public func create(_ request: SessionCreateRequest, caller: HostCaller) async throws -> SessionSummary
    public func send(_ sessionID: SessionID, prompt: PromptInput, caller: HostCaller) async throws
    public func stop(_ sessionID: SessionID) async
    public func transcript(_ sessionID: SessionID, page: TranscriptPageRequest) async throws -> TranscriptPage
    public func respond(_ sessionID: SessionID, to request: PendingRequestID, with answer: PendingRequestAnswer) async throws
    public func configure(_ sessionID: SessionID, _ change: SessionConfigChange) async throws
    public func queue(_ sessionID: SessionID, _ edit: QueueEdit) async throws
}
```

Sessions are addressed by `SessionID` and owned by the existing `SessionOwnerID` (a worktree or a Workspace checkout), treated the same everywhere. `WorktreeRef` is `(projectID, path)`, matching the claim key, since a path can exist under more than one host's project. `HostCaller` names who asked: the app, a CLI/MCP origin (session id or cwd), a Remote peer, or a plugin. It is used for authorization and attribution only, never for presentation.

`HostCaller` is never part of a wire message. Each transport adapter builds it from what it authenticated:
- the Remote adapter from the paired peer identity of the connection;
- the socket adapter from the connection's local user, plus a session id or cwd that it resolves against the host's own registry, refusing ones that resolve to nothing;
- the plugin host from the plugin's identity and its project scope.

A client can name a target, but it can never name who it is.

Errors are per-domain enums, extending the ones that exist (`WorktreeDeletionRefusal`, `WorktreeArchiveRefusal`, `WorkspaceCheckoutCoordinatorError`).

### Snapshots and events

```swift
public enum HostEvent: Sendable, Codable {
    case projectChanged(ProjectSnapshot), projectRemoved(id: String)
    case worktreeChanged(WorktreeSnapshot), worktreeRemoved(WorktreeRef)
    case workspaceCheckoutChanged(WorkspaceCheckoutSnapshot), workspaceCheckoutRemoved(id: UUID)
    case sessionChanged(SessionSummary), sessionRemoved(SessionID)
    case transcript(SessionID, TranscriptDelta)
    case pendingRequest(SessionID, PendingRequest), pendingRequestResolved(SessionID, PendingRequestID)
    case runChanged(RunSnapshot), runRemoved(RunID)
    case attentionChanged(AttentionSnapshot)
    case resync
}
```

- Every keyed kind has a removal event, including runs, whose finished records and history are purged.
- `WorktreeSnapshot` carries the operation state (`creating`, `deleting`, `archiving`, failures), so clients see claims instead of inferring them.
- Events coalesce per key. A slow subscriber gets `resync` and re-reads the snapshot instead of an unbounded backlog.
- Transcripts reuse `ACPTranscriptChangeLog`'s epoch and revision model. A subscription receives `transcript` and pending-request events only for sessions it follows, like Remote's `subscribe`/`unsubscribe` today. Following retains the session's change log, and unfollowing or cancelling releases it, so a transcript is tracked exactly while someone follows it.
- The in-process app does not need the stream. It keeps observing core stores directly, but every mutation it makes goes through the same verbs, so the two cannot diverge.

### Environment

```swift
@MainActor
public protocol AlasHostEnvironment: AnyObject {
    func quiesceWorktree(_ worktree: WorktreeSnapshot) async throws
    func stopWorkspaceCheckoutSessions(_ checkout: WorkspaceCheckoutSnapshot) async throws
    func decideRepoHook(_ hook: RepoHook, context: RepoHookApprovalContext) async -> RepoHookApprovalDecision
    func checkpointRecoveryBlocksRemoval(_ worktree: WorktreeSnapshot) async -> Bool
    func launchWorktreeCleanup(_ ticket: WorktreeTrashCleanupTicket) throws
    func globalTerminalConfig() -> AppConfig.Terminal
    var runLauncher: any RunLauncher { get }
}
```

This replaces the seven hook closures installed in `AppState.init`. `HeadlessHostEnvironment` provides the defaults: skip unapproved hooks, stop processes without terminals, and launch runs as plain processes with output captured to run history.

`RunLauncher` is how runs become one implementation. The app's launcher is terminal-backed and the headless one is process-backed. Starting, stopping, settling and recording a run is core logic either way. Run observation and settlement plumbing (`observeRun`, `finalizeRun`, `resolveRunSettlements`, `takeRunCapture` and their 20-odd app call sites) moves behind the launcher seam instead of being exported.

### Presentation

```swift
@MainActor
public protocol AlasHostPresenter: AnyObject {
    func open(_ target: OpenTarget, in worktree: WorktreeRef)
    func focus(_ target: FocusTarget)
    func openReview(_ session: ReviewSessionID, in worktree: WorktreeRef)
    var webPreviews: (any WebPreviewAutomating)? { get }
}
```

Front ends that have a UI pass a presenter to their adapter, not to the host. The CLI router, for example, calls `host.worktrees.create` and then `presenter?.focus(.worktree(ref))`. Without a presenter, commands like `open`, `worktree_switch`, `workspace_focus` and `preview_*` answer "not available on this host".

This is where `AlasActionService`'s closures go: the domain half to the host, the presentation half to the presenter.

### Enforcing the boundary

- **Core stores are read-only outside the core.** Views keep binding to `ProjectsManager`, `ACPSessionManager`, `RunRecordStore` and the other stores, but only through their reads. Their mutators (claims, hidden state, session lifecycle, run records) leave the app's reach as the verbs for each domain land (internal, or test-only SPI when tests seed them), so the app cannot change state except through `AlasHost`. Each phase's exit includes sealing its domain's mutators.
- **Test fixtures** that seed such states use mutators marked `@_spi(Testing) public`: public, as the package boundary requires for anything tests use, but imported only by tests (`@_spi(Testing) import AlasCore`). App code never imports `Testing`.
- **App plumbing** that must stay public for the app only (environment integration, presenter wiring) is marked `@_spi(AppHost) public`. The app imports `@_spi(AppHost) import AlasCore`; nothing else does. SPI is for integration seams, never for mutators, which would reopen the bypass.
- **Out-of-process clients** see only the wire protocol, so the boundary there is the message set.

Sealing the whole package is out of scope. Many value types are rightly public.

### Transport

The host API is transport-free. One wire shape mirrors it, the **host protocol**: snapshot, events and verbs as messages, with its own version. It is carried two ways:

- **Local Unix socket:** authorized by file permissions. This is what `alas-host` clients and local tools use.
- **Remote server:** a versioned namespace on the paired TLS channel, for clients on other machines.

Two shapes sit on top of the host protocol:

- **Remote's web messages** (transcript tails, mentions, tab actions) become a thin layer over it. Peers that predate the host namespace keep being answered in the old messages.
- **The CLI/MCP protocol** stays command-shaped. Its router calls `AlasHost` in-process.

### `alas-host`

`alas-host` is a SwiftPM executable target in `Packages/AlasCore`. It builds `AlasHost` with `HeadlessHostEnvironment` and serves the host protocol on the local socket and, when Remote is enabled, on the Remote server.

- It uses the app's data directory layout, honoring `ALAS_APP_SUPPORT_DIR`.
- It takes an exclusive lock on that directory, and so does the app. The two never write the same state at once; attaching the app to a running host is a non-goal.
- A hostless `swift test` boots it on a temporary directory, then creates a worktree, starts a session against a fake agent, and runs a script, all over the wire.

## Surface mapping

| Today | Becomes |
|---|---|
| `AppState.createWorktree` / `cliCreateWorktree` / `createDelegatedWorktree` / `createRemoteWorktreeSession` / plugin `task/start` | `worktrees.create`, then each front end's presenter call (select, focus or none) |
| `AppState.deleteWorktree` / `cliDeleteWorktree` / `performDeleteWorktree` | `worktrees.delete`. Confirmation dialogs stay in the app, before the call. |
| `AppState.archiveWorktree` / `unarchiveWorktree` | `worktrees.archive` / `unarchive`. The dirty-buffer prompt stays in the app, before the call. |
| CLI `wt list`, Remote `remoteWorktrees`, plugin `workspace/snapshot` | `worktrees.list` and `snapshot()` |
| CLI `agent_list` / `session_*`, Remote session requirements | `sessions.*`. `ACPSessionOrchestrationCoordinator`'s environment closures move onto the host. |
| Remote `openSessionTab` / `closeSessionTab`, `isActive` / `tabIndex` | Presenter, plus app-only fields the Remote adapter adds when a presenter exists |
| CLI `workspace_*`, `WorkspaceAutomationService` | `workspaces.*` (list/show). Switch and focus go to the presenter. |
| CLI `review_*`, plugin `review/comment` and `reviews` | `reviews.*`, owning the draft and session stores the CLI now builds ad hoc. Plugin `reviews` stops depending on the right pane having loaded. |
| CLI `notify` / `cliNotifyOwned` | `attention.notify` |
| Plugin `run/start` / `run/output`, `AlasCoreContext.runScript` | `runs.start` / `runs.output` through `RunLauncher` |
| `AlasCoreContext` hook closures | `AlasHostEnvironment` |
| `open`, `worktree_switch`, `workspace_switch/focus`, `preview_*`, plugin `worktree/switch` / `session/focus` / `notify` / view APIs | Presenter only |

## Phases

Each phase is one or more independent PRs. It is done when its exit criterion holds on `main`.

1. **Converge worktree lifecycle onto the core.** `AppState`'s create, delete, archive and unarchive call the core verbs, and the duplicated logic is deleted. Claims the app opens before a verb runs (the `.preparingDelete` claim held while a confirmation is up, the optimistic `.creating` row) come from core verbs that return the claim token, so the app never writes operation state itself. *Exit:* `AppState` keeps only dialogs and selection for worktree lifecycle, and `ProjectsManager`'s claim and hidden-state mutators are out of the app's reach.
2. **Environment and SPI.** Introduce `AlasHostEnvironment` and `HeadlessHostEnvironment` in place of the hook closures. Mark the remaining app plumbing `@_spi(AppHost)`. *Exit:* `AlasCoreContext` has no settable closure properties, and a test target importing `AlasCore` without SPI cannot reach the plumbing.
3. **Runs.** Introduce `RunLauncher`; terminal-backed and process-backed runs share start, settle and record. *Exit:* no run observation or settlement call remains in `AppState+RunScripts`.
4. **Host facade and snapshots.** Add `AlasHost` with `projects`, `worktrees`, `workspaces` and `runs` as value-typed APIs and `snapshot()`. *Exit:* the CLI's `wt list`, `wt new`, `wt delete` and `workspace_list/show` go through the host.
   - *Decided:* `AlasHost(core:)` is a thin facade over `AlasCoreContext`, which the app keeps holding next to it until callers have moved; ownership moves to the host afterwards.
   - *Decided:* the APIs reuse the existing values (`Worktree`, `ProjectConfig`, `WorkspaceCheckout`, `RunRecord`, now all `Codable`). `WorktreeSnapshot` adds only the operation state and whether the worktree is archived; making the operation state `Codable` waits for the protocol in phase 5.
   - *Decided:* errors are the existing typed refusals, and `snapshot()` has no cursor until events exist in phase 5.
   - *Decided:* no verb takes a `HostCaller` yet; it arrives with the host protocol in phase 5, built by each transport adapter.
5. **Events and the host protocol.**
   - Add `HostEvent` with cursors, coalescing and resync.
     - *Decided:* events are diffs of observed state: projects, worktrees and claims, and run records through Observation, and Workspace checkouts on each `WorkspaceStore` write. The source starts with the first `snapshot()`, which publishes pending diffs before reading its cursor. The log keeps the last 1024 events, and a subscription coalesces at most 512 keys before it falls back to `resync`.
   - Add read-only session summaries to the host (`sessions.list`, `sessionChanged`, `sessionRemoved`). Session verbs and transcripts stay in phase 6.
     - *Decided:* `HostSessionSummary` is the owner, the stored `ACPSessionRow` (with the live agent-side id), the streaming state while a runner exists, and whether this instance is the writer; archived rows are not listed. Events key on owner and session id. Managers announce runner and lease changes on `summaryWillChange`, which unlike `willChange` does not re-render views.
   - Add the host message set (snapshot, events, the phase 4 verbs and the session list), served on a local Unix socket and as a versioned namespace on the Remote server.
   - The Remote layer subscribes to host events instead of polling.
     - *Decided:* each gateway subscribes to the host from now on, through `RemoteSessionsProvider.eventHost`, and rebuilds the session list on session, worktree and project events, and the worktree list on the latter two once its client has asked for worktrees. Rebuilds run at most every 500 ms. A browser page asks again when it becomes visible, because a suspended socket can miss pushes. Sessions of owners without a loaded manager stay out of the list, as before; discovering them belongs to phase 6.
   - *Exit:* the web client's and federation's 15 s list polls are gone, and a host-protocol client can list and mutate projects, worktrees and workspaces.
6. **Sessions.** `SessionsAPI` over the session managers. Session verbs, transcripts and pending requests join the host protocol. Remote's session messages become a layer over them, and `RemoteSessionsProvider` is retired. *Exit:* no Remote session path reaches `AppState` except through the presenter, and no API returns `ACPSession`.
7. **CLI, MCP and plugins.** `AlasActionService` shrinks to presentation. `ACPSessionOrchestrationCoordinator` and `PluginHostActions` call the host. Review stores move to the host. *Exit:* every domain command in the router and plugin host calls `AlasHost`.
8. **`alas-host`.** The executable target serving the host protocol, the data-directory lock and the hostless end-to-end test. *Exit:* CI boots `alas-host` and drives a worktree, a session and a run over the wire.

Phases 1–3 change no external behavior and can start right away. Phase 5 is the first one users notice: lists update live instead of every 15 seconds.

## Decisions

1. **App reads stay in-process.** The app's views keep binding to core `@Observable` stores. Only mutations must go through the host.
2. **Headless runs are process-backed.** `alas-host` runs scripts as plain processes, with output captured to run history. A terminal-backed headless launcher (for example over zmx) can be added later behind the same `RunLauncher`.
3. **`AlasHost` is the public entry point.** It is a new type. `AlasCoreContext` becomes the internal engine behind it and loses its public verbs as their callers move.
4. **Session owners are uniform.** Every session verb takes the existing `SessionOwnerID` (`.worktree` or `.workspaceCheckout`), and authorization, attention and events treat both the same way. Its `.worktree` case carries only the id today; it gains the project, like `WorktreeRef`, so it is unambiguous for same-path checkouts across hosts. Phase 6 removes the Remote paths that refuse checkout-owned sessions today, because special-cased owners are where the lifecycle bugs of #1952 came from.

5. **One host protocol, two transports (option C below).** Headless clients speak a host message set that mirrors `AlasHost`. It is served over a local Unix socket (file permissions) and over the Remote server's paired TLS channel as its own namespace. Remote's web-specific messages become a layer over host messages, and the CLI stays command-shaped over the same API in-process. This was chosen over the cheaper options for its clean shape and single streaming implementation, accepting the larger migration.

### Client protocol options considered

**A. Grow the Remote protocol into the host protocol.**
- Pros:
  - It exists and is in use: pairing, TLS, Tailscale and federation.
  - It already streams transcripts as epoch/revision deltas and carries pending permission, question and plan requests.
  - Everything added for headless clients also reaches the web client and peers.
- Cons:
  - It is shaped by one UI. Transcript snapshots are a 90-row tail, and it carries mentions and tab fields (`isActive`, `tabIndex`) and stringly session status.
  - Pairing is heavy for local, scripted clients that already have the user's file permissions.
  - Federated peers can run different Alas versions, so every message added is one kept compatible across versions. The bundled web client is versioned with the app, but peers are not.
  - A gateway per connection holds per-client state (subscriptions, change-log retention), which then grows with every host feature.

**B. A new, smaller host protocol.**
- Pros:
  - It mirrors `AlasHost` one to one, so messages could even be generated from the API.
  - It carries no UI fields, versions independently, and authenticates local clients with Unix socket permissions.
- Cons:
  - It is a third protocol next to CLI and Remote. Session streaming, pending requests and change-log retention would be implemented twice, unless shared below both.
  - The web client gains nothing unless it migrates.

**C. One host message set, two transports, with Remote layered on top.**
- How it works:
  - The host protocol is B's message set.
  - It is served over a local Unix socket (file permissions) and over the Remote server's paired TLS channel as its own namespace.
  - Remote's web-specific messages (tails, mentions, tab actions) become a thin layer over host messages.
  - The CLI stays command-shaped and calls the same API in-process.
- Pros: A's security and transport plus B's clean shape, and one implementation of streaming.
- Cons:
  - It is the largest migration.
  - The Remote layer has to keep old peers working while it moves underneath them.

**Chosen: C.** Peer compatibility is handled by version negotiation in `hello`: the host namespace carries its own protocol version, and the Remote layer keeps answering the existing messages for peers that do not speak it, until a release drops them.
