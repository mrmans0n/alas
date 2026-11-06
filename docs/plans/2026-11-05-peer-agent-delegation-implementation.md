# Agent Delegation to Paired Peers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an agent on one machine start, message, wait on, read and stop a child session on another paired machine, and wake with its result.

**Architecture:** The target stores the child as an ordinary delegated session whose parent is the sentinel `peer:<serverId>`, so its existing coordinator handles recovery and outcomes. The store sends those outcomes to an outbox rather than the inbox. The source collects the outbox through the host protocol, moves a durable per-peer cursor, and enqueues each entry on its local inbox.

**Tech Stack:** Swift 5.9+, Swift Testing, SQLite via `SQLiteDatabase`, the Rust `alas` CLI in `AlasCLI/`.

**Spec:** `docs/plans/2026-11-05-peer-agent-delegation-design.md`

## Global Constraints

- New capability string: `host.delegation.v1`. Never send a `.delegation` request to a peer that does not advertise it.
- `agentAccess` values: `off`, `ask`, `autoRun`. Existing and new devices default to `off`.
- Sentinel parent format: `peer:<serverId>`.
- Effective auto-run: `parent.autoRunEnabled && device.agentAccess == .autoRun`.
- Orchestration schema goes from version 4 to version 5.
- Offline notice delay: 15 minutes. It is a notice, not a wake.
- `Packages/AlasCore` must not import SwiftUI, AppKit, WebKit, GhosttyKit, MLX, `TreeSitterPack` or `FffC`. Anything used from outside is `public`.
- Tests use Swift Testing and follow the repo's Testing policy: extend the named suite, one behaviour per test, `@Test(arguments:)` for variants, no fixed sleeps, real git only where stated.
- Run focused tests only. In this plan, `CORE <filter>` means `swift test --package-path Packages/AlasCore --filter <filter>`, `APP <Suite>` means `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/<Suite> test`, and `RUST` means `cargo test --manifest-path AlasCLI/Cargo.toml`. For `APP`, check the `Test run with N tests in M suites` line, because a wrong suite name passes silently.
- Only the controller runs `xcodebuild`; concurrent builds deadlock on the build database.
- Conventional Commit titles. No agent attribution anywhere. Each PR gets its own branch, opened only when the user asks.

## Review Focus

1. **Two instances sharing a profile (Alas Dev and the release app) both collect.** One wake only. Pinned in Task 10.
2. **Re-pairing while a child runs.** The new device starts `off`: `send` is refused, but `status`, `read`, `interrupt` and `outbox` still reach the old child. Pinned in Task 4.
3. **A laptop asleep for hours while several outcomes accumulate.** They arrive in order, each once, even with the parent's tab closed. Pinned in Task 10.
4. **A large final message.** An outbox page stays under the frame limit and pages rather than failing the link. Pinned in Task 4.
5. **Unsuitable targets and ambiguous names.** A target worktree in an SSH project, a folder project, or one held by an operation gets a clear refusal; two peers with the same name give an error listing their server ids. Pinned in Tasks 3 and 8.

---

# PR 1: Target

### Task 1: Store: outbox, cursor and peer column

**Files:**
- Create: `Packages/AlasCore/Sources/AlasModel/Model/ACPPeerDelegationModels.swift`
- Modify: `Packages/AlasCore/Sources/AlasACP/ACP/Orchestration/ACPOrchestrationStore.swift`, `ACPOrchestrationPersistence.swift`, `Packages/AlasCore/Sources/AlasModel/Model/ACPOrchestrationModels.swift`
- Test: `AlasTests/ACP/Orchestration/ACPOrchestrationStoreTests.swift`

**Interfaces:**
- Produces in `AlasModel`:
  - `enum ACPPeerParent { static func sentinel(serverId: String) -> String; static func serverId(from parentSessionId: String) -> String? }`
  - `struct ACPPeerOutboxEntry: Codable, Equatable, Sendable { seq: Int64; messageId: String; childSessionId: String; prompt: String; kind: ACPDelegatedMessageKind; createdAt: Int64 }`
  - `ACPDelegationRecord.peerServerId: String?`
- Produces on the store and persistence:
  - `outbox(peerServerId: String, after: Int64, maxBytes: Int) throws -> (entries: [ACPPeerOutboxEntry], hasMore: Bool)`
  - `acknowledgeOutbox(peerServerId: String, through: Int64) throws`
  - `deleteOutbox(peerServerId: String) throws`
  - `collectPeerEntry(_ entry: ACPPeerOutboxEntry, peerServerId: String, parentSessionId: String) throws -> Bool`, which returns true only for the caller that advanced the cursor
  - `peerCursor(peerServerId: String) throws -> Int64`, 0 when absent
  - `peerChildren(peerServerId: String) throws -> [ACPDelegationRecord]`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func outcomeForPeerParentGoesToOutboxNotInbox() throws {
    try store.enqueue(message(id: "m1", target: ACPPeerParent.sentinel(serverId: "s1")))
    #expect(try store.outbox(peerServerId: "s1", after: 0, maxBytes: .max).entries.map(\.messageId) == ["m1"])
    #expect(try store.pendingMessages(targetSessionId: ACPPeerParent.sentinel(serverId: "s1")).isEmpty)
}

@Test func failedTransitionForPeerParentWritesOutboxInSameTransaction() throws { /* markFailed path: phase is .failed and one outbox row exists */ }

