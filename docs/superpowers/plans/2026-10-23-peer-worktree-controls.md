# Peer Worktree Controls (Phase 2, PR 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Mac paired with a host lists every visible worktree of the host in the peer sidebar and can archive or delete it, with the host's typed refusals and an explicit, separately confirmed discard of unsaved host edits.

**Architecture:** The host gains a `discardUnsavedEdits` acknowledgement on `deleteWorktree`/`archiveWorktree`, typed refusals for unsaved edits and Workspace ownership, and the `host.worktrees.lifecycle.v1` capability. On the Mac, a UI-free `PeerHostChannel` (package) speaks the host protocol over `RemotePeerManager.sendToPeer` / a new `onHostMessage` hook (snapshot, subscribe, events, resync, request matching, timeout), and a UI-free `PeerWorktreeRemoval` drives the confirm → request → refusal → confirm loop. The app's `NativePeerHosts` owns one channel per capable peer; the sidebar snapshot joins the channel's worktrees with session and console rows by project id and worktree id. A selected worktree with no selected session reads its Changes and Files through one new worktree-keyed host request, `readWorktree`, whose answer is the very `RemoteServerMessage` the session path sends, so the peer right pane applies it unchanged.

**Tech Stack:** Swift 5.9+, SwiftUI/AppKit (app only), Swift Testing, SwiftPM package `Packages/AlasCore`, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-23-peer-runs-and-worktrees-design.md` (goals 1-4 only; goals 5-7, the Run tab and run requests, are PR 2 and out of scope).

## Global Constraints

- PR 1 scope, verbatim: "The host-channel client, every worktree in the peer sidebar, the worktree controls, and the typed refusals with the explicit discard." No Run tab, no `listRunScripts`, no `restartRun`.
- "No path where a peer action discards unsaved work on the host without the user explicitly confirming that consequence."
- "Delete and archive must target exactly the checkout the user saw. Send the host snapshot's `lineageID`/`branch`, and keep the server's existing lineage and on-disk checks."
- "No regression for older hosts or older Macs. New requests are gated on capabilities, and new response or error cases must not break older decoders."
- "The core package gains no UI imports." / AGENTS.md: `Packages/AlasCore` "must not import SwiftUI, AppKit, WebKit, or anything the app builds outside SwiftPM … Anything the app or tests use from the package must be `public`."
- "`force` keeps meaning only "delete despite git changes"." `deleteWorktree` and `archiveWorktree` gain a separate `discardUnsavedEdits` acknowledgement; "Without it, both refuse with the typed unsaved-edits error, whatever `force` says".
- Capability string: `host.worktrees.lifecycle.v1`. "The peer Archive and Delete controls appear only for hosts that advertise it". The host channel itself is gated on `host.v1` and `host.events.v1`; peers without them keep today's session-derived grouping.
- Spec goal 2: "Selecting an idle worktree opens it in the peer view (Changes, Files, Run, and a new session from there) as a worktree with sessions does." Changes and Files of a worktree with no selected session use `readWorktree`, gated on `host.worktrees.read.v1`; the session-keyed path stays unchanged whenever a session is selected, and for hosts without the capability. Run is PR 2.
- Keep-branch item "appears under the same rule as locally (`config.worktrees.deleteBranchOnRemove` on this Mac)". Items "hidden for the main worktree, folder projects and Workspace-owned worktrees, and disabled with an explanation for remote (SSH) projects."
- Delete reuses the local confirmation (`AppState.deleteConfirmation(branch:keepBranch:)`), the local force alert strings (`AppState.forceDeleteAlertTitleSuffix`, `AppState.forceDeleteAlertMessage`) and shows every other refusal's message.
- AGENTS.md: Swift Testing (`import Testing`), not XCTest. Extend the existing suite for the type under test before creating a file; one behavior per test; `@Test(arguments:)` for variants; never synchronize with a fixed `Task.sleep` (poll with `eventually`).
- AGENTS.md: Conventional Commits (`type(scope): summary`); no `Co-Authored-By`, no generated-by footers, no agent attribution anywhere.
- AGENTS.md: keep code, comments, logs, and UI strings in English.
- AGENTS.md: new app source or test files are only compiled once `xcodegen` regenerates `Alas.xcodeproj`; commit the regenerated project with them.
- AGENTS.md: for changes under `Packages/AlasCore`, run `swift test --package-path Packages/AlasCore` (filtered to the touched suites) first. `AlasTests` cannot run on this machine: CI is their first run and the app's first full compile, so app logic lives in plain types and app-side tests are written but verified in CI. Report exactly which local checks ran.

## Review Focus

1. A peer that drops or replaces its link while a request is out (reconnect, older host that answers nothing): the request ends with a message, never hangs, and nothing is retried on its own. Test: Task 2 `anUnansweredRequestFailsAfterItsTimeoutAndItsLateAnswerIsDropped`, `disconnectFailsPendingRequestsAndForgetsTheState`.
2. Event batches from the subscription a resync replaces arrive after the new snapshot: they must not resurrect a deleted worktree. Test: Task 2 `eventsApplyOnlyWhileSubscribedAndResyncTakesANewSnapshot`.
3. The host's worktree changed between listing and the request (lineage or branch differs): the `.changed` refusal is shown and never answered with a forced retry. Test: Task 3 `otherRefusalsEndTheFlowWithTheirMessage`.
4. The selection moves while the host is still answering, or the host deletes or archives the selected idle worktree: the selection clears instead of leaving a ghost pane, and a late file or changes answer for a worktree no longer selected is dropped. Tests: Task 5 `anIdleHostWorktreeSelectsIntoItsEmptyStateAndClearsWhenTheHostDropsIt`, Task 6 `aSelectedIdleWorktreeReadsItsFilesOverTheHostChannel`.
5. Mixed versions: a host with `host.v1`/`host.events.v1` but no lifecycle capability lists its worktrees with no controls; a host without the host channel gets no host messages at all and keeps session grouping. Tests: Task 4 `onlyPeersServingTheHostChannelAreAskedForASnapshot`, Task 7 `peerWorktreeControlsNeedTheLifecycleCapability`.

---

### Task 1: Host — explicit discard, typed refusals, lifecycle capability

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocol.swift:57-61` (request cases)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocolServer.swift:195-224,360-373`
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost.swift:257-305` (`WorktreesAPI.delete`, `.archive`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost+WorktreeChecks.swift:119-128` (`deletionCheck`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext+WorktreeRemoval.swift:193-282,340-435`
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteProtocol.swift:1443-1462` (`HostProtocolCapability`)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/HostProtocolTests.swift`, `Packages/AlasCore/Tests/AlasCoreTests/HostProtocolServerTests.swift`, `Packages/AlasCore/Tests/AlasCoreTests/AlasHostTests.swift`, `AlasTests/AppStateWorktreeArchiveBatchTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `HostRequest.deleteWorktree(worktree: WorktreeRef, lineageID: String?, branch: String, force: Bool, deleteBranchIfMerged: Bool, discardUnsavedEdits: Bool? = nil)`
  - `HostRequest.archiveWorktree(worktree: WorktreeRef, lineageID: String?, branch: String, discardUnsavedEdits: Bool? = nil)` — `nil` is an older client: refused like `false`, refusal sent untyped.
  - `WorktreeDeletionRefusal.unsavedEdits`, `WorktreeDeletionRefusal.ownedByWorkspaceCheckout(String)` (wire key `reason`), `WorktreeArchiveRefusal.unsavedEdits`
  - `HostProtocolCapability.worktreesLifecycleV1 = "host.worktrees.lifecycle.v1"` (appended to `served`)
  - `WorktreesAPI.delete(_ worktree: Worktree, force: Bool = false, deleteBranchIfMerged: Bool = false, discardUnsavedEdits: Bool = false, caller: HostCaller) async throws`
  - `WorktreesAPI.archive(_ worktree: Worktree, verifiesCheckout: Bool = false, discardUnsavedEdits: Bool = false, caller: HostCaller) async throws`

- [ ] **Step 1: Write the failing protocol tests** in `HostProtocolTests`

Extend `clientMessagesRoundTrip`'s arguments with
`HostClientMessage(id: 18, request: .deleteWorktree(worktree: ref, lineageID: "l", branch: "feature", force: false, deleteBranchIfMerged: true, discardUnsavedEdits: true))` and
`HostClientMessage(id: 19, request: .archiveWorktree(worktree: ref, lineageID: "l", branch: "feature", discardUnsavedEdits: false))`;
extend `serverMessagesRoundTrip` with `.response(id: 11, result: .failure(error: .worktreeArchive(refusal: .unsavedEdits)))` and `.response(id: 12, result: .failure(error: .worktreeDeletion(refusal: .ownedByWorkspaceCheckout("Owned."))))`. Add to `encodingIsPinned` (the existing archive pin stays unchanged: it pins that `nil` is omitted):

```swift
#expect(try json(HostClientMessage(id: 1, request: .deleteWorktree(
    worktree: Self.ref, lineageID: "l", branch: "feature", force: false, deleteBranchIfMerged: false, discardUnsavedEdits: true
))) == #"{"id":1,"request":{"deleteWorktree":{"branch":"feature","deleteBranchIfMerged":false,"discardUnsavedEdits":true,"force":false,"lineageID":"l","worktree":{"path":"\/srv\/feature","projectID":"p"}}},"version":1}"#)
#expect(try json(HostServerMessage.response(id: 3, result: .failure(error: .worktreeDeletion(refusal: .unsavedEdits)))) ==
    #"{"response":{"id":3,"result":{"failure":{"error":{"worktreeDeletion":{"refusal":{"unsavedEdits":{}}}}}}}}"#)
