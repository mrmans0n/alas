# Headless Host as a Mac Peer (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Mac app pairs with a headless `alas-host` as a normal peer and opens, drives and creates its sessions, with no app-side change.

**Architecture:** `alas-host` gains:
- the pieces `AppState` gives the app's Remote server: an identity signer, a `RemotePeerManager` that does the reciprocal pair-back, and a `RemoteSessionPresenter`;
- a persisted open-session list in place of the tab strip;
- per-server hello capabilities, so it stops claiming consoles;
- session managers loaded at boot, so stored sessions are listed.

The host never connects out to peers: `connectAll()` is never called.

**Tech Stack:** Swift 6, SwiftPM package `Packages/AlasCore` (modules AlasHostCore, AlasModel, AlasAgents), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-22-headless-host-peer-design.md`

## Global Constraints

- Core code must not import SwiftUI, AppKit, WebKit, GhosttyKit, MLX, TreeSitterPack or FffC. Anything the app or tests use from the package must be `public`.
- Tests use Swift Testing (`import Testing`). Follow the AGENTS.md testing policy:
  - one behavior per test, `@Test(arguments:)` for variants;
  - no fixed `Task.sleep`;
  - git stays real;
  - extend existing suites before creating files.
- Commit titles follow Conventional Commits. **No `Co-Authored-By` trailers or other agent attribution** (AGENTS.md overrides any harness reminder).
- No change to `Alas/` (the app) is needed. If one becomes unavoidable, stop and record a ruling.
- Pairing codes are minted only for a `.localUser` caller. No unverified peer may carry sessions.
- The host never deletes a secret copy it did not write.
- The open-session list is the host's own file, separate from the app's tab files.
- Package tests: `swift test --package-path Packages/AlasCore --filter <Suite>`. Before any `AlasHostExecutableTests` run, `touch Packages/AlasCore/Sources/alas-host/main.swift`, or a stale incremental binary is tested.

## Review Focus

1. **A host restart keeps the identity:** the same public key after a restart, so a paired laptop still verifies the mini. Pinned in Task 2.
2. **Opening a session whose worktree or row is gone:** a failure message, never a crash, and no list entry. Pinned in Task 3.
3. **An open list that points at a session archived or deleted while the host was down:** dropped on restore, not listed as a ghost tab. Pinned in Task 3.
4. **Open and close of one session racing from two clients:** serialized, and the final state matches the last request. Pinned in Task 3.
5. **`alas-host pair` on a loopback-only host:** the link still prints, plus a stderr note that only this Mac or a tunnel reaches it. Covered in Task 6.

---

### Task 1: Per-server hello capabilities

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteProtocol.swift` (`RemoteServerMessage.hello`, ~line 1399)
- Modify: the `RemoteServerIdentity` declaration (grep `struct RemoteServerIdentity`)
- Test: the existing package suite that covers `RemoteServerMessage.hello` or the hello encoding (grep the Tests dir for `.hello(`). Add there.

**Interfaces:**
- Produces: `RemoteServerIdentity.servesPeerConsoles: Bool`, an init parameter that defaults to `true`. When it is false, `hello(_:)` omits `PeerConsoleCapability.v1` and `PeerConsoleCapability.terminateV1` and keeps `PeerSessionTabsCapability.v1` and `HostProtocolCapability.served`.

- [ ] **Step 1: Write the failing test.** `@Test func helloOmitsConsoleCapabilitiesForAServerWithoutConsoles()`:
  - Build `.hello(RemoteServerIdentity(serverId: "s", name: "n", servesPeerConsoles: false))` and extract `capabilities`.
  - `#expect(!caps.contains(PeerConsoleCapability.v1))`
  - `#expect(!caps.contains(PeerConsoleCapability.terminateV1))`
  - `#expect(caps.contains(PeerSessionTabsCapability.v1))`