@Test func outboxPageRespectsByteLimitAndAlwaysReturnsOneEntry() throws {
    // two 10 KB entries, maxBytes 1 KB: first page has one entry and hasMore == true
}

@Test func onlyOneCollectorAdvancesTheCursor() throws {
    let entry = outboxEntry(seq: 1)
    #expect(try store.collectPeerEntry(entry, peerServerId: "s1", parentSessionId: "p"))
    #expect(try store.collectPeerEntry(entry, peerServerId: "s1", parentSessionId: "p") == false)
    #expect(try store.pendingMessages(targetSessionId: "p").count == 1)
}

@Test func migratesFromVersion4KeepingRows() throws { /* a v4 file keeps its rows; targetSchemaVersion == 5; peerServerId nil */ }
```

Use the suite's existing helpers for the store and messages.

- [ ] **Step 2: Run to confirm failure.** `APP ACPOrchestrationStoreTests`. Expected: FAIL to compile on `ACPPeerParent`.
- [ ] **Step 3: Implement.** Set `targetSchemaVersion = 5` and add `peer_server_id` to `delegations`, plus the `peer_outbox` table from the spec and `peer_delegation_cursors`. Route inside the store's `enqueue` and `enqueueUnlessTargetEnded`: a target with the `peer:` prefix inserts `INSERT OR IGNORE` into `peer_outbox`. This one place covers `enqueueOutcome` and the transactional failure path at `ACPOrchestrationStore.swift:140`. `collectPeerEntry` runs `BEGIN IMMEDIATE`, updates the cursor only when `entry.seq > seq`, and enqueues the message with `id = entry.messageId` only if that update happened.
- [ ] **Step 4: Run to confirm passing.** `APP ACPOrchestrationStoreTests`. Expected: PASS, with a non-zero test count.
- [ ] **Step 5: Commit.** `feat(acp): store peer delegation outbox and cursors`

### Task 2: Device access and its CLI

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Pairing/RemoteDevice.swift`, `RemotePairingService.swift`, `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocol.swift`, `HostProtocolServer.swift`, `Packages/AlasCore/Sources/alas-host/Commands.swift`
- Create: `Packages/AlasCore/Sources/AlasHostCore/Remote/Pairing/PeerDelegationGate.swift`
- Test: `AlasTests/Remote/RemotePairingServiceTests.swift`, `Packages/AlasCore/Tests/AlasCoreTests/HostProtocolServerTests.swift`

**Interfaces:**
- Produces:
  - `enum RemoteDeviceAgentAccess: String, Codable, Sendable { case off, ask, autoRun }`
  - `RemoteDevice.agentAccess`, decoded tolerantly so that a missing or unknown value is `.off`
  - `RemotePairingService.device(id: String) -> RemoteDevice?`
  - `RemotePairingService.setAgentAccess(_:deviceId:) -> Bool`
  - `HostRequest.setPeerAgentAccess(peerID: String, access: RemoteDeviceAgentAccess)`, local client only
  - `HostPeerSummary.agentAccess: RemoteDeviceAgentAccess?`
  - `enum PeerDelegationVerb { case discover, start, send, read, status, interrupt, outbox }`
  - `PeerDelegationGate.allows(_ verb: PeerDelegationVerb, device: RemoteDevice?) -> Bool`
  - `PeerDelegationGate.effectiveAutoRun(parent: Bool, access: RemoteDeviceAgentAccess) -> Bool`

- [ ] **Step 1: Write the failing tests**

```swift
@Test(arguments: [
    (RemoteDeviceAgentAccess.off, PeerDelegationVerb.start, false),
    (.off, .send, false), (.off, .discover, false),
    (.off, .status, true), (.off, .read, true), (.off, .interrupt, true), (.off, .outbox, true),
    (.ask, .start, true), (.autoRun, .send, true),
])
func gateByAccessAndVerb(access: RemoteDeviceAgentAccess, verb: PeerDelegationVerb, allowed: Bool) {
    #expect(PeerDelegationGate.allows(verb, device: peerDevice(access)) == allowed)
}

@Test func browserDeviceAndMissingDeviceAreRefused() { /* kind .browser with autoRun, and nil: false for every verb */ }

@Test(arguments: [(true, RemoteDeviceAgentAccess.autoRun, true), (true, .ask, false), (false, .autoRun, false), (true, .off, false)])
func effectiveAutoRunIsTheLowerOfBoth(parent: Bool, access: RemoteDeviceAgentAccess, expected: Bool) { /* … */ }

@Test func deviceRecordWithoutAccessDecodesAsOff() throws { /* JSON from before this field */ }
@Test func setPeerAgentAccessRefusesRemoteCaller() async { /* HostProtocolServer with .remotePeer caller: refused, as forgetPeer is */ }
```