```

New test:

```swift
/// A client before `host.worktrees.lifecycle.v1` sends no acknowledgement.
@Test func anOlderClientsDeleteDecodesWithoutADiscardAcknowledgement() throws {
    let old = #"{"id":1,"request":{"deleteWorktree":{"branch":"feature","deleteBranchIfMerged":false,"force":true,"lineageID":"l","worktree":{"path":"\/srv\/feature","projectID":"p"}}},"version":1}"#
    #expect(try JSONDecoder().decode(HostClientMessage.self, from: Data(old.utf8)).request == .deleteWorktree(
        worktree: Self.ref, lineageID: "l", branch: "feature", force: true, deleteBranchIfMerged: false, discardUnsavedEdits: nil
    ))
}
```

- [ ] **Step 2: Write the failing server and API tests**

In `HostProtocolServerTests`:

```swift
/// The refusals `host.worktrees.lifecycle.v1` added reach only a client that
/// sent `discardUnsavedEdits`; an older one gets the message it can decode.
@Test(arguments: [false, true])
func newLifecycleRefusalsAreTypedOnlyForClientsThatAcknowledgeDiscards(typed: Bool) {
    let refusals: [any Error] = [
        WorktreeDeletionRefusal.unsavedEdits, WorktreeDeletionRefusal.ownedByWorkspaceCheckout("Owned."), WorktreeArchiveRefusal.unsavedEdits,
    ]
    let mapped = refusals.map { HostProtocolConnection.hostError(HostProtocolConnection.lifecycleRefusal($0, typed: typed)) }
    #expect(mapped == (typed
        ? [.worktreeDeletion(refusal: .unsavedEdits), .worktreeDeletion(refusal: .ownedByWorkspaceCheckout("Owned.")), .worktreeArchive(refusal: .unsavedEdits)]
        : refusals.map { .failed(message: $0.localizedDescription) }))
    #expect(HostProtocolConnection.hostError(HostProtocolConnection.lifecycleRefusal(WorktreeDeletionRefusal.needsForce("dirty"), typed: typed))
        == .worktreeDeletion(refusal: .needsForce("dirty")))
}
```

In `AlasHostTests.worktreeVerbsRefuseWhatTheirChecksRefuse`, add `VerbCheck` cases `forceDeleteWithUnsavedEdits` and `archiveWithUnsavedEdits`, and replace the shared `refusal: WorktreeCheckRefusal` with one `#expect(throws:)` per case:
- `.deleteWorkspaceOwned` (`environment.workspaceRefusal = "A Workspace checkout manages this worktree."`): `host.worktrees.delete(worktree, caller:)` throws `WorktreeDeletionRefusal.ownedByWorkspaceCheckout("A Workspace checkout manages this worktree.")`.
- `.deleteWithUnsavedEdits` / `.forceDeleteWithUnsavedEdits` (`environment.unsavedEdits = true`): `delete(worktree, force: false|true, caller:)` throws `WorktreeDeletionRefusal.unsavedEdits` — force does not bypass it.
- `.archiveWithUnsavedEdits`: `host.worktrees.archive(worktree, caller:)` throws `WorktreeArchiveRefusal.unsavedEdits`, and additionally `#expect(!projects.isWorktreeHidden(projectId: "p", path: worktree.path))`.
- The shared tail (`projects.worktrees(projectId: "p") == [worktree]`, `operationState == nil`) stays.