- [ ] **Step 2: Run it.** Expected: FAIL to compile (no `servesPeerConsoles`).
- [ ] **Step 3: Implement.** Add the property and branch on it in `hello`.
- [ ] **Step 4: Run the suite.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(remote): let a server leave peer consoles out of its hello`

### Task 2: Host secret store that never deletes a copy

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasModel/Persistence/RemoteSecretStore.swift`
- Test: the existing suite for `RemoteKeychainSecretStore` / `RemoteFileSecretStore` (grep Tests for `RemoteFileSecretStore`). Add there.

**Interfaces:**
- Produces: `public final class RemoteHostSecretStore: RemoteSecretStore, Sendable` with `public init(reading: any RemoteSecretStore = RemoteKeychainSecretStore(fallback: RemoteFileSecretStore()), writing: any RemoteSecretStore = RemoteFileSecretStore())`.
  - `secret(for:)` returns `reading.secret(for:)`.
  - `setSecret(_:for:)` forwards only to `writing`.
  - The doc comment states why: an app and a host taking turns on one profile must keep the same key, and the Keychain store deletes the file copy on write.

- [ ] **Step 1: Write the failing tests.** Use in-memory fakes (a dictionary-backed `RemoteSecretStore` in the test file, unless the suite already has one).
  - `@Test func readsThroughButWritesOnlyTheWritingStore()`:
    1. Seed reading with `"k" → A` and set `"k" → B`.
    2. Expect reading still holds A and writing holds B.
  - `@Test func anIdentityKeyStaysTheSameAcrossProviders()`:
    1. Two `RemoteIdentityKeyProvider(store:)` over two `RemoteHostSecretStore`s that share the same fakes.
    2. Expect the same non-empty `publicKey`. This pins Review Focus 1.