- [ ] **Step 2: Run to confirm failure.** `CORE HostProtocolServerTests` and `APP RemotePairingServiceTests`. Expected: FAIL to compile.
- [ ] **Step 3: Implement.** `setPeerAgentAccess` resolves the peer through `localPeers()`, then acts on its `localDeviceId`, returning a refusal saying to pair again when that is nil. Add `alas-host peers agents <id|name|serverId> off|ask|auto` next to `("peers", "remove", 2)`, using `HostPeerSummary.resolve`, and show the value in `peers list`.
- [ ] **Step 4: Run to confirm passing.** Same commands. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(remote): add per-peer agent access`

### Task 3: Coordinator: start a child for a peer

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasAgents/ACP/Orchestration/ACPSessionOrchestrationCoordinator.swift`, `Packages/AlasCore/Sources/AlasHostCore/Core/Orchestration/AlasCoreContext+Orchestration.swift`, `AlasCoreContext+DelegationRecovery.swift`
- Modify: `Packages/AlasCore/Sources/AlasModel/Model/ACPPeerDelegationModels.swift`
- Test: `AlasTests/ACP/Orchestration/ACPSessionOrchestrationCoordinatorTests.swift`

**Interfaces:**
- Consumes: Task 1's `ACPPeerParent`.
- Produces in `AlasModel`:
  - `struct ACPPeerChildStart: Sendable { childID, peerServerId, projectID, target: ACPPeerChildTarget, agentID, modelSelection: ACPDelegatedModelSelection?, role: String?, autoRun: Bool, prompt: String }`
  - `enum ACPPeerChildTarget { case worktree(path: String); case newWorktree(branch: String, base: String, expectedBaseSHA: String?) }`
  - `enum ACPPeerStartResult { case started(sessionId: String, state: String); case refused(String) }`