In `AlasTests/AppStateWorktreeArchiveBatchTests` (the app host's editors, CI only):
- Parameterize `hostDeleteRefusesEditsMadeWhileItRuns` into `@Test(arguments: [false, true]) func hostVerbsRefuseEditsMadeWhileTheyRun(archive: Bool)`: for `archive` call `fixture.state.host.worktrees.archive(target, caller: .localUser(uid: 501))`; expect a throw, the editor tab still open, and for archive `!fixture.state.projectsManager.isWorktreeHidden(projectId: fixture.project.id, path: target.path)`.
- New `@Test(arguments: [false, true]) func hostArchiveRefusesUnsavedEditsUnlessDiscarded(discard: Bool)`: open an editor on `a.txt` in `fixture.worktrees[1]`, `awaitLoadForTesting()`, edit `buffer.storage` (dirty before the call), then call `host.worktrees.archive(target, discardUnsavedEdits: discard, caller: .remotePeer(deviceID: "d"))`. `discard == false`: throws `WorktreeArchiveRefusal.unsavedEdits`, tab still open, worktree not hidden. `discard == true`: no throw, worktree hidden, tab closed.

- [ ] **Step 3: Run the package tests to verify they fail**

Run: `swift test --package-path Packages/AlasCore --filter 'HostProtocolTests|HostProtocolServerTests|AlasHostTests'`
Expected: build FAILS ("extra argument 'discardUnsavedEdits'", "type 'WorktreeDeletionRefusal' has no member 'unsavedEdits'").

- [ ] **Step 4: Implement**

- `HostProtocol.swift`: add the trailing `discardUnsavedEdits: Bool? = nil` to both cases (synthesized `Codable` uses `encodeIfPresent`/`decodeIfPresent` for it). Doc comment: "Whether the user agreed to discard unsaved editor changes on the host (`host.worktrees.lifecycle.v1`). Nil from an older client, refused like false with an untyped message."
- `AlasCoreContext+WorktreeRemoval.swift`: the three new refusal cases; `errorDescription` for both `unsavedEdits` is `"An editor on the host has unsaved changes in this worktree."`, `ownedByWorkspaceCheckout(let reason)` is `reason`. `deleteWorktree(_:force:deleteBranchIfMerged:discardUnsavedEdits: Bool = false)` sets `options.refusesUnsavedEdits = !discardUnsavedEdits` (no longer `!force`). `archiveWorktree(_:verifiesCheckout:refusesUnsavedEdits: Bool = false)`, `archiveWorktree(_:claim:verifiesCheckout:refusesUnsavedEdits: Bool = false)` and `performArchive(_:refusesUnsavedEdits: Bool = false, revalidate:)` thread it to `environment.quiesceWorktree(worktree, refusingUnsavedEdits: refusesUnsavedEdits, in: self)`. The app's own archive callers keep the default.
- `AlasHost+WorktreeChecks.swift`: `func deletionCheck(_ worktree: Worktree, discardUnsavedEdits: Bool) throws` throws `WorktreeDeletionRefusal.ownedByWorkspaceCheckout(refusal)` for `environment.workspaceDeletionRefusal(for:)`, then `WorktreeDeletionRefusal.unsavedEdits` unless `discardUnsavedEdits` when `environment.hasUnsavedEditorChanges(in:)`. `beginDelete(_:force:caller:)` (the CLI path) is unchanged.
- `AlasHost.swift`: `WorktreesAPI.delete` calls `deletionCheck(worktree, discardUnsavedEdits:)` then `core.deleteWorktree(..., discardUnsavedEdits:)`. `WorktreesAPI.archive` throws `WorktreeArchiveRefusal.unsavedEdits` first when `!discardUnsavedEdits && core.environment.hasUnsavedEditorChanges(in: worktree)`, then `core.archiveWorktree(worktree, verifiesCheckout:, refusesUnsavedEdits: !discardUnsavedEdits)`. The app host's `AppHostEnvironment.hasUnsavedEditorChanges` (`AppState.swift:14668`, dirty editor tabs) and the headless default (`false`) already answer it.
- `HostProtocolServer.swift`: bind the sixth/fourth value in the `.deleteWorktree`/`.archiveWorktree` cases, pass `discardUnsavedEdits ?? false`, and wrap only the `host.worktrees.delete`/`.archive` call in `do { … } catch { throw Self.lifecycleRefusal(error, typed: discardUnsavedEdits != nil) }`. Add `static func lifecycleRefusal(_ error: any Error, typed: Bool) -> any Error`: returns `HostError.failed(message: error.localizedDescription)` for the three new cases when `!typed`, otherwise `error` unchanged.
- `RemoteProtocol.swift`: `public static let worktreesLifecycleV1 = "host.worktrees.lifecycle.v1"` with a doc line ("Hosts whose `deleteWorktree` and `archiveWorktree` take `discardUnsavedEdits` and answer typed unsaved-edits and Workspace refusals"); append it to `served`.

- [ ] **Step 5: Run the package tests to verify they pass**

Run: `swift test --package-path Packages/AlasCore --filter 'HostProtocolTests|HostProtocolServerTests|AlasHostTests|HostSocketServerTests|HostSessionsTests'`
Expected: PASS (HostSocketServerTests' archive/delete round trip and HostSessionsTests' `served` check still pass). The `AppStateWorktreeArchiveBatchTests` changes run in CI.

- [ ] **Step 6: Commit**

```bash
git add Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocol.swift Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocolServer.swift Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost.swift Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost+WorktreeChecks.swift Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext+WorktreeRemoval.swift Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteProtocol.swift Packages/AlasCore/Tests/AlasCoreTests/HostProtocolTests.swift Packages/AlasCore/Tests/AlasCoreTests/HostProtocolServerTests.swift Packages/AlasCore/Tests/AlasCoreTests/AlasHostTests.swift AlasTests/AppStateWorktreeArchiveBatchTests.swift
git commit -m "feat(host): require an explicit discard of unsaved edits to delete or archive"
```

---

### Task 2: `PeerHostChannel` — the host protocol client for one peer

**Files:**
- Create: `Packages/AlasCore/Sources/AlasHostCore/Remote/Peer/PeerHostChannel.swift`
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost.swift:117-158` (public memberwise inits)
- Test: Create `Packages/AlasCore/Tests/AlasCoreTests/PeerHostChannelTests.swift` (new type, no suite yet)

**Interfaces:**
- Consumes: `HostClientMessage`, `HostServerMessage`, `HostEvent`, `HostSnapshot`, `FederatedSessionsProvider.peerUnavailableMessage`.
- Produces:

```swift
@MainActor public final class PeerHostChannel {
    public static let defaultTimeout: Duration = .seconds(60)
    public static let unansweredMessage = "The peer did not answer."
    public struct State: Equatable, Sendable {
        public var projects: [ProjectSnapshot]
        public var worktrees: [WorktreeSnapshot]          // archived included
        public var workspaceCheckouts: [WorkspaceCheckoutSnapshot]
        public var runs: [RunRecord]
        public init(_ snapshot: HostSnapshot)
        /// Upserts or removes by key; session, transcript and request events are ignored.
        public mutating func apply(_ event: HostEvent)
    }
    public private(set) var state: State?
    public private(set) var isSubscribed: Bool
    public private(set) var isConnecting: Bool
    public var onChange: (@MainActor () -> Void)?
    public init(timeout: Duration = defaultTimeout, send: @escaping @MainActor (HostClientMessage) -> Void)
    public func connect() async
    public func request(_ request: HostRequest) async -> HostResponse
    public func receive(_ message: HostServerMessage)
    public func disconnect()
}
```
  plus `public init(cursor:projects:worktrees:workspaceCheckouts:runs:sessions:)` on `HostSnapshot` and `public init(worktree:operation:isArchived:)` on `WorktreeSnapshot` (app tests build them).

- [ ] **Step 1: Write the failing tests** (`PeerHostChannelTests`, `@MainActor struct`, a `Sent` recorder class with `messages: [HostClientMessage]`, a `connected(…)` helper that answers the snapshot and the subscribe). An answer resumes `connect()` on a later main-actor turn, so wait for each next send or state change with `eventually { @MainActor in … }` from `TestSupport/Eventually.swift` before asserting on it.

```swift
@Test func connectTakesASnapshotThenSubscribesAfterItsCursor() async throws {
    // connect → first send is .snapshot; answering it publishes `state` and sends
    // .subscribe(after: snapshot.cursor); isSubscribed only after .subscribed.
    #expect(sent.messages[0].request == .snapshot)
    #expect(channel.state?.worktrees == [feature])
    #expect(sent.messages[1].request == .subscribe(after: cursor))
    #expect(!channel.isSubscribed)        // before .subscribed
    #expect(channel.isSubscribed)         // after .subscribed and `await connecting.value`
}

@Test func eventsApplyOnlyWhileSubscribedAndResyncTakesANewSnapshot() async throws {
    // subscribed: .worktreeChanged(feature archived) → state.worktrees[0].isArchived == true;
    // .worktreeRemoved(projectID: "p", worktreeID: feature.id) → state.worktrees.isEmpty.
    // .events([.resync]) → a new .snapshot request is sent; a stale
    // .worktreeChanged(feature, operation: .deleting) delivered before the new
    // snapshot answer and another before its .subscribed are both ignored:
    #expect(channel.state?.worktrees == [])   // after the new snapshot (without feature) and .subscribed
}

@Test func answersAreMatchedToTheirRequestsById() async throws {
    // request(.listSessions) and request(.capabilities) in flight; answer id 2 then id 1.
    #expect(await sessions == .sessions(sessions: []))
    #expect(await capabilities == .capabilities(capabilities: ["host.v1"]))
}

@Test func anUnansweredRequestFailsAfterItsTimeoutAndItsLateAnswerIsDropped() async throws {
    let channel = PeerHostChannel(timeout: .milliseconds(20), send: sent.append)
    #expect(await channel.request(.snapshot) == .failure(error: .failed(message: PeerHostChannel.unansweredMessage)))
    channel.receive(.response(id: 1, result: .done))            // late: dropped
    // the next request (id 2) resolves only with its own answer
    #expect(await next == .capabilities(capabilities: []))
}

@Test func disconnectFailsPendingRequestsAndForgetsTheState() async throws {
    // connected, one request pending, then disconnect():
    #expect(await pending == .failure(error: .failed(message: FederatedSessionsProvider.peerUnavailableMessage)))
    #expect(channel.state == nil)
    #expect(!channel.isSubscribed)
    // a later .events batch changes nothing (state stays nil)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path Packages/AlasCore --filter PeerHostChannelTests`
Expected: FAIL to build ("cannot find 'PeerHostChannel' in scope").

- [ ] **Step 3: Implement `PeerHostChannel` in `PeerHostChannel.swift`**

Ids count up from 1; each request stores a `CheckedContinuation` before calling `send`, plus a timeout `Task` cancelled on answer that resolves it with `unansweredMessage`. `receive(.response)` resumes and removes the matching id (unknown ids are ignored). `disconnect()` resumes every pending request with `FederatedSessionsProvider.peerUnavailableMessage`, sets `state = nil`, `isSubscribed = false`, bumps an epoch, calls `onChange`. `State.apply` upserts by `id` (projects, checkouts, runs) and by `(worktree.projectId, worktree.id)` (worktrees, appended when new); `projectRemoved` also drops that project's worktrees. The ordering rule the tests pin:

```swift
public func connect() async {
    guard !isConnecting else { return }
    isConnecting = true; defer { isConnecting = false }
    isSubscribed = false                       // drop batches of the subscription being replaced
    let epoch = self.epoch
    guard case .snapshot(let snapshot) = await request(.snapshot), epoch == self.epoch else { return }
    state = State(snapshot); onChange?()
    guard case .subscribed = await request(.subscribe(after: snapshot.cursor)), epoch == self.epoch else { return }
    isSubscribed = true                        // the host sends .subscribed before any of its events
}
// receive(.events(events, _)): guard isSubscribed, var state else { return }
// if events.contains(.resync) { Task { await connect() }; return }
// apply all, publish once and call onChange if state changed.
```

Add the two public memberwise inits in `AlasHost.swift`.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --package-path Packages/AlasCore --filter PeerHostChannelTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AlasCore/Sources/AlasHostCore/Remote/Peer/PeerHostChannel.swift Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost.swift Packages/AlasCore/Tests/AlasCoreTests/PeerHostChannelTests.swift
git commit -m "feat(remote): add a host protocol client for a paired peer"
```

---

### Task 3: Peer worktree join, control rules and the removal flow

**Files:**
- Create: `Packages/AlasCore/Sources/AlasHostCore/Remote/Peer/PeerWorktreeLifecycle.swift`
- Test: Create `Packages/AlasCore/Tests/AlasCoreTests/PeerWorktreeLifecycleTests.swift` (new types)

**Interfaces:**
- Consumes: `PeerHostChannel.State` (Task 2); `WorktreeDeletionRefusal.unsavedEdits`, `.ownedByWorkspaceCheckout`, `WorktreeArchiveRefusal.unsavedEdits`, `HostRequest.deleteWorktree/archiveWorktree(…discardUnsavedEdits:)` (Task 1).
- Produces:

```swift
public struct PeerHostWorktree: Equatable, Sendable {
    public var snapshot: WorktreeSnapshot
    public var project: ProjectSnapshot
    /// `worktree.isMainWorktree`, else its standardized path equals the project's.
    public var isMain: Bool
    /// The active Workspace checkout managing it (workspaceID set, not archived,
    /// a member with this project id and standardized worktree path).
    public var workspaceCheckoutName: String?
    public init(snapshot: WorktreeSnapshot, project: ProjectSnapshot, isMain: Bool, workspaceCheckoutName: String?)
    public func controls(lifecycleSupported: Bool) -> PeerWorktreeControls
}
extension PeerHostChannel.State {
    /// Non-archived worktrees of listed projects, in snapshot order.
    public func visibleWorktrees() -> [PeerHostWorktree]
}
public enum PeerWorktreeControls: Equatable, Sendable {
    case hidden
    case disabled(reason: String)
    case available
    public static let remoteProjectReason = "Worktrees of remote projects can only be archived or deleted on the host Mac."
}
public enum PeerWorktreeRemoval {
    public enum Action: Equatable, Sendable { case archive; case delete(keepBranch: Bool, deleteBranchIfMerged: Bool) }
    public enum Confirmation: Equatable, Sendable {
        case delete(branch: String, keepBranch: Bool)
        case force(branch: String)
        case discardUnsavedEdits(branch: String, archiving: Bool)
    }
    public enum Outcome: Equatable, Sendable { case done, cancelled, refused(message: String) }
    @MainActor public static func run(
        _ action: Action, on worktree: WorktreeSnapshot,
        request: @MainActor (HostRequest) async -> HostResponse,
        confirm: @MainActor (Confirmation) async -> Bool
    ) async -> Outcome
    public static func message(for error: HostError) -> String
}
```

- [ ] **Step 1: Write the failing tests** (a private `Sendable` `Case` enum — `plain`, `main`, `folder`, `workspaceMember`, `remoteProject` (`project.host = "build"`), `operation(WorktreeOperation)` — builds the `PeerHostWorktree` for the controls table; the flow tests feed `run` a scripted `[HostResponse]` and record `requests` and `confirmations`)

```swift
@Test func visibleWorktreesJoinProjectsHideArchivedAndMarkMainAndWorkspaceMembers() {
    // project p at /srv/repo; worktrees: main (/srv/repo, isMainWorktree nil), feature, archived (isArchived),
    // member (/srv/member, in an active checkout "Checkout"), orphan (projectId "gone").
    #expect(state.visibleWorktrees().map(\.snapshot.worktree.branch) == ["main", "feature", "member"])
    #expect(state.visibleWorktrees().map(\.isMain) == [true, false, false])
    #expect(state.visibleWorktrees().map(\.workspaceCheckoutName) == [nil, nil, "Checkout"])
}

@Test(arguments: [
    (Case.plain, true, PeerWorktreeControls.available),
    (.plain, false, .hidden),                        // host without host.worktrees.lifecycle.v1
    (.main, true, .hidden), (.folder, true, .hidden), (.workspaceMember, true, .hidden),
    (.operation(.deleting), true, .hidden), (.operation(.createFailed(message: "x")), true, .hidden),
    (.operation(.deleteFailed(message: "x")), true, .available),
    (.remoteProject, true, .disabled(reason: PeerWorktreeControls.remoteProjectReason)),
])
func controlsFollowTheLocalRules(_ worktree: Case, lifecycleSupported: Bool, expected: PeerWorktreeControls)

@Test func deleteConfirmsThenRetriesWithForceOnlyAfterTheUserAgrees() async {
    // responses: [.failure(.worktreeDeletion(.needsForce("dirty"))), .done]; confirm returns true
    #expect(outcome == .done)
    #expect(confirmations == [.delete(branch: "feature", keepBranch: true), .force(branch: "feature")])
    #expect(requests == [
        .deleteWorktree(worktree: ref, lineageID: "l", branch: "feature", force: false, deleteBranchIfMerged: false, discardUnsavedEdits: false),
        .deleteWorktree(worktree: ref, lineageID: "l", branch: "feature", force: true, deleteBranchIfMerged: false, discardUnsavedEdits: false),
    ])
}