- [ ] **Step 2: Run them.** Expected: FAIL to compile.
- [ ] **Step 3: Implement** `RemoteHostSecretStore`.
- [ ] **Step 4: Run the suite.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(remote): add a secret store for the headless host that never deletes a copy`

### Task 3: Headless session presenter with a persisted open list

**Files:**
- Create: `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/HeadlessSessionPresenter.swift`
- Modify: `Packages/AlasCore/Sources/AlasModel/Persistence/Paths.swift`. Add `public static var hostOpenSessionsFile: URL`, the profile's `host-open-sessions.json`, next to the other profile files.
- Test: create `Packages/AlasCore/Tests/AlasHostCoreTests/HeadlessSessionPresenterTests.swift`. It's a new type with no existing suite. Match the Tests folder layout the package uses.

**Interfaces:**
- Consumes:
  - `RemoteSessionPresenter` (`AlasHostCore/Remote/Gateway/RemoteSessionPresenter.swift`);
  - `AlasCoreContext.sessionManagers`, `sessionManager(for: Worktree)`, `projectAndWorktree(withWorktreeId:)`;
  - `ACPSessionManager.flushPersistence()`, `persistence.loadSession(id:)`, `sessionRows`, `liveSession(for:)`;
  - `ChangeSignal<Void>`.
- Produces: `@MainActor public final class HeadlessSessionPresenter: RemoteSessionPresenter` with:
  - `public init(core: AlasCoreContext, store: any PersistenceStoreProtocol = PersistenceStore(), fileURL: URL = Paths.hostOpenSessionsFile)`
  - `public func restore() async`: loads the file, creates the manager of each owner that is still a configured local worktree, and drops entries whose stored row is missing or archived. It saves if anything was dropped.
  - Protocol members:
    - `sessionTabIndex`: the index in that owner's list;
    - `sessionListChanges`: a `ChangeSignal`;
    - `peerConsoleHost`: nil;
    - `openSessionTab`, `closeSessionTab`;
    - `sessionRenamed`: no-op;
    - `sessionCreated(_:worktreeID:)`: appends, saves, signals.
- File format (your call, keep it small): `struct HostOpenSessionsFile: Codable { var sessions: [String: [String]] }`, keyed by `SessionOwnerID.storageKey`. Only `.worktree` owners in phase 1.

Behavior, mirroring `AppState.openSessionTabNow` and `closeSessionTabNow` (`Alas/Sources/App/AppState.swift:14399-14480`):
- **Open:**
  1. Find the owner whose manager lists the id, else search the configured local worktrees' stored rows.
  2. Return success if already open.
  3. `flushPersistence()`, then `loadSession(id:)`. Return `.failure("This session is no longer available.")` when it's missing and `.failure("This session is archived.")` when archived. Return `.failure("This session's worktree is no longer available.")` when the worktree is gone.
  4. Append, save, signal.
- **Close:** remove, save, signal. Success when not open. Dispose the session's runner as the app's close does (`ACPSessionManager` close or teardown API; find what `closeTabRecordingHistory` calls for an ACP tab), keeping the row in history.
- Actions for one id run one at a time. Copy the `serializedSessionTabAction` pattern.

- [ ] **Step 1: Write the failing tests.** Use a real `AlasCoreContext` over a temp profile, with one worktree from the shared git template fixture and a stored session row. Reuse the fixtures other AlasHostCore tests use to build a core with a worktree and session rows.
  - `openAppendsAndIsIdempotent`: open twice; expect `.success` both times and `sessionTabIndex == 0`.
  - `closeRemovesButKeepsHistory`: after close, index is nil and the row is still in `sessionRows`, unarchived.
  - `@Test(arguments:) openRefusesWhatCannotBeOpened`: missing id or archived row; expect `.failure` and index nil (Review Focus 2).
  - `restoreReloadsOpenSessionsAndDropsStaleOnes`:
    1. Open a and b, then archive b directly in persistence.
    2. Build a new presenter over the same file and `restore()`.
    3. Expect a at index 0, b absent, and the file rewritten (Review Focus 3).
  - `racingOpenAndCloseEndInTheLastRequestsState`: start `open` then `close` without awaiting between; await both; expect index nil (Review Focus 4).
  - `sessionCreatedOpensTheSession`: `sessionCreated(id, worktreeID:)` gives index 0 and fires `sessionListChanges`.
- [ ] **Step 2: Run them.** Expected: FAIL to compile.
- [ ] **Step 3: Implement** the presenter and the `Paths` entry.
- [ ] **Step 4: Run.** `swift test --package-path Packages/AlasCore --filter HeadlessSessionPresenterTests`. Expected: all PASS; check the "Test run with N tests" line.
- [ ] **Step 5: Commit.** `feat(host): keep a headless list of open sessions for paired clients`

### Task 4: List stored sessions at boot; remember advertised models

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext.swift`. Add `loadStoredSessionManagers()`, and give `sessionManagerFactory` an `onChipsObserved` parameter.
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost.swift`. `loadProjectWorktrees()` calls it after the refresh.
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHostEnvironment.swift`. `HeadlessHostEnvironment` gets `public let modelCatalog: ACPAgentModelCatalog?`, created in `init` as `ACPAgentModelCatalog()`, so it persists to `Paths.acpModelCatalogFile`.
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost+Boot.swift`. Pass `onChipsObserved` to record into `environment.modelCatalog`, as `AppState.recordObservedChips` does (`record(agentID:models:host:)` plus `recordEffort(agentID:thinking:)`).
- Test: the existing suite that covers `loadProjectWorktrees` / `AlasCoreContext` session managers (grep Tests for `loadProjectWorktrees` or `remoteSessionSummaries`).

**Interfaces:**
- Produces:
  - `public func loadStoredSessionManagers() async` on `AlasCoreContext`. For every visible worktree of a local project (`project.host == nil`) whose `Paths.acpSessionsDB(for: .worktree(id))` file exists, it calls `sessionManager(for:)` and then `await refreshRecentNow()`.
  - `sessionManagerFactory(config:onChipsObserved:)`, with `onChipsObserved: (@MainActor (String, String?, ACPChipState) -> Void)? = nil` forwarded to `ACPSessionManager`'s `onChipsObserved:`.

- [ ] **Step 1: Write the failing test.** `storedSessionsAreListedWithoutOpeningThem`:
  1. Use a temp profile with one worktree and a stored session row written through `ACPSessionPersistence` at `Paths.acpSessionsDB`.
  2. On a fresh core, `await loadStoredSessionManagers()`.
  3. Expect `remoteSessionSummaries(tabIndex: { _, _ in nil })` to contain the row's id.
- [ ] **Step 2: Run it.** Expected: FAIL.
- [ ] **Step 3: Implement**, including the model-catalog wiring. The wiring only forwards to the already-tested catalog, so per policy it gets no test of its own.
- [ ] **Step 4: Run the suite.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(host): list stored sessions at boot and remember the models agents advertise`

