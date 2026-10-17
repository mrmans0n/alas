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
     - *Decided:* the message set is `HostClientMessage` (version, id, `HostRequest`) and `HostServerMessage` (a response matched by id, or a batch of events), in `HostProtocol.swift`. Refusals cross as typed `HostError` cases that carry the domain's own refusal enums. Values cross as they are, except where they hold host-only state: `WorktreeSnapshot` carries a `WorktreeOperation` (the kind, plus the message of a failure) instead of the retry details in `WorktreeOperationState`, and `HostSessionSummary` carries the list's fields instead of an `ACPSessionRow`. Configuration never crosses: projects are `ProjectSnapshot` (identity, path, host, kind) and Workspace checkouts are `WorkspaceCheckoutSnapshot` (the automation summary), because project and checkout configuration holds MCP server settings whose values can be credentials. Payloads are named on the wire, and a test pins the encoding.
     - *Decided:* the local transport is a socket of its own, separate from the CLI's, so the command-shaped CLI protocol and the host protocol never share a connection.
     - *Decided:* `HostSocketServer` serves it at `host.sock` in the profile's runtime directory (`/tmp/alas-<uid>/` by default), one JSON message per line. The directory is owner-only, the socket is `0600`, and a peer whose `getpeereid` user differs is refused; the caller is `.localUser(uid:)`. A host owns the path while it holds an exclusive `flock` on `host.sock.lock`, which the kernel releases if it dies, so a second instance never takes over a live host's socket. The app starts it with the harness and stops it on quit. Writes complete before the next event batch is taken, so a slow client's events coalesce in its subscription.
     - *Decided:* on the Remote server, host messages travel as `{"type":"host","host":…}` frames in both directions, and hosts advertise `host.v1` in `hello`. Every authenticated connection may use them, as `.remotePeer(deviceID:)` for the paired device it authenticated. They run outside the connection's ordered work, because responses are matched by id, and each send waits for its frame to be written.
     - *Decided:* Workspace verbs stay read-only (`workspaces.list`, `workspaces.checkout`) in this phase; mutating Workspaces over the protocol waits for their verbs to reach the host.
   - The Remote layer subscribes to host events instead of polling.
     - *Decided:* each gateway subscribes to the host from now on, through `RemoteSessionsProvider.eventHost`, and rebuilds the session list on session, worktree and project events, and the worktree list on the latter two once its client has asked for worktrees. Rebuilds run at most every 500 ms. A browser page asks again when it becomes visible, because a suspended socket can miss pushes. Sessions of owners without a loaded manager stay out of the list, as before; discovering them belongs to phase 6. Until tabs and Git status join the host, the app announces session tab and `WorktreeStatusStore` changes on `RemoteSessionsProvider.sessionListChanges`. A commit-count change with no status change, such as an empty commit or a fetch moving the comparison base, shows up with the next refresh.
     - *Decided:* federation does not poll peers. Their gateways push `sessionList` and `projectList` on change, and a client's `listSessions` asks every peer again, which is how a peer that predates pushing stays current.
   - *Exit:* the web client's and federation's 15 s list polls are gone, and a host-protocol client can list and mutate projects, worktrees and workspaces.