- Produces on the coordinator: `startForPeer(_ start: ACPPeerChildStart) async -> ACPPeerStartResult`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func startForPeerRecordsSentinelParentAndStartsChild() async { /* record.parentSessionId == "peer:s1", phase .starting, prompt queued */ }
@Test func repeatedStartReturnsTheSameChild() async { /* same childID twice: one record, both .started with the same id */ }
@Test(arguments: [TargetKind.sshProject, .folderProject, .operationHeld, .archived])
func unsuitableTargetIsRefusedWithAReason(kind: TargetKind) async { /* .refused with non-empty reason; no record */ }
@Test func outcomeOfPeerChildReachesOutboxNotAnySession() async { /* childTurnCompleted: outbox has the entry; deliverPendingMessages touches no session */ }
@Test func blockedPeerChildEscalatesThroughOutbox() async { /* childBlocked then escalate: notice then wake entries */ }
@Test func recoveryReattachesPeerChild() async { /* recoverDelegations treats a sentinel row as a local child */ }
@Test func unavailableModelFailsChildRatherThanFallingBack() async { /* failure outcome in outbox; prompt never sent */ }
```

- [ ] **Step 2: Run to confirm failure.** `APP ACPSessionOrchestrationCoordinatorTests`. Expected: FAIL to compile.
- [ ] **Step 3: Implement.** Share `createChild` and the `.new` path. Refuse projects with `host != nil` and `kind == .folder` here. Build the origin from the target's project and worktree with the sentinel as `sessionId`; `createChild` already tolerates a nil `parentSession`. Make `deliverPendingMessages` return early for sentinel targets, and make `rememberParent` and `loadDelegatedSessionParents` ignore them, so `HostSessionSummary.parentID` stays nil. Apply `SessionsAPI`'s admission and checkpoint-recovery checks, turning a failure into `markChildFailed`. Apply `autoRun` by setting `autoRunEnabled` before the first prompt, through `createSession(autoRunDefault:)`. Set `asksAboutRepoHooks = false`.
- [ ] **Step 4: Handle `expectedBaseSHA`.** Before worktree creation: run an explicit fetch of `<remote> <branch>`, where `<remote>` is the project's remote matching the repository, then resolve `<remote>/<branch>`. With an expected SHA, a failed fetch or a different SHA fails the child with `"<branch> on <Mac> is at <sha>, expected <sha>. Push and try again."`. Add the real-git test `expectedBaseMismatchFailsChild`, using the suite's template repository.
- [ ] **Step 5: Add a skipped-hook notice.** When hooks were skipped, enqueue one notice entry through the normal path. Test: `skippedHookProducesANotice`.
- [ ] **Step 6: Run to confirm passing.** Same command. Expected: PASS.
- [ ] **Step 7: Commit.** `feat(acp): start delegated children on behalf of a peer`

### Task 4: Host protocol `.delegation`

**Files:**
- Create: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost+PeerDelegation.swift`, `Packages/AlasCore/Sources/AlasFoundation/Helpers/GitRemoteIdentity.swift`
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocol.swift`, `HostProtocolServer.swift`, `AlasHost+Events.swift`, `Remote/Protocol/RemoteProtocol.swift`, `Remote/Peer/PeerHostChannel.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/HostProtocolServerTests.swift`

**Interfaces:**
- Consumes: Tasks 1 to 3.
- Produces:
  - `HostProtocolCapability.delegationV1 = "host.delegation.v1"`
  - `HostRequest.delegation(HostDelegationRequest)`, with the cases in the spec, where `start` carries `HostDelegationStart`
  - `HostResponse.delegation(HostDelegationResponse)`, with `.discovered(HostDelegationDiscovery)`, `.started(sessionID: String, state: String)`, `.read(data: Data)`, `.status(data: Data)`, `.interrupted(cancelRequested: Bool)`, `.outbox(entries: [ACPPeerOutboxEntry], hasMore: Bool)`
  - `HostDelegationDiscovery { access: RemoteDeviceAgentAccess; projects: [ProjectSnapshot]; worktrees: [WorktreeSnapshot]; agents: [RemoteAgentOption] }`
  - `HostEvent.delegationOutboxChanged`, sent only to clients that accept that kind and whose device's `peerServerId` matches
  - `PeerHostChannel.onDelegationOutboxChanged: (@MainActor () -> Void)?`
  - `GitRemoteIdentity.normalized(_ url: String) -> String?`, giving `host/owner/repo` without credentials, scheme or `.git`
  - `DelegationAPI.status(sessionIDs:)` and `DelegationAPI.read(...)`, which return the same JSON as `session_wait` and `session_read`

- [ ] **Step 1: Write the failing tests**

```swift
@Test(arguments: [
    ("git@github.com:o/r.git", "github.com/o/r"),
    ("https://user:token@github.com/o/r.git", "github.com/o/r"),
    ("ssh://git@github.com:22/o/r", "github.com/o/r"),
    ("/local/path", nil as String?),
])
func normalizesRemotes(url: String, expected: String?) { #expect(GitRemoteIdentity.normalized(url) == expected) }

@Test func delegationIsRefusedForEveryCallerExceptAPeerInstance() async { /* .app, .cli, .session, .localUser, browser device */ }
@Test func startIsRefusedWhileOffAndNoSessionIsCreated() async { /* … */ }
@Test func childOfAnotherPeerIsNotFound() async { /* send, read, status, interrupt from s2 on a child of s1 */ }
@Test func rePairedPeerReachesItsChildButCannotSendUntilAllowed() async {
    // A new device with the same peerServerId and access .off:
    // status, read, interrupt, outbox succeed; send is refused
}
@Test func outboxPageStaysUnderFrameLimitAndPages() async { /* an entry-heavy peer: reply fits limit, hasMore true, the next page continues */ }
@Test func outboxAcknowledgesEntriesThroughAfter() async { /* outbox(after: 2) deletes seq ≤ 2 */ }
@Test func outboxEventReachesOnlyTheOwningPeer() async { /* s2's subscription gets no event for s1's entry */ }
@Test func capabilityIsAdvertised() async { /* .capabilities contains host.delegation.v1 */ }
```

- [ ] **Step 2: Run to confirm failure.** `CORE HostProtocolServerTests`. Expected: FAIL to compile.
- [ ] **Step 3: Implement.** Dispatch resolves `caller` to a device through `RemotePairingService`, then calls `PeerDelegationGate`. Ownership compares `device.peerServerId` with `ACPPeerParent.serverId(from: record.parentSessionId)`, and a mismatch answers `SessionRefusal.notFound`. `start` computes `effectiveAutoRun`. `discover` reads each project's remotes only when asked and matches with `GitRemoteIdentity`. Set the outbox page size from the frame limit already enforced for host replies (`4f0efee6d` added one). A single oversized entry has its `prompt` truncated with a note to use `session_read`. `HostProtocolServer` needs access to the pairing service, which is wired alongside `remotePeers` in both `AppState.swift` and `alas-host/main.swift`. Advertise the capability on both.
- [ ] **Step 4: Run to confirm passing.** Same command. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(alas-host): serve agent delegation to paired peers`

### Task 5: What a peer child sees

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasACP/ACP/Session/ACPMCPPromptPreamble.swift`, `BuiltInAlasMCP.swift`, `Packages/AlasCore/Sources/AlasModel/Model/ACPDelegatedOutcomeText.swift`, `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCLICommandRouter.swift`, `AlasCLI/crates/alas/src/mcp.rs`
- Test: `AlasTests/ACP/Session/ACPMCPPromptPreambleTests.swift`, `AlasTests/AlasCLICommandRouterTests.swift`, the `mcp.rs` tests

**Interfaces:**
- Consumes: `ACPPeerParent`.
- Produces: `ALAS_PARENT_SESSION_ID=peer:<serverId>` reaches the MCP server through the existing env path, and `isDelegated` is already true for it. Rust gains `fn is_peer_child(parent: Option<&str>) -> bool`. The preamble's builders gain `isPeerChild: Bool`.

The design's `.peerChild` scope is implemented through this env value rather than a new `BuiltInMCPToolScope` case. The existing cases describe SSH relays, and peer children never run in SSH projects (Task 3).

- [ ] **Step 1: Write the failing tests**

```rust
#[test]
fn peer_child_discovery_omits_machine_and_workspace_tools() {
    // removed: session_new, session_wait, session_interrupt, computer_*, vm_*, device_*,
    // preview_*, open, worktree_new, worktree_delete, worktree_switch, workspace_*
    // kept: notify, pr_create, pr_status, review
}
```

```swift
@Test func peerChildPreambleSaysFinalMessageIsTheReport() {
    // contains "Your final message is your report", and not "session_send"
}
@Test(arguments: ["computer_click", "worktree_delete", "session_new"])
func routerRefusesRemovedToolsFromPeerChild(tool: String) async { /* a direct call is refused, as for a delegated child */ }
@Test func sessionSendFromPeerChildExplainsItself() async { /* error includes "final message" */ }
```

- [ ] **Step 2: Run to confirm failure.** `RUST`, `APP ACPMCPPromptPreambleTests`, `APP AlasCLICommandRouterTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Use the spec's preamble sentence exactly. The initialize instructions at `mcp.rs:228` and `:231` get the same text for peer children. In `ACPDelegatedOutcomeText`, add a `peerFinished` wording used for `.wake` with a peer record: `"[alas system] Delegated session <id> (<agent>) on <Mac> finished. Its final message:\n<text>"`, keeping the `[alas system] Delegated session` prefix so the card still renders. Include the machine name in the outcome context.
- [ ] **Step 4: Run to confirm passing.** Same commands. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(acp): tell peer-delegated children how to report`

### Task 6: "From" marker and Settings row

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost.swift`, `Alas/Sources/Remote/Settings/RemoteServerPane.swift`, `Alas/Sources/Remote/Native/NativePeerSessionView.swift`, the session tab and sidebar row views
- Test: `AlasTests/ACP/Session/` existing presentation suite, if a decision is extracted; `Packages/AlasCore/Tests/AlasCoreTests/HostSessionsTests.swift`

**Interfaces:**
- Consumes: Task 2's access API.
- Produces: `HostSessionSummary.delegatedFromName: String?`, decoded tolerantly, using the device record's name and falling back to `"another Mac"` when the peer has been forgotten.

- [ ] **Step 1: Write the failing test.** `summaryNamesThePeerAndSurvivesForgetting`: a sentinel-parent session has the device's name, and has `"another Mac"` after the device is revoked.
- [ ] **Step 2: Run to confirm failure.** `CORE HostSessionsTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the field, then show "From <name>" in the three places. Add the row to each peer in `RemoteServerPane`: title "Let agents on this Mac use this machine", with Off, Ask for approval and Allow auto-run. Under Allow auto-run, the description reads "They can run commands here as you, without asking." With no `localDeviceId`, disable it and show "Pair again to allow this".
- [ ] **Step 4: Run to confirm passing,** then run the build command from `AGENTS.md`. Expected: PASS and a clean build.
- [ ] **Step 5: Commit.** `feat(remote): show where delegated work came from`

---

# PR 2: Source

### Task 7: The peer client seam

**Files:**
- Create: `Packages/AlasCore/Sources/AlasAgents/ACP/Orchestration/ACPDelegationPeers.swift`, `Packages/AlasCore/Sources/AlasHostCore/Remote/Peer/PeerDelegationClient.swift`
- Modify: `AlasCoreContext+Orchestration.swift`, `Alas/Sources/App/AppState+PeerHosts.swift`, `Alas/Sources/Remote/Native/NativePeerHosts.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/` new `PeerDelegationClientTests.swift`, since this type is new

**Interfaces:**
- Consumes: Task 4's requests.
- Produces in `AlasAgents`:

```swift
@MainActor public protocol ACPDelegationPeers: AnyObject {
    var peers: [ACPDelegationPeerInfo] { get }   // name, serverId, state, supportsDelegation
    func discover(serverId: String, repository: String?) async -> Result<ACPPeerDiscovery, ACPPeerError>
    func start(serverId: String, _ start: ACPPeerChildStartRequest) async -> Result<ACPPeerStartReply, ACPPeerError>
    func send(serverId: String, sessionID: String, prompt: String) async -> Result<Void, ACPPeerError>
    func read(serverId: String, sessionID: String, offset: Int?, limit: Int?, maxChars: Int?) async -> Result<Data, ACPPeerError>
    func status(serverId: String, sessionIDs: [String]) async -> Result<Data, ACPPeerError>
    func interrupt(serverId: String, sessionID: String) async -> Result<Bool, ACPPeerError>
    func outbox(serverId: String, after: Int64) async -> Result<ACPPeerOutboxPage, ACPPeerError>
    var onOutboxChanged: (@MainActor (_ serverId: String) -> Void)? { get set }
    var onAvailabilityChanged: (@MainActor (_ serverId: String) -> Void)? { get set }
}

public enum ACPPeerError: Error, Equatable { case unreachable(peer: String), refused(String), notFound, outdated(peer: String), revoked(peer: String) }
```

  - `Environment.delegationPeers: () -> ACPDelegationPeers?` on the coordinator
- Produces in `AlasHostCore`: `PeerDelegationClient(links: FederatedPeerLinks, channel: @MainActor (String) -> PeerHostChannel?)`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func outdatedPeerIsNotSentARequest() async { /* no capability: .outdated; fake channel sent nothing */ }
@Test func unverifiedOrOfflinePeerIsUnreachable() async { /* absent from sessionCarryingPeers: .unreachable */ }
@Test(arguments: [(HostResponse.failure(error: .session(refusal: .notFound)), ACPPeerError.notFound)])
func mapsHostFailures(response: HostResponse, error: ACPPeerError) async { /* also unanswered → .unreachable, other refusal → .refused */ }
```

- [ ] **Step 2: Run to confirm failure.** `CORE PeerDelegationClientTests`. Expected: FAIL to compile.
- [ ] **Step 3: Implement.** `start` uses a 60-second timeout, which is enough because it answers once the row exists. `NativePeerHosts.makeChannel` sets `onDelegationOutboxChanged` and adds `delegationOutboxChanged` to the kinds in `PeerHostChannel.connect()`. `AppState+PeerHosts` installs the client on the core context.
- [ ] **Step 4: Run to confirm passing.** Same command, then the build. Expected: PASS and a clean build.
- [ ] **Step 5: Commit.** `feat(remote): add a client for delegating to peers`

### Task 8: `peer` on the tools

**Files:**
- Modify: `AlasCLI/crates/alas/src/parse.rs`, `mcp.rs`, `AlasCLI/crates/alas-client/src/lib.rs`, `Packages/AlasCore/Sources/AlasAgentKit/Harness/AlasCLIRequest.swift`, `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCLICommandRouter.swift`, `AlasHost+Delegation.swift`, `Packages/AlasCore/Sources/AlasModel/Model/ACPOrchestrationModels.swift`, coordinator
- Test: Rust tests in those crates, `AlasTests/AlasCLIRequestTests.swift`, coordinator suite

**Interfaces:**
- Consumes: Task 7.
- Produces:
  - JSON params `peer: String?` and `project: String?` on `session_new`, and `peer` on `agent_list`
  - `Command.agentList(worktree:peer:)`, `Command.sessionNew(… peer:project:)`
  - `ACPDelegatedSessionNewRequest.peer: String?`, `.project: String?`
  - `ACPOrchestrationDiscoveryResponse.peers: [ACPOrchestrationPeer]?`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func sessionNewDecodesPeerAndProject() throws { /* peer "mini", project "alas", new_worktree */ }
@Test func peerWithImplicitWorktreeIsAnError() async { /* coordinator: error saying to pass --worktree or --new-worktree; no request sent */ }
@Test func ambiguousPeerNameListsServerIds() async { /* two peers named "mini": error includes both ids */ }
@Test func unknownPeerListsPeers() async { /* … */ }
@Test func agentListAddsPeersWithoutCallingThem() async { /* peers array present; fake saw no discover */ }
@Test func agentListForPeerSendsParentOriginAsRepository() async { /* fake.discover received "github.com/o/r" */ }
@Test func multipleMatchingProjectsRequireProject() async { /* error names both */ }
```

Also a Rust test: `alas session new --peer mini --project alas --new-worktree b --prompt p` parses and serializes `peer` and `project`, and the MCP schema lists both.

- [ ] **Step 2: Run to confirm failure.** `RUST`, `APP AlasCLIRequestTests`, `APP ACPSessionOrchestrationCoordinatorTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the parsing and routing. `peer` matches on server id first, then exact name. Delegated callers are refused as today, before the peer is contacted.
- [ ] **Step 4: Run to confirm passing.** Same commands. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(cli): add a peer option to agent and session commands`

### Task 9: Coordinator: acting on peer children

**Files:**
- Modify: coordinator, `AlasCoreContext+DelegationRecovery.swift`
- Test: `AlasTests/ACP/Orchestration/ACPSessionOrchestrationCoordinatorTests.swift`

**Interfaces:**
- Consumes: Tasks 7 and 8, and `ACPDelegationRecord.peerServerId`.
- Produces: `create`, `send`, `list`, `read`, `wait`, `interrupt`, `readableSession` and `storedTurnState` handle records with `peerServerId`. Wait JSON state gains `peer_unreachable`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func createWritesRecordBeforeSending() async { /* fake.start sees the record already stored with the same childID */ }
@Test func refusedStartFailsRecordAndReturnsReason() async { /* response error; phase .failed; parent not separately woken */ }
@Test func lostStartAnswerIsRetriedOnceWithSameID() async { /* unreachable once: second call same id; second failure → fails with reason */ }
@Test func sendReadInterruptGoToThePeer() async { /* fake records each */ }
@Test func listShowsPeerName() async { /* session_list row carries the peer */ }
@Test func waitReportsChildStateFromStatus() async { /* settled from peer's JSON; re-asks on onOutboxChanged, deadline honoured with an injected clock */ }
@Test func siblingAndGrandchildRulesStillApply() async { /* other parent's peer child unreachable from caller */ }
@Test func recoverySkipsPeerRows() async { /* recoverDelegations leaves phase unchanged */ }
```

- [ ] **Step 2: Run to confirm failure.** `APP ACPSessionOrchestrationCoordinatorTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Branch on `peerServerId` first in each path. The record uses `worktreeRequest = .current(origin.worktreeId)`, `childWorktreeId = nil`. `create` reads `parentSession.autoRunEnabled` for `autoRun`. The retry is one further attempt, on the source's next subscribe when the link is down.
- [ ] **Step 4: Run to confirm passing.** Same command. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(acp): delegate sessions to paired peers`

### Task 10: Collecting outcomes

**Files:**
- Create: `Packages/AlasCore/Sources/AlasAgents/ACP/Orchestration/ACPPeerOutboxCollector.swift`
- Modify: `AlasCoreContext.swift` or `AlasCoreContext+Orchestration.swift` for wiring
- Test: `AlasTests/ACP/Orchestration/ACPSessionOrchestrationCoordinatorTests.swift`

**Interfaces:**
- Consumes: Task 1's `collectPeerEntry` and `peerCursor`, Task 7's `outbox`, `onOutboxChanged` and `onAvailabilityChanged`.
- Produces: `@MainActor final class ACPPeerOutboxCollector { init(peers:persistence:deliver:); func start(); func collect(serverId: String) async }`, with at most one pull per peer running at a time and one queued behind it.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func availabilityTriggersCollectFromStoredCursor() async { /* cursor 5: fake.outbox after == 5 */ }
@Test func entriesDeliverInOrderOncePerEntry() async {
    // Three accumulated entries over two pages arrive at the parent in order,
    // and a repeated collect wakes nobody.
}
@Test func twoCollectorsOnOneStoreWakeOnce() async { /* two instances, same store: one inbox row; the parent's tab closed still attaches through the existing path */ }
@Test func entryForUnknownChildIsSkippedAndAdvancesCursor() async { /* a human-forgotten row does not block the queue */ }
@Test func noticeEntryDoesNotWakeParent() async { /* kind .notice stays a notice */ }
```

- [ ] **Step 2: Run to confirm failure.** `APP ACPSessionOrchestrationCoordinatorTests`. Expected: FAIL to compile.
- [ ] **Step 3: Implement.** For each entry: look up the record by `childSessionId`, call `collectPeerEntry` with its parent, then call the coordinator's existing `deliverPendingMessages` for that parent. Continue while `hasMore`, passing the last `seq` as `after`, which also acknowledges. The next pull acknowledges the final page.
- [ ] **Step 4: Run to confirm passing.** Same command. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(acp): wake parents with results from peers`

---

# PR 3: Resilience

### Task 11: Unreachable and gone

**Files:**
- Modify: coordinator, `ACPPeerOutboxCollector.swift`, `Packages/AlasCore/Sources/AlasHostCore/Remote/Peer/PeerDelegationClient.swift`, `RemotePeerManager.swift` for the forget signal
- Test: coordinator suite

**Interfaces:**
- Consumes: `ACPPeerError`.
- Produces: `coordinator.peerAvailabilityChanged(serverId:)`; `Environment.peerOfflineNoticeDelay: TimeInterval`, default `900`; message id `peer-offline-<serverId>-<child>-<lastSeenOnlineAt>`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func waitReportsUnreachableAsSettled() async { /* state peer_unreachable, settled true */ }
@Test func sendReadInterruptNameThePeerWhenDown() async { /* error mentions "mini" */ }
@Test func offlineNoticeIsOneNoticeAfterDelayForUnsettledChildren() async { /* injected scheduler: one notice; settled children none */ }
@Test func returningPeerDeliversWhatEndedMeanwhile() async { /* no failure; outcome arrives */ }
@Test func notFoundFailsChildWithWake() async { /* status .notFound */ }
@Test(arguments: [ACPPeerError.revoked(peer: "mini")])
func revocationFailsUnfinishedChildren(error: ACPPeerError) async { /* unfinished fail; finished untouched */ }
@Test func forgettingPeerFailsChildrenAndDeletesCursor() async { /* … */ }
@Test func staleOutageNeverFailsAChild() async { /* three days unreachable: phase remains .ready */ }
```

- [ ] **Step 2: Run to confirm failure.** `APP ACPSessionOrchestrationCoordinatorTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Map `RemotePeerManager`'s `.unauthorized` state and `forget` to `.revoked`. Target side: forgetting a peer calls `deleteOutbox`. Use the existing `scheduleEscalationCheck` style for the delay, with its re-check against live state.
- [ ] **Step 4: Run to confirm passing.** Same command. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(acp): tell outages apart from lost peer children`

### Task 12: Stale-code preflight

**Files:**
- Create: `Packages/AlasCore/Sources/AlasAgents/ACP/Orchestration/ACPPeerBasePreflight.swift`
- Modify: coordinator, `AlasCoreContext+Orchestration.swift` for `Environment.branchState`
- Test: coordinator suite, as pure-decision tests

**Interfaces:**
- Produces:
  - `struct ACPPeerBranchState { isClean: Bool; head: String; branch: String?; upstream: String?; upstreamHead: String?; upstreamOnOrigin: Bool }`
  - `enum ACPPeerBasePreflight { static func decide(explicitBase: String?, state: ACPPeerBranchState?) -> Decision }`, with `Decision` being `.useBase(String, expectedSHA: String?)` or `.refuse(String)`
  - `Environment.branchState: (Worktree) async -> ACPPeerBranchState?`

- [ ] **Step 1: Write the failing test**

```swift
@Test(arguments: [
    (dirty, "push"), (ahead, "push"), (noUpstream, "push"), (detached, "--base"), (upstreamOnFork, "--base"),
])
func notSafeToInferIsRefused(state: ACPPeerBranchState, mentions: String) { /* … */ }
@Test func cleanPushedBranchSendsBareNameAndSHA() { /* .useBase("fix/x", expectedSHA: head) */ }
@Test func explicitBaseSkipsChecks() { /* dirty state: .useBase("main", expectedSHA: nil) */ }
```

- [ ] **Step 2: Run to confirm failure.** `APP ACPSessionOrchestrationCoordinatorTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the pure function and call it in `create` for `.new` with a peer. `branchState` uses `GitService`, so it follows the project's host.
- [ ] **Step 4: Run to confirm passing.** Same command. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(acp): refuse to delegate from unpushed code`

---

# PR 4: Surface

### Task 13: Source UI, preamble and docs

**Files:**
- Modify: delegated child row and report-card views in `Alas/Sources/ACP/UI/`, `Alas/Sources/Remote/Native/NativePeerWorkspace.swift`, `Packages/AlasCore/Sources/AlasAgentKit/Harness/NotificationService.swift`, `ACPMCPPromptPreamble.swift`, `docs/agent-delegation.md`, `docs/headless-host.md`, `docs/manual-test.md`
- Test: `AlasTests/ACP/Session/ACPMCPPromptPreambleTests.swift`

**Interfaces:**
- Consumes: Task 8's peer list.
- Produces: preamble builder parameter `delegationPeerNames: [String]`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func rootPreambleMentionsPeersOnlyWhenOneCanBeUsed() { /* [] : no "peer"; ["mini"]: names it and --peer */ }
@Test func delegatedPreambleNeverMentionsPeers() { /* … */ }
```

- [ ] **Step 2: Run to confirm failure.** `APP ACPMCPPromptPreambleTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the preamble change. Show the child as a row "on <Mac>", which opens `NativePeerSessionView` for that session, using the peer view's existing navigation. A blocked child's notice also posts a `notifyPeerNotice` notification that opens it.
- [ ] **Step 4: Update docs.** In `docs/agent-delegation.md`, add "Delegating to another machine": the options, the JSON additions, `peer_unreachable`, and the final-message rule. In `docs/headless-host.md`, add `alas-host peers agents`. In `docs/manual-test.md`, add the scenarios in the spec's Testing section.
- [ ] **Step 5: Run to confirm passing,** then build. Expected: PASS and a clean build.
- [ ] **Step 6: Commit.** `feat(acp): show peer children and explain them to agents`

---

# PR 5: Headless hosts as sources

### Task 14: Move channel ownership into core

**Files:**
- Create: `Packages/AlasCore/Sources/AlasHostCore/Remote/Peer/PeerHostChannels.swift`
- Modify: `Alas/Sources/Remote/Native/NativePeerHosts.swift`, `Alas/Sources/App/AppState+PeerHosts.swift`, `PeerDelegationClient.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/PeerDelegationClientTests.swift`

**Interfaces:**
- Consumes: `PeerHostChannel`, `RemotePeerManager.onHostMessage`.
- Produces:

```swift
@MainActor public final class PeerHostChannels {
    public init(links: RemotePeerManager, timeout: Duration)
    public func channel(for serverId: String) -> PeerHostChannel?
    public func peersChanged(online: Set<String>)    // moved from NativePeerHosts
    public var onChannelMade: (@MainActor (String, PeerHostChannel) -> Void)?
    public var onChannelChanged: (@MainActor (String) -> Void)?
}
```

- [ ] **Step 1: Write the failing test.** `channelsReconcileWithOnlinePeers`: a peer going offline disconnects and drops its channel; one with `host.events.v1` going online connects; one without gets none.
- [ ] **Step 2: Run to confirm failure.** `CORE PeerDelegationClientTests`. Expected: FAIL to compile.
- [ ] **Step 3: Implement.** Move only channel creation, lookup and reconciliation. `NativePeerHosts` keeps its derived state, moving what `makeChannel`'s `onChange` does to `onChannelMade`. `PeerDelegationClient` takes `PeerHostChannels`.
- [ ] **Step 4: Run existing peer suites to confirm no change.** `APP RemotePeerManagerTests`, `APP RemoteFederationAggregationTests`, any `NativePeerHosts` suite found with `git grep -l NativePeerHosts AlasTests`, then build. Expected: PASS.
- [ ] **Step 5: Commit.** `refactor(remote): own peer host channels in core`

### Task 15: Activate outbound links on the host

**Files:**
- Modify: `Packages/AlasCore/Sources/alas-host/main.swift`, `Commands.swift`, `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocol.swift`, `HostProtocolServer.swift`, `docs/headless-host.md`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/HostProtocolServerTests.swift`, `HeadlessCLIRouterTests.swift`

**Interfaces:**
- Consumes: Task 14, Task 10's collector, `RemotePeerManager.addPeer(link:)`.
- Produces: `HostRequest.addPeer(link: String)`, local client only, and `alas-host peers add <pairing-link>`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func addPeerRefusesRemoteCaller() async { /* .remotePeer: refused */ }
@Test func headlessAgentListIncludesOutboundPeers() async { /* HeadlessCLIRouter with a fake peer */ }
@Test func inboundOnlyPeerIsNotOfferedAsATarget() async { /* empty token: absent from delegation peers */ }
```

- [ ] **Step 2: Run to confirm failure.** `CORE HostProtocolServerTests` and `CORE HeadlessCLIRouterTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** In `main.swift`, when Remote serves, call `peers.connectAll()`, skipping records with an empty token, and `peers.disconnectAll()` on shutdown, as the manager's doc comment requires. Build `PeerHostChannels`, wire `onHostMessage`, install `PeerDelegationClient` and start the collector. `addPeer` on the host records the outbound link only; `pairsBackWithPeers = false` stays. A running host adds through the running process, like `peers remove`, and the target Mac needs Remote on and reachable, for example over Tailscale or the LAN.
- [ ] **Step 4: Update docs.** In `docs/headless-host.md`, describe host-to-Mac delegation, `alas-host peers add`, and the requirement that the Mac can be reached.
- [ ] **Step 5: Run to confirm passing,** with `swift test --package-path Packages/AlasCore`. Expected: PASS.
- [ ] **Step 6: Commit.** `feat(alas-host): delegate from a headless host to its peers`

## Not in this plan

- Reaching a Mac the source cannot dial. It needs requests sent back over the Mac's own connection, and its own design. Tailscale or a LAN covers the common cases through Task 15.
- A scoped agent credential, link expiry, and `session_search` across peers.