### Task 5: `alas-host peers list|remove`

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocol.swift`:
  - requests `case listPeers` and `case forgetPeer(peerID: String)`;
  - response `case peers(peers: [HostPeerSummary])`;
  - `public struct HostPeerSummary: Codable, Equatable, Sendable { id, serverId, name: String; origins: [String] }`.
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocolServer.swift`. Add `public var remotePeers: RemotePeerManager?`. Both requests are `.localUser` only, like `.remotePairingCode`; without a manager they fail with `"This host does not serve Mac peers."`. `forgetPeer` with an unknown id gives `HostError.notFound(what: "peer <id>")`.
- Modify: `Packages/AlasCore/Sources/alas-host/Commands.swift`:
  - add `"peers"` to the commands;
  - `peers list` prints `id  name  serverId` per line;
  - `peers remove <id|name|serverId>` resolves via list, then forgets.
  - Use `perform(_:decode:inProcess:)`. The in-process branch builds `RemotePeerManager(store: FilePeerStore(secrets: RemoteHostSecretStore()), pairing: RemotePairingService(store: FileDeviceStore()), localIdentity: { .init(serverId: "", name: "", origins: []) })` and calls `peers` / `forget(peerId:)`. The pairing service's revoke persists the device revocation.
- Modify: the `usage` text in `alas-host/main.swift`.
- Test: `HostProtocolServerTests`. Add one test.

**Interfaces:**
- Consumes: `RemoteHostSecretStore` (Task 2), `RemotePeerManager.peers`, `forget(peerId:)`.
- Produces: `HostProtocolServer.remotePeers`, used by Task 6.

- [ ] **Step 1: Write the failing test.** `@Test(arguments: [true, false]) forgettingAPeerRevokesItsDeviceOnlyForTheLocalUser(isLocalUser:)`:
  1. A server with a `RemotePeerManager` over an in-memory `RemotePeerStore` holding one peer, and a `RemotePairingService` holding its `.alasInstance` device.
  2. Send `.forgetPeer` as `.localUser` or as a paired device.
  3. Local user: the peer is gone and the device revoked. Otherwise: a failure, and both remain.