6. **Sessions.** `SessionsAPI` over the session managers. Session verbs, transcripts and pending requests join the host protocol. Remote's session messages become a layer over them, and `RemoteSessionsProvider` is retired. *Exit:* no Remote session path reaches `AppState` except through the presenter, and no API returns `ACPSession`.
   - *Decided:* `SessionsAPI` gains create (in a worktree or a Workspace checkout), send, stop, rename, archive, the model, mode and config option setters, and answers to permission, question, plan and form requests. Sending and the setters need this instance to be the session's writer, as the Remote layer requires. Stop, rename and answers do not: stop is the brake, rename touches only the row, and an answer is guarded by the request it answers. Verbs act on loaded sessions and refuse with `SessionRefusal`.
   - *Decided:* the rules for answering an agent's requests live in `ACPRequestAnswers`, shared by the host and the Remote gateway. A permission request is answered by the agent's own JSON-RPC id for it (`ACPPermissionPolicy.pendingPermissionRequestID`): the transcript shows every permission under one placeholder id, so it cannot tell a late reply from an answer to the next request.
   - *Decided:* a Workspace checkout's session manager comes from `AlasHostEnvironment.sessionManager(forCheckout:in:)`, which the app answers from its own checkout resolution and a headless host from `AlasCoreContext.sessionManager(forCheckout:)` (local checkouts only). `admitsAgent(_:remoteHost:)` says which agents new sessions may use.
   - *Decided:* `HostSubscription.follow(_:from:)` streams a loaded session's `transcript` deltas and its `pendingRequest` / `pendingRequestResolved` events; `unfollow` and `cancel` stop them. Following retains the transcript's change log. These events are worked out when the subscriber reads, from the change log, so a slow reader gets one delta per session instead of a backlog, and they never enter the shared event log. A delta carries its `TranscriptRevision` (the log's epoch and version); following again from it continues incrementally, and otherwise resets to the newest messages (`ACPTranscript.maxVisibleRows`). Releasing the last hold on a change log bumps its epoch, because changes nobody tracks move no version. Messages cross in the session store's encoding (`kind` and its JSON payload). Pending requests carry the ids their answering verbs take: the agent's JSON-RPC id, or the form's id for user input.
   - *Decided:* the gateway reads the agent, project, worktree and branch lists from the host's core, through `RemoteGatewayReads`, which tests replace with reads they can hold back to pin refresh ordering. `AlasHostEnvironment` supplies the app's `configuration()`, `enabledAgents()` and `modelCatalog`; a headless host gets the defaults and no remembered models.
   - *Decided:* a Remote client's session creation, and a worktree with a session in it, run in the core: `SessionsAPI.create` gains the effort, which the model catalog maps to its config option, and the worktree goes through `WorktreesAPI.create` with the destination prepared by `AlasCoreContext.preparedCreationDestination`, which the app's CLI and delegated creation share. The app opens the created session through `RemoteSessionPresenter.sessionCreated`. A worktree a client creates gets no app alert when saving the project list fails; the core logs it.
   - *Decided:* the reads of a session's worktree (change lists, diffs, file trees, commits, file contents) moved from the app into `AlasCoreContext`, which the gateway reaches through `RemoteGatewayHostCalls.inspection`. They resolve a session's worktree among the listed ones, as before.
   - *Decided:* what `@` offers (files, symbols and the project's other sessions) is found by `AlasCoreContext`, for the app's composer and for Remote clients alike. `AlasHostEnvironment` supplies the app's `fileIndex` and `agent(id:)`, and each gateway keeps the session list a search found while the client's query grows.
   - *Decided:* for the gateway to stream from follows, `SessionsAPI` gains `load` (a stored session read back, as opening it in the app does), `fullToolCallContent`, `visualAid` and `transcriptPage`, and a follow also carries `sessionState` events: whether this instance drives the session, whether it has background work to stop, and its config and queue as the Remote projections show them. They serve in-process followers: the host protocol leaves them out, because clients of the released protocol cannot decode a new event, and it can offer them once a client asks for them. A tool call whose output a loaded transcript cut short says so in `HostTranscriptMessage.truncated`, since the store's encoding cannot.
   - *Decided:* the gateway streams each subscribed session from a host subscription of its own, following it. One reader takes the follow's batches in turn and sends what they hold in the order a client expects: snapshot or delta, the requests waiting on it, then config and queue. It keeps the messages it has decoded, so the payload budget and the hiding of superseded background-task rows work as before. A resubscribe or takeover follows again, which resets; a send still waiting on a fetch for the state it replaced is dropped. Pending requests carry the agent's own ids, mapped to the integers a client answers by, and are answered through the host verbs; the follow reports them resolved.
   - *Decided:* `RemoteSessionsProvider` is gone: `RemoteServer` and each gateway take the `AlasHost`, and the session list is built by `AlasCoreContext` for every session owner, merging a session recorded twice under one agent session as before. The presenter supplies what only the app's windows know: each session's tab position, a signal when tabs or a worktree's Git status move, and the peer console host. Remote tab requests resolve the session's owner, so a checkout session's tab opens and closes like a worktree session's, without switching the tab shown on the host.
   - *Decided:* `SessionsAPI.submit` returns once a prompt is sent or queued, with a task that reports delivery when its turn ends, because a Remote connection handles one message at a time and a stop must not wait behind a turn. It refuses with `promptRejected` only before the session records the prompt, so a caller knows when the prompt's attachments are orphans. `send` waits for the turn.
   - *Decided:* the host protocol carries each session verb as a request (`createSession` … `respondToUserInput`), answered `.session` for a creation and `.done` otherwise, with refusals as `HostError.session(refusal:)`. `followSession` and `unfollowSession` act on the connection's subscription and are refused before it subscribes; a new subscription follows nothing. A prompt is answered when its turn ends, so a client answers the turn's requests on other requests meanwhile. Both transports get them through `HostProtocolConnection`. They extend version 1 additively: Remote hosts also advertise `host.sessions.v1` in `hello`, and clients send session requests only to hosts that do, because a v1 host before them cannot decode them.
   - *Plan (6b):* the Remote gateway becomes a layer over `AlasHost`, keeping `RemoteServerMessage` unchanged for the web client. One PR per step:
     1. `RemoteSessionPresenter` takes the tab requests (open and close a session's tab), which `AppState` implements and `RemoteServer` hands each gateway.
     2. `SessionsAPI` gains the session operations the gateway still reaches the app for (submitting or steering a prompt with attachments, auto-run, takeover, the queue edits, visual-aid answers and storing a prompt's images), and the gateway's verbs on existing sessions call the host. Renaming also retitles the session's tabs through the presenter.
     3. The read paths the gateway serves (agents, branches, change lists, diffs, file trees, commits, file contents, mentions) and session creation, with its effort, move behind host APIs, with `AlasHostEnvironment` supplying what only the app owns (its configuration, agent registry, model catalog and file index).
     4. Transcripts, pending requests, session config and the prompt queue stream to the gateway from host follows, and the gateway stops observing `ACPSession`. Answers to permission, question, plan and form requests move to the host verbs here, because only follows carry the agent's own request ids. Tool-call content truncation and older-page fetches stay gateway concerns over host reads.
     5. `RemoteSessionsProvider` is deleted, session summaries are built by the host with the presenter adding tab positions, the refusals of checkout-owned sessions go, and `RemoteSessionGatewayTests` run against a host built from `AlasCoreContext` with a scripted agent.
7. **CLI, MCP and plugins.** `AlasActionService` shrinks to presentation. `ACPSessionOrchestrationCoordinator` and `PluginHostActions` call the host. Review stores move to the host. *Exit:* every domain command in the router and plugin host calls `AlasHost`.
   - *Plan (7):* the router, the orchestration coordinator and the plugin host become adapters over `AlasHost`, with their UI halves on the presenter. Today only `wt list`, `workspace_list` / `workspace_show` and the claim steps of `wt new` / `wt delete` reach the host. One PR per step:
     1. **Caller origin.** The core resolves who is calling: a session id to its owner and worktree, and a working directory to the worktree that holds it, which `acpOrchestrationSessionLocation`, `sessionCwdWorktree` and `resolveWorktree(forDirectory:)` do in the app today. Terminal sessions stay app-side behind an `AlasHostEnvironment` lookup, because the terminal registry and tab trees are UI. `HostCaller` gains the calling session, so host verbs can check it.
     2. **Attention.** `HarnessService` moves under the core, and `host.attention.notify` takes an owner. CLI `notify` and the checkout-owned variant call it; the plugin `notify` toast stays on the presenter.
     3. **The coordinator moves into the host.** `AlasCoreContext` owns `ACPOrchestrationPersistence` and the one coordinator. It wires the child-turn, child-blocked and delivery hooks on every manager it builds, and runs the startup recovery that `AppState` runs now. The coordinator's environment closures (session locations, referenced sessions, managers, configuration, delegated worktree creation) become core lookups. Agent availability for delegation comes from `AlasHostEnvironment`. Parent links become host state (`HostSessionSummary` gains the parent), replacing `rememberParent` and the app's `delegatedSessionParents`.
     4. **Session commands call the host.** A `host.delegation` API carries every delegated-session command with the coordinator's semantics, the calling session taken from `HostCaller.session`: `agents` (`agent_list`), `list` (`session_list`, the caller's relatives), `create` (`session_new`: role, parent, a new or existing worktree, a caller-chosen id and a queued prompt), `send` (`session_send`, parent and child messaging with queued delivery), `read`, `search` and `wait` (direct relatives, forks and attached sessions), and `interrupt` (direct-child control). The coordinator stays their implementation, so the relationship checks it makes today hold unchanged. `SessionsAPI` gains `showVisualAid`, which appends a visual to the session's transcript for the session that drives it, and `visual_show` routes through it. Children are created through `SessionsAPI.create`, so they get the same agent, checkpoint-recovery and owner admission as every other session.
     5. **Worktree checks move with the verbs.** `worktrees.create` validates the branch and picks the default base (`WorktreeBaseBranch.preferred`) itself. `worktrees.delete` refuses workspace-owned worktrees and a recovering checkpoint itself, and asks `AlasHostEnvironment` about unsaved editor buffers. `wt new`, `wt delete` and plugin `task/start` call only the host and the presenter. The confirmation dialogs stay in the app, before the call.
     6. **Reviews.** `ReviewDraftCommentStore` and `ReviewHandoffProgress` move to the core, and `host.reviews` owns one draft store and one session store. It serves comments, add, reply, resolve, finish and opening a review target, with the author a parameter instead of the CLI's fixed one. A reply it appends, from `review_reply` or `review_resolve`, goes to the host's attention intake, which the app's `observeReviewReplyAttention` does today, so an agent's reply still raises an attention item. A host event replaces `.alasReviewDraftCommentsDidChangeExternally`, and the app's ad hoc store construction sites move onto the host's stores. Opening and focusing the review tab stays on the presenter. A GitLab review's original path comes from an `AlasHostEnvironment` hook until code-host diff loading moves.
     7. **Review status without the pane.** The host keeps each worktree's pull request and checks (`ReviewLoopState`) and refreshes them while someone follows the worktree. Following a worktree is new: `HostSubscription` gains `followWorktree` / `unfollowWorktree`, and the host protocol gains them as requests that extend version 1 additively, as session requests did: Remote hosts advertise a new `host.worktrees.follow.v1` capability in `hello`, and clients send them only to hosts that do, because an older host cannot decode them. The host counts followers per worktree, refreshing while the count is above zero and stopping when the last follower unfollows or its subscription ends. An open pane and a plugin listening for `review.changed` follow through the same count. The right pane reads the host's. The refresh is limited to followed worktrees so that the host does not poll every pull request.
     8. **Runs and plugins.** `runs.output` reads a run's output with the history flush the app does now. Every domain action in `PluginHostActions` calls the host, scoped to the plugin's project as `pluginHostActions(for:)` scopes it today: reads take the project (`snapshot(projectID:)`, `runs.list(projectID:)`, `worktrees.list(projectID:)`), and an action on a session, run or worktree id refuses one outside the project before it calls the host verb. Each adapter keeps its action's current behavior; where a plain host verb behaves differently, the host gains the verb or option that keeps it. The actions: `snapshot` (`snapshot(projectID:)`, with the presenter adding terminal agents and the selection; `WorktreeSnapshot` gains the worktree's Git status from the core's `WorktreeStatusStore`, an optional field released clients ignore, so the plugin's `dirty` counts and its status-change notifications keep working), `agents` (`sessions.agents(projectID:)`: the enabled agents that can launch where the project runs, as `enabledAgents(forProjectId:)` and `ACPLaunchCatalog` filter them today; `delegation.agents` builds on it), `lastMessage` (`sessions.lastAgentReply`: the text of the latest agent message in a loaded session, nil when it is not loaded, as the plugin reads it today), `sendToSession` (`SessionsAPI.submit`), `startTask` (`sessions.defaultAgent(projectID:)` first, resolving an omitted agent as today: the project's override, then the enabled repository default, then the global default, skipping agents that cannot launch where the project runs, and refusing before any worktree is created when none is left; then `worktrees.create` with a free-name option that reserves the next free suffixed branch and destination, serialized per project, as `createWorktreeAtFreeDestination` does today, so recurring and concurrent tasks start under the next free name; `sessions.create`, then `sessions.submit` with the task's prompt, as the prepared prompt sends it today), `runs` (`runs.list`, which the `run.started` / `run.finished` events read), `startRun` (`runs.startOrRestart`: a finished run, or a script whose run terminal is still open, restarts through `runs.restart` so no second terminal opens, as `startPluginRun` does today; otherwise `runs.start`, through the terminal-backed `RunLauncher`), `runOutput` (`runs.output`), `reviews` and `addReviewComment` (`reviews.*`), `worktreeLocation` (`worktrees.list`) and `usageHistory`. For the last, `AlasCoreContext` owns the `UsageHistoryStore` that `AppState` creates today, and `host.usage` reads it (`turns` and `limits`, the two reads plugins make); the app's usage views read the same store. `switchWorktree`, `focusSession` and `notify` stay on the presenter. `prs.create` and `prs.status` wrap the shepherd for CLI `pr_*`.
     9. **`AlasActionService` keeps only presentation:** `open`, `wt switch`, `workspace switch` / `focus`, `review` tab opening and `preview_*`, with their authorization reading the host's caller origin. `workspace focus` refreshes worktrees through the host before it focuses.
   - *Decided (7):*
     - **Plugin snapshot sessions** keep the sidebar's terminal agents: the host lists ACP sessions, and the presenter adds the terminal rows the snapshot shows today.
     - **Delegated children** are created through `SessionsAPI.create`, so they are refused where any session is (a disabled agent, checkpoint recovery, a busy owner). The coordinator skips those checks today.
     - **New host events stay in process.** The events Phase 7 adds (review comment changes, review status, parent links) serve in-process followers only, as `sessionState` does: `HostProtocolServer` leaves them out of the frames it sends, because a released `host.v1` client cannot decode a new `HostEvent` case and would lose the batch. A wire client opts in when it subscribes: a new `subscribeAccepting(after:events:)` request names the event kinds it can decode, and the host sends that subscription only those kinds besides the ones every version-1 client decodes. Hosts that serve the request advertise `host.events.v1` in `hello`, and clients send it only to hosts that do; a plain `subscribe` keeps today's events. The local socket has no `hello`, so a socket client asks first with a new `capabilities` request: a released host cannot decode it and answers `invalidRequest` under id 0, which the client takes as version 1 with no extensions, and a host that serves it answers with the capabilities Remote's `hello` lists. The capabilities Phase 7 adds (`host.worktrees.follow.v1`, `host.events.v1`) are learned the same way on both transports.
     - **Delegation and review verbs answer in the CLI's shape.** `host.delegation` and `host.reviews` return `AlasCLIResponse`, the result the coordinator and the review commands already produce, rather than new typed results; typed results can follow when a non-CLI client calls them.
     - **Reply attention reaches the app through the environment.** An agent's review reply goes to `AlasHostEnvironment.reviewReplyAdded`, because the attention item's owner and display come from the app's worktree context; it moves with the rest of attention production.
     - **Views keep their review stores.** The stores are stateless and read the same files, so `AppState`'s own reads use the core's instances and its `reviewCommentChanges` signal, while views that build a store keep doing so and keep listening for the notification the core still posts.
     - **The coordinator is split across three PRs:** the core builds it, then recovers delegations and delivers their messages, then keeps parent links (`HostSessionSummary.parentID`). Its app-only inputs (instance id, agent availability, delegated worktree creation, parent-link changes) are `AlasHostEnvironment` hooks.
     - **Review status** is refreshed only for followed worktrees. A plugin listening for `review.changed` follows the worktrees it asks about, and pays their polling.
     - **Git status is a host read, not a snapshot field.** The plugin snapshot reads `worktrees.gitStatus(of:)` beside `worktrees.list(projectID:)`, because the plugin host runs in process; `WorktreeSnapshot` gains the field when a wire client needs it.
     - **`reviews.open` resolves and saves; the presenter shows.** It turns a PR/MR number or URL, a range, a branch or a revision into a `ReviewSessionTarget`, saves its session (reusing the active one) and returns the record. The app opens the record's tab and focuses the worktree.
     - **`workspace focus` refreshes through `worktrees.refresh(projectID:)`**, the environment's project refresh that creation and deletion already use, then saves the project list when it changed.
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