@Test(arguments: [false, true])
func unsavedEditsAreAskedSeparatelyAndNeverImpliedByForce(archiving: Bool) async {
    // delete: [unsavedEdits, needsForce, .done]  → (force, discard) sent: (false,false), (false,true), (true,true);
    //         confirmations: .delete, .discardUnsavedEdits(branch: "feature", archiving: false), .force
    // archive: [.worktreeArchive(.unsavedEdits), .done] → discard sent: false, true;
    //         confirmations: [.discardUnsavedEdits(branch: "feature", archiving: true)]
}

@Test(arguments: [0, 1])
func aDeclinedConfirmationSendsNothingMore(declinedAt: Int) async {
    // delete with responses [needsForce, .done]; confirm returns false at index `declinedAt`
    #expect(outcome == .cancelled)
    #expect(requests.count == declinedAt)      // 0: nothing sent; 1: only the first, unforced request
}

@Test(arguments: [
    (HostResponse.failure(error: .worktreeDeletion(refusal: .changed("The worktree changed since it was listed."))), "The worktree changed since it was listed."),
    (.failure(error: .worktreeDeletion(refusal: .ownedByWorkspaceCheckout("Owned by “W”."))), "Owned by “W”."),
    (.failure(error: .failed(message: PeerHostChannel.unansweredMessage)), PeerHostChannel.unansweredMessage),
])
func otherRefusalsEndTheFlowWithTheirMessage(_ response: HostResponse, _ message: String) async {
    #expect(outcome == .refused(message: message))
    #expect(requests.count == 1)
    #expect(confirmations == [.delete(branch: "feature", keepBranch: false)])   // no force prompt
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path Packages/AlasCore --filter PeerWorktreeLifecycleTests`
Expected: FAIL to build ("cannot find 'PeerHostWorktree' in scope").

- [ ] **Step 3: Implement `PeerWorktreeLifecycle.swift`**

`controls(lifecycleSupported:)` order: `!lifecycleSupported` → hidden; `isMain`, `project.kind == .folder`, `workspaceCheckoutName != nil`, or `snapshot.operation` in `{creating, preparingDelete, deleting, archiving, createFailed}` → hidden; `project.host != nil` → `.disabled(reason: remoteProjectReason)`; else available. Requests always use `WorktreeRef(projectID: worktree.projectId, path: worktree.path.path)`, the snapshot's `lineageID` and `branch`, and a non-nil `discardUnsavedEdits`. The loop:

```swift
if case .delete(let keepBranch, _) = action,
   !(await confirm(.delete(branch: branch, keepBranch: keepBranch))) { return .cancelled }
var force = false, discard = false
while true {
    switch await request(makeRequest(action, worktree, force: force, discard: discard)) {
    case .done: return .done
    case .failure(.worktreeDeletion(.needsForce)) where !force:
        guard await confirm(.force(branch: branch)) else { return .cancelled }
        force = true
    case .failure(.worktreeDeletion(.unsavedEdits)) where !discard,
         .failure(.worktreeArchive(.unsavedEdits)) where !discard:
        guard await confirm(.discardUnsavedEdits(branch: branch, archiving: action == .archive)) else { return .cancelled }
        discard = true
    case .failure(let error): return .refused(message: message(for: error))
    default: return .refused(message: "The host sent an unexpected reply.")
    }
}
```

`message(for:)`: `.worktreeDeletion(r)`/`.worktreeArchive(r)` → `r.localizedDescription`; `.failed(m)` → `m`; `.operationInProgress` → `"Wait for the current worktree operation to finish."`; `.notFound` → `"The host no longer lists this worktree."`; anything else → `String(describing: error)`.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --package-path Packages/AlasCore --filter 'PeerWorktreeLifecycleTests|PeerHostChannelTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AlasCore/Sources/AlasHostCore/Remote/Peer/PeerWorktreeLifecycle.swift Packages/AlasCore/Tests/AlasCoreTests/PeerWorktreeLifecycleTests.swift
git commit -m "feat(remote): decide peer worktree controls and drive archive and delete"
```

---

### Task 4: Wire the host channel into the Mac — `onHostMessage` and `NativePeerHosts`

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Peer/RemotePeerManager.swift:86-89,1147-1160`
- Create: `Alas/Sources/Remote/Native/NativePeerHosts.swift`
- Create: `Alas/Sources/App/AppState+PeerHosts.swift`
- Modify: `Alas/Sources/Remote/Native/NativePeerSessions.swift:12-27,346-358,359-363,415-419` (init, start/stop, refresh)
- Modify: `Alas/Sources/App/AppState.swift:1045-1050` (pass `hosts:`)
- Modify: `Alas.xcodeproj/project.pbxproj` (regenerated)
- Test: `AlasTests/Remote/RemotePeerManagerTests.swift`, `AlasTests/Remote/NativePeerSessionsTests.swift`

**Interfaces:**
- Consumes: `PeerHostChannel` (Task 2), `PeerHostChannel.State.visibleWorktrees()`, `PeerHostWorktree` (Task 3), `HostProtocolCapability.v1`, `.eventsV1`.
- Produces:
  - `RemotePeerManager.onHostMessage: (@MainActor (_ serverId: String, HostServerMessage) -> Void)?` — `.host` messages from a carrying link go here and never to federation.
  - App, `@MainActor final class NativePeerHosts`:
    - `init(send: @escaping @MainActor (_ serverId: String, HostClientMessage) -> Void, supports: @escaping @MainActor (_ serverId: String, _ capability: String) -> Bool, confirm: @escaping @MainActor (PeerWorktreeRemoval.Confirmation, _ peerName: String) async -> Bool = { _, _ in false }, showError: @escaping @MainActor (_ title: String, _ message: String) -> Void = { _, _ in }, timeout: Duration = PeerHostChannel.defaultTimeout)`
    - `private(set) var worktrees: [String: [PeerHostWorktree]]` — by `serverId`; a key exists only for a peer whose channel holds a snapshot.
    - `var onChange: (@MainActor () -> Void)?`
    - `func peersChanged(online: Set<String>)`, `func receive(serverId: String, _ message: HostServerMessage)`, `func stop()`
  - `NativePeerSessions.init(…, consoles: NativePeerConsoles? = nil, hosts: NativePeerHosts? = nil)`, `let hosts: NativePeerHosts?`
  - `AppState.makeNativePeerHosts() -> NativePeerHosts`

- [ ] **Step 1: Write the failing tests**

In `RemotePeerManagerTests`, extend `consoleEventsBypassFederationAndNeedACarryingLink` and rename it `consoleAndHostMessagesBypassFederationAndNeedACarryingLink`: set `manager.onHostMessage = { hosts.append(($0, $1)) }`, emit `.message(.host(.response(id: 1, result: .done)))` offline, online, and on the unverified link, then:

```swift
#expect(hosts.map(\.0) == ["srv-a"])
#expect(hosts.map(\.1) == [.response(id: 1, result: .done)])
#expect(!federated.contains { if case .message = $0 { true } else { false } })
```

In `NativePeerSessionsTests`:

```swift
@Test func onlyPeersServingTheHostChannelAreAskedForASnapshot() async throws {
    // links online: "B" (supports host.v1 + host.events.v1), "C" (supports neither)
    let hosts = NativePeerHosts(send: { sent.append(($0, $1)) }, supports: { serverId, _ in serverId == "B" })
    let client = NativePeerSessions(federation: …, peers: { [B, C online] }, hosts: hosts)
    client.start()
    try await eventually("snapshot request") { sent.count == 1 }
    #expect(sent.map(\.0) == ["B"])
    #expect(sent[0].1.request == .snapshot)
    hosts.receive(serverId: "B", .response(id: sent[0].1.id, result: .snapshot(snapshot: snapshot(idle))))
    try await eventually("host worktrees") { hosts.worktrees["B"] != nil }   // connect() resumes on a later turn
    #expect(hosts.worktrees["B"]?.map(\.snapshot.worktree.branch) == ["idle"])
    #expect(hosts.worktrees["C"] == nil)
    links.offline("B")                         // drives refresh → peersChanged
    #expect(hosts.worktrees["B"] == nil)
}
```

(`eventually(_:within:_:)` is the shared helper in `AlasTests/Code/LSP/LSPClientTests.swift:70`.)

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path Packages/AlasCore --filter PeerHostChannelTests` (still green: the package compiles before the hook exists). The new AlasTests fail to compile until Step 3; they run in CI:
`xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/RemotePeerManagerTests -only-testing AlasTests/NativePeerSessionsTests test`
Expected (CI, before Step 3): build FAILS ("value of type 'RemotePeerManager' has no member 'onHostMessage'").

- [ ] **Step 3: Implement**

- `RemotePeerManager.handle(.message)`: after the console branch, `if case .host(let message) = message { onHostMessage?(peer.serverId, message); return }`. Doc comment mirrors `onConsoleEvent`.
- `NativePeerHosts.swift`: `peersChanged(online:)` disconnects and drops channels (and `worktrees` keys) of peers that left; for every online peer where `supports(serverId, HostProtocolCapability.v1) && supports(serverId, HostProtocolCapability.eventsV1)`, creates a `PeerHostChannel(timeout:send:)` if missing (its `send` wraps `send(serverId, $0)`, its `onChange` recomputes `worktrees[serverId] = channel.state?.visibleWorktrees()` and calls `onChange`) and starts `Task { await channel.connect() }` when `!channel.isSubscribed && !channel.isConnecting` — so a failed snapshot retries on the next refresh, and a peer that drops and returns gets a fresh snapshot. `receive` forwards to the peer's channel. `stop()` disconnects all and clears.
- `NativePeerSessions`: store `hosts`, set `hosts?.onChange = { [weak self] in self?.rebuildSnapshot() }` in `init`; in `refresh()` call `hosts?.peersChanged(online:)` with the same set passed to `consoles?.peersChanged`; `stop()` calls `hosts?.stop()`.
- `AppState+PeerHosts.swift`: `func makeNativePeerHosts() -> NativePeerHosts` mirroring `makeNativePeerConsoles()` (`AppState+PeerConsoles.swift:93-117`): `send` → `remotePeers.sendToPeer(.host(message), serverId:)`, `supports` → `remotePeers.capabilities[serverId]?.contains(capability) == true`, then `remotePeers.onHostMessage = { [weak hosts] in hosts?.receive(serverId: $0, $1) }`. `confirm`/`showError` are wired in Task 7.
- `AppState.swift:1049`: `NativePeerSessions(…, consoles: makeNativePeerConsoles(), hosts: makeNativePeerHosts())`.
- Run `xcodegen` from the repo root.

- [ ] **Step 4: Verify**

Run: `swift test --package-path Packages/AlasCore --filter 'PeerHostChannelTests|PeerWorktreeLifecycleTests'`
Expected: PASS. In CI the two AlasTests suites above PASS (check the `Test run with N tests in M suites` line names both).

- [ ] **Step 5: Commit**

```bash
git add Packages/AlasCore/Sources/AlasHostCore/Remote/Peer/RemotePeerManager.swift Alas/Sources/Remote/Native/NativePeerHosts.swift Alas/Sources/App/AppState+PeerHosts.swift Alas/Sources/Remote/Native/NativePeerSessions.swift Alas/Sources/App/AppState.swift Alas.xcodeproj/project.pbxproj AlasTests/Remote/RemotePeerManagerTests.swift AlasTests/Remote/NativePeerSessionsTests.swift
git commit -m "feat(remote): follow paired hosts' worktrees over the host channel"
```

---

### Task 5: Every host worktree in the peer sidebar

**Files:**
- Modify: `Alas/Sources/Remote/Native/NativePeerSidebarSnapshot.swift:55-166,193-314,316-363`
- Modify: `Alas/Sources/Remote/Native/NativePeerSessions.swift:202-211` (`rebuildSnapshot`), `:266-294` (`reconcileSelectedTab`)
- Test: `AlasTests/Remote/NativePeerSidebarSnapshotTests.swift`, `AlasTests/Remote/NativePeerSessionsTests.swift`

**Interfaces:**
- Consumes: `PeerHostWorktree` (Task 3), `NativePeerHosts.worktrees` (Task 4), `RemoteWorktreeSummaryBuilder.make(projectName:worktree:isMain:isFolder:metrics:)`.
- Produces:
  - `NativePeerSidebarSnapshot.build(peers:rows:consoles:projects:hostWorktrees: [String: [PeerHostWorktree]] = [:])` — used for online peers only, like consoles.
  - `NativePeerGroup.hostWorktrees: [PeerHostWorktree]?` (nil = no host channel: session-derived grouping as today)
  - `NativePeerRepoGroup.build(sessions:consoles:projects:hostWorktrees: [PeerHostWorktree]? = nil, ordering:)`
  - `NativePeerWorktreeGroup.host: PeerHostWorktree?`; `worktree`, `peerWorktreeId`, `isMain`, `isFolder`, `title` fall back to it; `status` puts `host?.snapshot.operation` first.
  - `static func NativePeerWorktreeGroup.status(for operation: WorktreeOperation) -> WorktreeRowView.StatusPresentation`

- [ ] **Step 1: Write the failing tests**

In `NativePeerSidebarSnapshotTests`:

```swift
@Test func hostWorktreesListIdleOnesAndJoinSessionRowsByWorktreeId() {
    // host worktrees of project p: main, feature, idle; one session row with
    // projectId "p", worktreeId feature.id
    let worktrees = snapshot.groups[0].repos(ordering: .manual)[0].worktrees
    #expect(worktrees.map(\.title) == ["main", "feature", "idle"])        // main pinned, no duplicate feature row
    #expect(worktrees[1].sessions.map(\.id) == ["B:s"])
    #expect(worktrees[1].host?.snapshot.worktree.id == feature.id)
    #expect(worktrees[2].sessions.isEmpty)
    #expect(worktrees[2].worktree?.branch == "idle")                      // summary from the host for the right pane
    #expect(worktrees[2].peerWorktreeId == idle.id)                       // new-session preselection
}

@Test func peersWithoutTheHostChannelKeepSessionDerivedGrouping() {
    // peers B and C online, rows for both, hostWorktrees only for "B"
    #expect(withHosts.groups[1] == NativePeerSidebarSnapshot.build(peers: peers, rows: rows).groups[1])
    #expect(withHosts.groups[1].hostWorktrees == nil)
}

@Test(arguments: [
    (WorktreeOperation.deleting, "Deleting…", "fg-muted", true),
    (.archiving, "Archiving…", "fg-muted", true),
    (.preparingDelete, "Preparing deletion…", "fg-muted", true),
    (.deleteFailed(message: "locked"), "Delete failed: locked", "del", false),
])
func hostOperationsOutrankSessionStatus(_ operation: WorktreeOperation, note: String, colorToken: String, pulses: Bool) {
    // a worktree group with a streaming session and a host snapshot holding `operation`
    #expect(group.status == .init(note: note, colorToken: colorToken, pulses: pulses))
}
```

In `NativePeerSessionsTests` (Review Focus 4):

```swift
@Test func anIdleHostWorktreeSelectsIntoItsEmptyStateAndClearsWhenTheHostDropsIt() async throws {
    // capable peer B; snapshot with idle worktree; subscribed
    client.selectWorktree(selection)
    #expect(client.selectedWorktree == selection)
    #expect(client.selectedTab == nil)
    #expect(client.selectedWorktreeGroup?.worktree != nil)               // RootView shows the peer right pane
    #expect(client.newSessionTarget(in: selection) != nil)
    hosts.receive(serverId: "B", .events(events: [.worktreeRemoved(projectID: "p", worktreeID: idle.id)], cursor: cursor))
    #expect(client.selectedWorktree == nil)
}
```

- [ ] **Step 2: Run to verify they fail**

Run (CI): `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/NativePeerSidebarSnapshotTests -only-testing AlasTests/NativePeerSessionsTests test`
Expected: build FAILS ("extra argument 'hostWorktrees' in call").

- [ ] **Step 3: Implement**

- `NativePeerRepoGroup.build`: after sessions and consoles, for each host worktree `place(repo: repoKey(projectId: w.project.id), worktreeKey: "id:\(w.snapshot.worktree.id)", name: w.project.name)` into a `hostBuckets` map (the "already placed" check in `place` also consults `hostBuckets`), and let `w.project.name` win for the repo name as inventory names do. Keys match `NativePeerWorktreeGroup.key(for:)`, so session and console rows join the host row; rows whose worktree the host does not list keep their own rows.
- `NativePeerWorktreeGroup`: `worktree` = sessions' summary ?? consoles' ?? `host.map { RemoteWorktreeSummaryBuilder.make(projectName: $0.project.name, worktree: $0.snapshot.worktree, isMain: $0.isMain, isFolder: $0.project.kind == .folder, metrics: .unavailable) }`; `peerWorktreeId` falls back to `host?.snapshot.worktree.id`. `status(for:)` copies `WorktreeRowView.statusText` wording: `creating` "Creating…", `preparingDelete` "Preparing deletion…", `deleting` "Deleting…", `archiving` "Archiving…" (all `"fg-muted"`, pulsing); `createFailed`/`launchFailed`/`deleteFailed(message)` "Create failed: …"/"Launch failed: …"/"Delete failed: …" with `message.trimmedForDisplay` (`"del"`, not pulsing).
- `NativePeerSessions.rebuildSnapshot()`: pass `hostWorktrees: hosts?.worktrees ?? [:]`. In `reconcileSelectedTab()`, when `worktree(selection) == nil`, `selectedTab == nil` and `hosts?.worktrees[selection.serverId] != nil` (the host is authoritative), set `selectedWorktree = nil` and `selectedWorktreeTabs = []`; the existing early return stays for every other missing-row case.

- [ ] **Step 4: Verify**

Run: `swift test --package-path Packages/AlasCore --filter 'PeerHostChannelTests|PeerWorktreeLifecycleTests'` (unchanged, PASS). In CI the two suites above PASS.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Remote/Native/NativePeerSidebarSnapshot.swift Alas/Sources/Remote/Native/NativePeerSessions.swift AlasTests/Remote/NativePeerSidebarSnapshotTests.swift AlasTests/Remote/NativePeerSessionsTests.swift
git commit -m "feat(remote): list every host worktree in the peer sidebar"
```

---

### Task 6: Changes and Files for a selected worktree without a session

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocol.swift` (`HostWorktreeRead`, `HostRequest.readWorktree`, `HostResponse.worktreeRead`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocolServer.swift:170-306` (`respond(to:)`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/AlasCoreContext+RemoteInspection.swift:282-660` (split each session-keyed read into a session resolve plus a worktree-keyed read)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteProtocol.swift:1443-1462` (`HostProtocolCapability.worktreesReadV1`)
- Modify: `Alas/Sources/Remote/Native/NativePeerHosts.swift`, `Alas/Sources/Remote/Native/NativePeerSessions.swift:232-241,834-945,1046-1050,1180-1245`, `Alas/Sources/Right/NativePeerRightPaneView.swift:87-105,146-160`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/HostProtocolTests.swift`, `Packages/AlasCore/Tests/AlasCoreTests/HostProtocolServerTests.swift`, `AlasTests/Remote/NativePeerSessionsTests.swift`

**What exists (recon):** `followWorktree`/`unfollowWorktree` (`host.worktrees.follow.v1`) only keep a worktree's *review status* (`reviewFollowers`/`reviewRefreshes`) refreshed; no host request or event carries changed files, diffs, a file listing or file contents. The six reads exist only session-keyed on the Remote protocol (`listChanges`, `fileDiff`, `listFiles`, `listCommitFiles`, `commitFileDiff`, `readFile`), served by `RemoteSessionGateway` through `AlasCoreContext.remote…(sessionId:)`, each of which resolves the session to a `Worktree` first (`remoteWorktreeContext(sessionId:)`). So the smallest addition is one worktree-keyed host request that reuses those reads and answers with the same reply message.

**Interfaces:**
- Consumes: `PeerHostChannel.request` (Task 2), `NativePeerHosts` (Task 4), `NativePeerWorktreeGroup.host` and the idle selection (Task 5).
- Produces:

```swift
/// One read of a worktree's code, as the Remote session requests of the same name.
public enum HostWorktreeRead: Codable, Equatable, Sendable {
    case changes(comparisonMode: AppConfig.Changes.ChangesComparisonMode?)
    case fileDiff(path: String, stage: String?, comparisonMode: AppConfig.Changes.ChangesComparisonMode?)
    case files(path: String?, comparisonMode: AppConfig.Changes.ChangesComparisonMode?)
    case commitFiles(sha: String)
    case commitDiff(sha: String, path: String)
    case file(path: String)
}
// HostRequest:  case readWorktree(worktree: WorktreeRef, read: HostWorktreeRead)      (host.worktrees.read.v1)
// HostResponse: case worktreeRead(reply: RemoteServerMessage)
//   `reply` is the message the session path sends for the same read
//   (.changeList/.changeListFailed, .fileDiffResult/.fileDiffFailed, .fileTree/.fileTreeFailed,
//    .commitFiles/.commitFilesFailed, .commitDiffResult/.commitDiffFailed, .fileContents/.fileUnavailable),
//   with `sessionId` set to the worktree's id.
HostProtocolCapability.worktreesReadV1 = "host.worktrees.read.v1"   // appended to `served`
// AlasCoreContext (package-internal):
func remoteRead(_ read: HostWorktreeRead, in worktree: Worktree, replyingAs id: String) async -> RemoteServerMessage
// App:
NativePeerHosts.canRead(serverId: String) -> Bool        // channel subscribed && supports host.worktrees.read.v1
NativePeerHosts.read(_ read: HostWorktreeRead, in worktree: PeerHostWorktree, serverId: String) async -> RemoteServerMessage?
NativePeerSessions.canReadWorkspace: Bool                // a session is selected, or the selected worktree is readable over the host channel
NativePeerSessions.workspaceWorktreePath: String?        // selectedRow's summary path, else the selected group's
```

- [ ] **Step 1: Write the failing package tests**

`HostProtocolTests`: add `HostClientMessage(id: 20, request: .readWorktree(worktree: ref, read: .fileDiff(path: "a.swift", stage: "unstaged", comparisonMode: nil)))` to `clientMessagesRoundTrip` and `.response(id: 13, result: .worktreeRead(reply: .fileContents(sessionId: "/srv/feature", path: "a.txt", text: "hi", truncated: false)))` to `serverMessagesRoundTrip`.

`HostProtocolServerTests` (extend with the existing `RepoFixture`, a real repository):

```swift
/// A worktree is read as a session in it would be, keyed by the worktree.
@Test func worktreeReadsAnswerWithTheSessionReplyKeyedByTheWorktree() async throws {
    let fixture = try await RepoFixture()
    defer { fixture.tearDown() }
    let worktree = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first)
    try "hi\n".write(to: worktree.path.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    let ref = WorktreeRef(projectID: fixture.projectID, path: worktree.path.path)

    #expect(try await fixture.request(.readWorktree(worktree: ref, read: .file(path: "notes.txt")))
        == .worktreeRead(reply: .fileContents(sessionId: worktree.id, path: "notes.txt", text: "hi\n", truncated: false)))
    guard case .worktreeRead(.fileTree(worktree.id, nil, let nodes, _)) =
        try await fixture.request(.readWorktree(worktree: ref, read: .files(path: nil, comparisonMode: nil)))
    else { Issue.record("expected a file tree"); return }
    #expect(nodes.contains { $0.path == "notes.txt" })
    guard case .worktreeRead(.fileUnavailable(worktree.id, "../outside", .pathRejected, _, _)) =
        try await fixture.request(.readWorktree(worktree: ref, read: .file(path: "../outside")))
    else { Issue.record("expected the escape refused"); return }
    #expect(try await fixture.request(.readWorktree(worktree: WorktreeRef(projectID: fixture.projectID, path: "/srv/missing"), read: .file(path: "a")))
        == .failure(error: .notFound(what: "worktree /srv/missing in project \(fixture.projectID)")))
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path Packages/AlasCore --filter 'HostProtocolTests|HostProtocolServerTests'`
Expected: build FAILS ("type 'HostRequest' has no member 'readWorktree'").

- [ ] **Step 3: Implement the host side**

- `AlasCoreContext+RemoteInspection.swift`: each `remote…(sessionId:…)` keeps its signature and failure reasons (`sessionUnknown`/`worktreeUnavailable`) but, once it has the `Worktree`, calls a new package-internal `remote…(in worktree: Worktree, …)` holding today's body. `RemoteSessionGateway` and the `RemoteWorktreeInspecting` seam are untouched, so the session path behaves exactly as before.
- `remoteRead(_:in:replyingAs:)`: switches on the read, calls the worktree-keyed function and wraps the result in the reply case the gateway sends for it (`RemoteSessionGateway.swift:364-467` is the mapping to copy, with `replyingAs` as `sessionId`).
- `HostProtocolServer.respond(to:)`: `case .readWorktree(let ref, let read): return .worktreeRead(reply: await host.core.remoteRead(read, in: try worktree(ref), replyingAs: try worktree(ref).id))`. Reading needs no lease or claim, like the session path ("seeing a session is enough to read its code"); a paired peer can already list and open every worktree.
- `HostProtocolCapability.worktreesReadV1` with a doc line ("Hosts that serve `readWorktree`"), appended to `served`. An older host cannot decode `readWorktree` and answers nothing; `worktreeRead` is only ever an answer to it, so no older client meets it.

- [ ] **Step 4: Run the package tests to verify they pass**

Run: `swift test --package-path Packages/AlasCore --filter 'HostProtocolTests|HostProtocolServerTests|HostSessionsTests'`
Expected: PASS. Then `swift test --package-path Packages/AlasCore` once, since the inspection split touches the Remote file reads.

- [ ] **Step 5: Write the failing app test** in `NativePeerSessionsTests` (Review Focus 4)

```swift
@Test(arguments: [false, true])
func aSelectedIdleWorktreeReadsItsFilesOverTheHostChannel(servesReads: Bool) async throws {
    // capable peer B (host.v1, host.events.v1, and host.worktrees.read.v1 only when servesReads),
    // snapshot with idle worktree `idle` and `other`, subscribed; select `idle`
    #expect(client.canReadWorkspace == servesReads)
    let reads = sent.compactMap { if case .readWorktree(let ref, let read) = $0.1.request { (ref, read) } else { nil } }
    guard servesReads else { #expect(reads.isEmpty); return }
    #expect(reads.map(\.1) == [.changes(comparisonMode: nil), .files(path: nil, comparisonMode: nil)])
    #expect(reads.allSatisfy { $0.0 == WorktreeRef(projectID: "p", path: idle.path.path) })
    let nodes = [RemoteFileNode(name: "notes.txt", path: "notes.txt", kind: "file", badge: nil, childrenState: "none", isSubmodule: false)]
    hosts.receive(serverId: "B", .response(id: filesRequestID, result: .worktreeRead(
        reply: .fileTree(sessionId: idle.id, path: nil, nodes: nodes, truncated: false))))
    try await eventually("file tree") {   // loaded, with one node at "notes.txt" (match on the workspace's node type)
        if case .loaded(let loaded) = client.workspace.fileTree { loaded.map(\.path) == ["notes.txt"] } else { false }
    }
    // a late answer for a worktree no longer selected is dropped
    client.selectWorktree(otherSelection)
    hosts.receive(serverId: "B", .response(id: changesRequestID, result: .worktreeRead(
        reply: .changeListFailed(sessionId: idle.id, reason: .gitFailed, message: "late"))))
    #expect(client.workspace.changes != .failed("late"))   // NativePeerWorkspace.Load.failed(String)
}
```

- [ ] **Step 6: Implement the client side**

- `NativePeerHosts.read`: `nil` unless `canRead(serverId:)`; otherwise `await channel.request(.readWorktree(worktree: WorktreeRef(projectID: worktree.snapshot.worktree.projectId, path: worktree.snapshot.worktree.path.path), read: read))`, returning `reply` for `.worktreeRead(reply)` and `nil` otherwise (a failure or timeout leaves the workspace to `markUnavailable()`).
- `NativePeerSessions`:
  - Extract the workspace part of `receive(_:)` (the in-flight bookkeeping, `workspace.apply`, the outdated retries; lines ~1205-1245) into `private func applyWorkspaceReply(_ message: RemoteServerMessage) -> Bool`, called by the session path as before.
  - `private func routeWorkspaceRead(_ read: HostWorktreeRead, session: (String) -> RemoteClientMessage) -> Bool`: with a session selected, `routeWhileOnline(session)` exactly as today; otherwise, when the selected group has a `host` and `hosts?.canRead(serverId:)`, start `Task { if let reply = await hosts.read(…), selectedSessionId == nil, selectedWorktreeGroup?.host?.snapshot.worktree.id == reply.sessionId { applyWorkspaceReply(reply) } else { workspace.markUnavailable() if still selected } }` and return true; else false.
  - `requestChanges`, `loadFileTree`, `loadFileTreeChildren`, `loadCommitFiles` and `open(_:)` guard on `canReadWorkspace` instead of `selectedSessionId != nil` and send through `routeWorkspaceRead` (`.changes`, `.files`, `.files(path:)`, `.commitFiles`, `.fileDiff`/`.commitDiff`/`.file`). `requestChanges` reads the summary as `selectedRow?.worktree ?? selectedWorktreeGroup?.worktree`.
  - `selectWorktree`'s no-tab branch calls `reloadWorkspace()` after setting `selectedWorktree` (`clearSelection()` already resets the workspace). `rebuildSnapshot()` reloads when the selected tab-less group's `host?.snapshot` differs from the one last loaded, so a host `worktreeChanged` refreshes it.
- `NativePeerRightPaneView`: show the "Select a session…" message only when `!client.canReadWorkspace`; use `client.workspaceWorktreePath` for both `worktreePath:` arguments; key the changes view with `.id(client.selectedSessionId ?? client.selectedWorktree?.worktreeId)`.

- [ ] **Step 7: Verify**

Run: `swift test --package-path Packages/AlasCore --filter 'HostProtocolTests|HostProtocolServerTests'` (PASS). In CI: `xcodebuild … -only-testing AlasTests/NativePeerSessionsTests -only-testing AlasTests/NativePeerWorkspaceTests test` PASS (the second suite guards the unchanged session path).

- [ ] **Step 8: Commit**

```bash
git add Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocol.swift Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocolServer.swift Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/AlasCoreContext+RemoteInspection.swift Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteProtocol.swift Packages/AlasCore/Tests/AlasCoreTests/HostProtocolTests.swift Packages/AlasCore/Tests/AlasCoreTests/HostProtocolServerTests.swift Alas/Sources/Remote/Native/NativePeerHosts.swift Alas/Sources/Remote/Native/NativePeerSessions.swift Alas/Sources/Right/NativePeerRightPaneView.swift AlasTests/Remote/NativePeerSessionsTests.swift
git commit -m "feat(remote): show changes and files of a peer worktree without a session"
```

---

### Task 7: Archive and delete from the peer sidebar

**Files:**
- Modify: `Alas/Sources/Remote/Native/NativePeerHosts.swift` (actions)
- Modify: `Alas/Sources/App/AppState+PeerHosts.swift` (dialogs)
- Modify: `Alas/Sources/App/AppState.swift:11679` (`confirmDeleteWorktree` drops `private`)
- Modify: `Alas/Sources/Sidebar/NativePeerSidebarView.swift:37-48,131-167,352-406` (context menu)
- Modify: `Alas/Sources/Sidebar/SidebarView.swift:315-330` (pass the keep-branch rule)
- Test: `AlasTests/Remote/NativePeerSessionsTests.swift`

**Interfaces:**
- Consumes: `PeerWorktreeRemoval.run`, `PeerWorktreeControls`, `PeerHostWorktree.controls(lifecycleSupported:)` (Task 3); `NativePeerHosts` (Task 4); `NativePeerWorktreeGroup.host` (Task 5); `AppState.deleteConfirmation(branch:keepBranch:)`, `AppState.resolveDeleteBranchIfMerged(globalDeleteOnRemove:keepBranch:)`, `AppState.forceDeleteAlertTitleSuffix`, `AppState.forceDeleteAlertMessage`, `AppState.showFileActionError(title:message:)`.
- Produces:
  - `NativePeerHosts.controls(for worktree: PeerHostWorktree, serverId: String) -> PeerWorktreeControls` — `worktree.controls(lifecycleSupported: supports(serverId, HostProtocolCapability.worktreesLifecycleV1))`
  - `NativePeerHosts.archive(_ worktree: PeerHostWorktree, serverId: String, peerName: String)`
  - `NativePeerHosts.delete(_ worktree: PeerHostWorktree, keepBranch: Bool, deleteBranchIfMerged: Bool, serverId: String, peerName: String)`
  - `AppState.confirmPeerWorktreeRemoval(_ confirmation: PeerWorktreeRemoval.Confirmation, peerName: String) -> Bool`
  - `NativePeerSidebarView.showKeepBranchOption: Bool = false`

- [ ] **Step 1: Write the failing test** in `NativePeerSessionsTests` (Review Focus 5)

```swift
@Test(arguments: [false, true])
func peerWorktreeControlsNeedTheLifecycleCapability(lifecycle: Bool) async throws {
    // peer B serves host.v1 + host.events.v1, and host.worktrees.lifecycle.v1 only when `lifecycle`;
    // snapshot with a plain feature worktree, answered and subscribed (poll each step with `eventually`)
    try await eventually("host worktrees") { hosts.worktrees["B"] != nil }
    let feature = try #require(hosts.worktrees["B"]?.first)
    #expect(hosts.controls(for: feature, serverId: "B") == (lifecycle ? .available : .hidden))
    let before = sent.count
    hosts.archive(feature, serverId: "B", peerName: "Mac B")
    if lifecycle {
        try await eventually("archive request") { sent.count == before + 1 }
        #expect(sent.last?.1.request == .archiveWorktree(
            worktree: WorktreeRef(projectID: "p", path: feature.snapshot.worktree.path.path),
            lineageID: feature.snapshot.worktree.lineageID, branch: "feature", discardUnsavedEdits: false))
    } else {
        #expect(sent.count == before)          // an older host is never sent a lifecycle request
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run (CI): `xcodebuild … -only-testing AlasTests/NativePeerSessionsTests test`
Expected: build FAILS ("value of type 'NativePeerHosts' has no member 'controls'").

- [ ] **Step 3: Implement**

- `NativePeerHosts.archive`/`.delete`: return at once unless `controls(for:serverId:) == .available` and the peer's channel exists; otherwise `Task { let outcome = await PeerWorktreeRemoval.run(action, on: worktree.snapshot, request: { await channel.request($0) }, confirm: { await confirm($0, peerName) }) }`, and on `.refused(let message)` call `showError("Archive Failed" | "Delete Failed", message)`. Nothing else: the host's events update or remove the row.
- `AppState+PeerHosts.swift`: `makeNativePeerHosts()` passes `confirm: { [weak self] in self?.confirmPeerWorktreeRemoval($0, peerName: $1) ?? false }` and `showError: { [weak self] in self?.showFileActionError(title: $0, message: $1) }`. `confirmPeerWorktreeRemoval` uses `NSAlert` (`.warning`, destructive first button, "Cancel" second) with the local strings:
  - `.delete(branch, keepBranch)` → `confirmDeleteWorktree(Self.deleteConfirmation(branch: branch, keepBranch: keepBranch))`
  - `.force(branch)` → title `"'\(branch)' \(Self.forceDeleteAlertTitleSuffix)"`, text `Self.forceDeleteAlertMessage`, button "Force Delete"
  - `.discardUnsavedEdits(branch, archiving)` → title `"\(action) worktree '\(branch)'?"` (`action` = "Archive"/"Delete"), text `"An editor on \(peerName) has unsaved changes in this worktree. \(archiving ? "Archiving" : "Deleting") will discard them; save them on \(peerName) first to keep them."`, button `"Discard & \(action)"`.
- `NativePeerSidebarView`: add `var showKeepBranchOption: Bool = false`; on `NativePeerWorktreeRow` attach `.contextMenu` when `worktree.host` is non-nil and `client.hosts?.controls(for:serverId:)` is not `.hidden`: buttons "Archive", "Delete Worktree…" (destructive) and, when `showKeepBranchOption`, "Delete Worktree, Keep Branch…" (destructive) — the local row's labels. Delete passes `deleteBranchIfMerged: AppState.resolveDeleteBranchIfMerged(globalDeleteOnRemove: showKeepBranchOption, keepBranch:)`. For `.disabled(reason)` the buttons are `.disabled(true)` followed by `Text(reason)`.
- `SidebarView.swift:315`: pass `showKeepBranchOption: state.config.worktrees.deleteBranchOnRemove`.

- [ ] **Step 4: Verify**

Run: `swift test --package-path Packages/AlasCore` (whole package, it is cheap and every package change of this PR is in).
Expected: PASS. If the machine allows, `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -quiet build > /tmp/alas-build.log 2>&1; echo "exit $?"` (expected `exit 0`; never pipe into `tail`, which hides the status); otherwise CI's build-test is the first compile (spec constraint). In CI, `NativePeerSessionsTests` PASS.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Remote/Native/NativePeerHosts.swift Alas/Sources/App/AppState+PeerHosts.swift Alas/Sources/App/AppState.swift Alas/Sources/Sidebar/NativePeerSidebarView.swift Alas/Sources/Sidebar/SidebarView.swift AlasTests/Remote/NativePeerSessionsTests.swift
git commit -m "feat(remote): archive and delete paired hosts' worktrees from the sidebar"
```