- [ ] **Step 2: Run it.** Expected: FAIL to compile.
- [ ] **Step 3: Implement** the protocol, the server and the commands.
- [ ] **Step 4: Run** `--filter HostProtocolServerTests`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(host): list and remove paired Macs from the command line`

### Task 6: Wire peers, identity, presenter and the pairing link into `alas-host`

**Files:**
- Modify: `Packages/AlasCore/Sources/alas-host/main.swift`, in the Remote block, ~lines 186-275:
  - `let secrets = RemoteHostSecretStore()`; `let identityKey = RemoteIdentityKeyProvider(store: secrets)`.
  - `RemoteServer(…, identity: { RemoteServerIdentity(serverId:…, name:…, servesPeerConsoles: false) }, signer: identityKey)`.
  - Remove `server.admitsPeers = false` and update the comment above the block, which today says there is no peer identity.
  - Create a `RemotePeerManager(store: FilePeerStore(secrets: secrets), pairing: pairing, localIdentity: { … })`:
    - `serverId` and `resolvedDisplayName` come from `settings`;
    - origins are the current advertised addresses minus `.localhost`, capped at `RemotePairingLink.maxOrigins`;
    - `publicKey` is `identityKey.publicKey`.
  - Set `onRevokeDevice = { server.disconnectDevice($0) }`.
  - `server.onPeerPaired`: copy `AppState.swift:913-921` (`notePeerPairingArrived`, then `Task { await handleInboundPeer }`).
  - `let presenter = HeadlessSessionPresenter(core: host.core)` (or whatever exposes the core). Keep a strong reference, since `server.presenter` is weak. Assign it, and `await presenter.restore()` after `loadProjectWorktrees()`.
  - `protocolServer.remotePeers = peers`.
  - Advertised addresses come from `settings.advertisedAddresses(port:interfaces:tailnetHTTPSHost:loopbackOnly:)`. Pass the tailnet HTTPS host (`status.dnsName` when serve runs) once it is known, so both diagnostics and peer origins include it. Hold it in a `var` the closures read.
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocol.swift`. The response becomes `remotePairingCode(code: String, expiresAt: Date, link: String?)`. Decoding must accept an older host's response without `link`.
- Modify: `HostProtocolServer.swift`. Add `public var remotePairingLink: (@MainActor (String) -> String?)?`, which `.remotePairingCode` uses to fill `link`. `main.swift` sets it in `onPortChange` to `RemotePairingLink.build(base: <best non-loopback address URL, else http://127.0.0.1:port>, code:, addresses: <advertised>)`.
- Modify: the `pair` branch of `main.swift`:
  - stdout line 1 is the code, unchanged for scripts;
  - stdout line 2 is the link when present;
  - stderr carries the validity line, plus `Reachable only from this Mac or a tunnel; set host.reachability to lan or tailscale for other Macs.` when every address is loopback (Review Focus 5).
- Test: `AlasHostExecutableTests`. Add one test.

**Interfaces:**
- Consumes: Tasks 1, 2, 3, 5.

- [ ] **Step 1: Write the failing test.** `aMacCanPairWithTheHostAndProveItsIdentity`:
  1. Start `alas-host` on a temp profile with `host.reachability` `lan` and a free port, as the existing executable tests boot it.
  2. Run `alas-host pair`. Expect two stdout lines, with line 2 parsing through `RemotePairingLink.parse` to the same code.
  3. Call `RemotePeerPairer.live.pair(...)` with that code, a `RemotePeerAdvertisement` for a fake Mac (origins pointing at a closed local port, so the pair-back fails harmlessly), and a fresh challenge.
  4. Expect success with a non-empty `publicKey` whose signature verified, not `identityUnproven`.
  5. Restart the host and fetch `/pair`'s identity again (or the hello over WebSocket if simpler). Expect the same `publicKey` (Review Focus 1, end to end).
- [ ] **Step 2: Run it.** `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter AlasHostExecutableTests/aMacCanPairWithTheHostAndProveItsIdentity`. Expected: FAIL (403 peer rejected).
- [ ] **Step 3: Implement** the wiring above.
- [ ] **Step 4: Run** the whole `AlasHostExecutableTests` and `HostProtocolServerTests`. Expected: PASS. Then run `swift test --package-path Packages/AlasCore` once. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(host): pair with Macs as a peer and serve them its sessions`

### Task 7: Docs

**Files:**
- Modify: `docs/headless-host.md`.

- [ ] **Step 1: Edit.**
  - Replace "Other Macs cannot pair…" with a "Pair a Mac" subsection: run `alas-host pair` on the mini, paste the link into the app's Remote > Peers > Add Peer, keep the laptop's Remote on, and have it reachable from the host (same LAN or tailnet).
  - Document `alas-host peers list` / `peers remove`.
  - Note that sessions opened from a Mac stay open for every client and survive a host restart.
  - In "What it does not do yet", say that terminals come later and that run scripts and worktree deletion can't be controlled from a Mac's peer view yet.
- [ ] **Step 2: Commit.** `docs: pairing a Mac with a headless host`. Docs-only: no build.
