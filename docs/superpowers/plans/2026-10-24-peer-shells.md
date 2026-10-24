# Peer Shells (Phase 3, part 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** From a Mac's peer view, "New Terminal" on a host worktree opens a login shell there, already attached and under the requester's control. A headless `alas-host` serves it through zmx, and a Mac running the app serves it as a hidden tab.

**Architecture:** The console protocol gains `open` and `resize` requests, `opened` and `openFailed` events, and the capabilities `peerConsoleOpen.v1` and `peerConsoleResize.v1`. `RemoteServerIdentity` now carries the console capabilities it advertises instead of a Bool. `PeerConsoleHost` runs the requests through two optional environment closures. It waits until the new console's socket answers, then replies with a fresh `list` and `opened`. On the headless host, a new core type `HostConsoles` holds the persisted registry (`host-consoles.json`). It launches `zmx attach alashost-… <login shell> -l` with no TTY, sizes consoles with a one-shot zmx `Resize`, and builds the `PeerConsoleHost`. The app host opens a hidden, non-activating terminal tab. On the viewing Mac, `NativePeerConsoles` sends `open`, selects what opens and takes control. Its viewer asks a headless host to fit the pane.

**Tech Stack:** Swift 5.9+, SwiftUI/AppKit (app only), Swift Testing, SwiftPM package `Packages/AlasCore`, zmx (executed, never linked).

**Spec:** `docs/superpowers/specs/2026-10-24-peer-shells-design.md`

## Global Constraints

- Spec anti-goals, verbatim: "A peer must never take focus or change selection on a host user's screen." "No regression for older peers or hosts. New requests are capability-gated, and older decoders ignore what they don't know." "The app's orphan sweep must never kill host-created shells." "No UI imports in the core package. zmx is executed as a binary, never linked."
- Spec decision: "being paired is enough to open a shell. There is no extra host setting, matching agent sessions and run scripts."
- Spec decision: "Host-created zmx names use a prefix that does **not** start with `alas-` (e.g. `alashost-<wtHash>-<id>`)." "While the app runs on the profile, host shells stay alive but are not listed." "Shells opened as hidden app tabs belong to the app, and the host doesn't list them."
- Spec decision: "No `ALAS_*` CLI variables in host shells for now."
- Spec: "The shell is the user's login shell, in the worktree directory, with the same environment the host gives agents: login-shell PATH first, as `ACPProcessEnvironment.baseEnvironment`."
- Spec: "The registry is persisted in the profile (id, worktree, title, zmx name, size). On boot, entries whose zmx session is gone are dropped."
- Spec: "A Mac running the app keeps sizing its consoles from its own Ghostty grid, and ignores the request or refuses it cleanly."
- Spec: "If zmx isn't found, the host doesn't advertise the console capabilities, and the open request fails with a clear message."
- Spec non-goals: running scripts inside zmx; "Consoles for SSH-project worktrees on the host (remote zmx). They are refused with a clear reason."; web and phone clients.
- Spec: "Nobody can answer a privacy (TCC) prompt there, so shells in protected folders may fail silently. Document this."
- AGENTS.md: `Packages/AlasCore` "must not import SwiftUI, AppKit, WebKit, or anything the app builds outside SwiftPM … Anything the app or tests use from the package must be `public`."
- AGENTS.md: Swift Testing (`import Testing`), not XCTest. Extend the existing suite for the type under test before creating a file. One behavior per test; use `@Test(arguments:)` for variants. "Never synchronize with a fixed `Task.sleep`." "Git stays real." This plan touches no git.
- AGENTS.md: Conventional Commits (`type(scope): summary`). No `Co-Authored-By`, no generated-by footers, no agent attribution anywhere.
- AGENTS.md: code, comments, logs and UI strings in English.
- AGENTS.md: for `Packages/AlasCore` changes run `swift test --package-path Packages/AlasCore` (filtered to the touched suites) first. The app target and `AlasTests` can't be built on this machine, so CI gives them their first build and run. App-side tests are written here and verified in CI. Report exactly which local checks ran.
- No new app source files, so `xcodegen` is not needed. If an executor adds one anyway, regenerate the project and commit it with the file.

## Review Focus

1. **The installed zmx speaks the pre-freeze wire.** Verified on the real binary: `/Applications/Alas.app`'s zmx 0.8.1 ignores a v1-framed `Resize` and applies a pre-freeze one. Resize must probe the daemon's wire first. Test: Task 2 `resizeSpeaksTheDaemonsWire`.
2. **The app later runs on the profile.** Its orphan sweep, the Open Sessions list, "Kill idle orphans" and `ZmxPreFreezeMigration` must skip host shells. Test: Task 2 `hostShellNamesAreNeverAlasNames`.
3. **A resize that shouldn't apply.** It comes from a viewer that doesn't hold control, carries an absurd size, or goes to an app host with no `resize`. It changes nothing and broadcasts nothing. Test: Task 1 `resizeAppliesOnlyFromTheControlHolderWithinLimits`.
4. **An open whose shell never comes up.** The launcher fails, zmx is missing, or the app's tab never gets a reachable socket. The peer gets `openFailed` with the reason, and a half-opened console is closed rather than left behind as a hidden tab. Test: Task 1 `openThatNeverBecomesReachableFailsAndClosesIt`.
5. **A shell that exited.** If it exited while the host was down, restore drops it. If the user typed `exit` while the host runs, the next list drops it. Tests: Task 3 `restoreDropsShellsWhoseSessionIsGone`, `listDropsShellsWhoseSocketIsGone`.

---

### Task 1: Protocol and `PeerConsoleHost` open/resize

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Console/PeerConsoleProtocol.swift` (capabilities, request/event cases, `PeerConsoleOpenError`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Console/PeerConsoleHost.swift` (Environment, `handle`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteProtocol.swift:34-49,1428-1439` (`RemoteServerIdentity`, `hello`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/RemoteSessionGateway.swift:593-603` (`handleConsole` fallback)
- Modify: `Packages/AlasCore/Sources/alas-host/main.swift:280` (`consoleCapabilities: []`, until Task 4)
- Modify: `Alas/Sources/Remote/Native/PeerConsoleViewer.swift:403` (`case .inputAck, .list, .opened, .openFailed: break`)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/HostProtocolTests.swift:138-147`, `AlasTests/PeerConsoleHostTests.swift`, `AlasTests/Remote/RemoteProtocolTests.swift:72-79`

**Interfaces:**
- Produces:
  - `PeerConsoleCapability.openV1 = "peerConsoleOpen.v1"` and `.resizeV1 = "peerConsoleResize.v1"`. Add `static let appHost = [v1, terminateV1, openV1]` and `static let headlessHost = [v1, terminateV1, openV1, resizeV1]`.
  - `PeerConsoleRequest.open(requestId: String, worktreeId: String)` takes the host's worktree id (`Worktree.id`). `PeerConsoleRequest.resize(attachmentId: String, rows: Int, columns: Int)` is accepted only from the lease holder. Both are documented with their capability.
  - `PeerConsoleEvent.opened(requestId: String, consoleId: String)` is sent after a fresh `list`. `PeerConsoleEvent.openFailed(requestId: String, message: String)`. Both are sent only to a peer that sent `open`, so older decoders never see them. `attachmentId` is nil for both.
  - `public struct PeerConsoleOpenError: Error, Equatable, Sendable { public let message: String; public init(_ message: String) }`, with this exact copy:
    - `unsupported`: "This Mac can't open terminals for a peer."
    - `worktreeUnavailable`: "This worktree is no longer available on the host."
    - `sshProject`: "Terminals in SSH projects can't be opened from a peer."
    - `zmxMissing`: "zmx was not found next to alas-host or in /Applications/Alas.app, so this host can't open terminals."
    - `notStarted`: "The terminal did not start."
  - `PeerConsoleHost.Environment` adds three defaulted init parameters, after `terminate`:
    - `open: (@MainActor (_ worktreeId: String) async throws -> String)? = nil` returns the new console id and throws `PeerConsoleOpenError`.
    - `resize: (@MainActor (_ consoleId: String, _ rows: Int, _ columns: Int) async -> Bool)? = nil`. Nil means the host sizes its consoles itself.
    - `openReadyTimeout: Duration = .seconds(5)`.
  - `PeerConsoleHost.gridLimits: ClosedRange<Int> = 2...1000`.
  - `RemoteServerIdentity.init(serverId:name:peers:consoleCapabilities: [String] = PeerConsoleCapability.appHost)`. This replaces `servesPeerConsoles`. `hello` advertises `identity.consoleCapabilities + [PeerSessionTabsCapability.v1] + HostProtocolCapability.served`.

- [ ] **Step 1: Write the failing hello test.** In `HostProtocolTests`, replace `helloOmitsConsoleCapabilitiesForAServerWithoutConsoles`:

```swift
@Test(arguments: [[], PeerConsoleCapability.appHost, PeerConsoleCapability.headlessHost])
func helloAdvertisesExactlyTheConsoleCapabilitiesItServes(_ console: [String]) {
    guard case .hello(_, _, _, _, _, let caps) = RemoteServerMessage.hello(
        RemoteServerIdentity(serverId: "s", name: "n", consoleCapabilities: console)) else {
        Issue.record("expected hello")
        return
    }
    #expect(caps == console + [PeerSessionTabsCapability.v1] + HostProtocolCapability.served)
}
```

In `RemoteProtocolTests.helloAdvertisesPeerCapabilities`, expect `PeerConsoleCapability.appHost + [PeerSessionTabsCapability.v1] + HostProtocolCapability.served`.

- [ ] **Step 2: Write the failing host tests** in `AlasTests/PeerConsoleHostTests`. Give `Fixture` the members `var openResult: Result<String, PeerConsoleOpenError> = .success("c")`, `var resized: [String] = []` (formatted `"c 40x100"`), `var servesResize = true` and `var readyTimeout: Duration = .seconds(5)`, and wire them as `open`, `resize` (nil when `!servesResize`) and `openReadyTimeout`.

```swift
@Test func openRelistsThenNamesTheNewConsole() async throws {
    let fixture = Fixture()
    let peer = FakePeer()
    fixture.host.handle(.open(requestId: "r", worktreeId: "w"), from: peer.link)
    try await eventually("opened") { peer.events.all.count == 2 }
    #expect(peer.events.all == [.list(consoles: []), .opened(requestId: "r", consoleId: "c")])
}

@Test func openFailureCarriesTheHostsReason() async throws {
    let fixture = Fixture()
    fixture.openResult = .failure(.sshProject)
    let peer = FakePeer()
    fixture.host.handle(.open(requestId: "r", worktreeId: "w"), from: peer.link)
    try await eventually("failed") { !peer.events.all.isEmpty }
    #expect(peer.events.all == [.openFailed(requestId: "r", message: PeerConsoleOpenError.sshProject.message)])
}

@Test func openThatNeverBecomesReachableFailsAndClosesIt() async throws {
    let fixture = Fixture(daemon: .unreachable)
    fixture.readyTimeout = .zero
    let peer = FakePeer()
    fixture.host.handle(.open(requestId: "r", worktreeId: "w"), from: peer.link)
    try await eventually("failed") { !peer.events.all.isEmpty }
    #expect(peer.events.all == [.openFailed(requestId: "r", message: PeerConsoleOpenError.notStarted.message)])
    #expect(fixture.terminated == ["c"])
}

@Test func resizeAppliesOnlyFromTheControlHolderWithinLimits() async throws {
    let fixture = Fixture()
    let holder = FakePeer()
    let viewer = FakePeer()
    fixture.host.handle(.attach(consoleId: "c", attachmentId: "a", scrollbackRows: 0), from: holder.link)
    fixture.host.handle(.attach(consoleId: "c", attachmentId: "b", scrollbackRows: 0), from: viewer.link)
    fixture.host.handle(.resize(attachmentId: "a", rows: 40, columns: 100), from: holder.link)   // no lease yet
    fixture.host.handle(.takeControl(attachmentId: "a"), from: holder.link)
    fixture.host.handle(.resize(attachmentId: "b", rows: 40, columns: 100), from: viewer.link)   // not the holder
    fixture.host.handle(.resize(attachmentId: "a", rows: 0, columns: 100_000), from: holder.link) // out of limits
    fixture.host.handle(.resize(attachmentId: "a", rows: 40, columns: 100), from: holder.link)
    try await eventually("geometry") { viewer.events.all.contains(.geometry(attachmentId: "b", rows: 40, columns: 100)) }
    #expect(fixture.resized == ["c 40x100"])
    #expect(holder.events.all.contains(.geometry(attachmentId: "a", rows: 40, columns: 100)))
}

@Test func anAppHostIgnoresResize() {
    let fixture = Fixture()
    fixture.servesResize = false
    let peer = FakePeer()
    fixture.host.handle(.attach(consoleId: "c", attachmentId: "a", scrollbackRows: 0), from: peer.link)
    fixture.host.handle(.takeControl(attachmentId: "a"), from: peer.link)
    let before = peer.events.all
    fixture.host.handle(.resize(attachmentId: "a", rows: 40, columns: 100), from: peer.link)
    #expect(peer.events.all == before)
}
```

- [ ] **Step 3: Confirm the package test fails.** Run `swift test --package-path Packages/AlasCore --filter HostProtocolTests`. Expected: a compile FAIL on `consoleCapabilities` and `PeerConsoleCapability.appHost`.

- [ ] **Step 4: Implement the protocol, identity, host and gateway pieces** from the Interfaces block.
  - `handle(.open)`: when `environment.open` is nil, send `openFailed(… unsupported)`. Otherwise run a `Task`: open, then poll until the console is reachable. Reachable means `resolve(id)` is non-nil and `await BlockingWork.run { probe(path) } != .unreachable`. Poll every 100 ms until `openReadyTimeout` has passed, checking at least once. This is production polling, not a test sleep.
  - When the console is reachable, send `.list(consoles: environment.consoles())`, then `.opened`. When it is not, call `environment.terminate(id)` and send `openFailed(notStarted)`. A thrown `PeerConsoleOpenError` sends its message. Any other error sends `notStarted`.
  - `handle(.resize)`: require `environment.resize`, an attachment of this link, a lease held by that attachment, and both values in `gridLimits`. Then run a `Task` that calls `geometryChanged(consoleId:rows:columns:)` once `resize` returns true.
  - `RemoteSessionGateway.handleConsole`: with no console host, also answer `.open` with `openFailed(requestId, PeerConsoleOpenError.unsupported.message)`.
  - `Fixture` reads `servesResize` and `readyTimeout` when its lazy `host` is first built, so tests set them before touching `host`.

- [ ] **Step 5: Run the package checks.** Run `swift test --package-path Packages/AlasCore --filter HostProtocolTests`, expecting PASS, then `swift build --package-path Packages/AlasCore`, expecting a successful build. `PeerConsoleHostTests` and `RemoteProtocolTests` are CI's first run.

- [ ] **Step 6: Commit**

```bash
git add Packages/AlasCore Alas/Sources/Remote/Native/PeerConsoleViewer.swift AlasTests/PeerConsoleHostTests.swift AlasTests/Remote/RemoteProtocolTests.swift
git commit -m "feat(remote): add console open and resize requests"
```

---

### Task 2: Host shell primitives (naming, launch, resize, zmx lookup)

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasPlatform/Zmx/ZmxSessionName.swift` (`hostShell`)
- Modify: `Packages/AlasCore/Sources/AlasPlatform/Zmx/ZmxIPC.swift` (`ZmxIPCSocket.resize`)
- Modify: `Packages/AlasCore/Sources/AlasPlatform/Zmx/ZmxEnv.swift` (`resolve(binaryURL:…)`)
- Create: `Packages/AlasCore/Sources/AlasHostCore/Remote/Console/HostShellLaunch.swift`
- Test: create `Packages/AlasCore/Tests/AlasCoreTests/HostConsolesTests.swift` (the suite for Tasks 2–3; the package has no zmx suite), and extend `AlasTests/ZmxPassiveClientTests.swift` (`ZmxPassiveClientTests` and `ZmxPassiveClientIntegrationTests`)

**Interfaces:**
- Produces:
  - `ZmxSessionName.hostShell(worktreeId: String, consoleId: String) -> String` returns `"alashost-\(worktreeHash(worktreeId))-\(hash16(consoleId))"`. Its doc says it deliberately doesn't start with `alas-`.
  - `ZmxIPCSocket.resize(path: String, rows: Int, columns: Int) -> Bool` is blocking. It probes the wire with `probe(path:)` on its own connection, returning false for `.unreachable`. It then opens one new connection, writes `ZmxIPC.encode(.resize, ZmxIPC.sizePayload(rows:cols:), wire:)`, and shuts down. A `Resize` from a client while no leader is set makes that client leader and applies the size. Closing leaves the PTY size in place and clears leadership (`loop.zig` `handleResize` and `closeClient`).
  - `ZmxEnv.resolve(binaryURL: URL?, fileManager: = .default, processInfo: = .processInfo, runtimeDirectory: URL? = AlasProfile.current.runtimeDirectory) -> ZmxEnv`. The existing `resolve(bundle:…)` calls it with `resolveBinaryURL(bundle:fileManager:)`.
  - `public struct HostShellLaunch: Equatable, Sendable { executable: URL; arguments: [String]; environment: [String: String]; directory: URL }` with:
    - `static func make(zmx: ZmxClient, sessionName: String, directory: URL, shell: String, shellArguments: [String] = ["-l"], baseEnvironment: [String: String]) -> HostShellLaunch?`. It returns nil when `!zmx.isAvailable`. Executable and arguments come from `zmx.wrap(sessionName:plan:)`. The environment is `baseEnvironment` without `TERM`, `TERMINFO`, `TERMINFO_DIRS`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, `COLORTERM` and `ZMX_SESSION`, plus `TERM=xterm-256color`, `COLORTERM=truecolor` and `ZMX_DIR=<zmxDir>`.
    - `func run(timeout: TimeInterval = 10) async throws`. Use a plain `Process` with `currentDirectoryURL = directory` and stdin, stdout and stderr set to `FileHandle.nullDevice`. Wait on `terminationHandler` with a semaphore in `BlockingWork.run`. Throw `PeerConsoleOpenError.notStarted` on spawn failure, timeout (terminate it) or a non-zero exit.
    - `static func loginShell() -> String` tries `getpwuid(getuid()).pw_shell`, then `$SHELL`, then `/bin/zsh`.
    - `static func zmxBinary(executable: URL?, fallback: URL = URL(fileURLWithPath: "/Applications/Alas.app/Contents/Resources/zmx/zmx"), fileManager: FileManager = .default) -> URL?`. It returns the first executable file among `executable` with links resolved → `../zmx/zmx` (the layout of both `Alas.app/Contents/Resources` and the cask zip from Task 4) and `fallback`.

- [ ] **Step 1: Write the failing package tests** in the new `HostConsolesTests.swift` (`@MainActor struct HostConsolesTests`):

```swift
@Test func hostShellNamesAreNeverAlasNames() {
    let name = ZmxSessionName.hostShell(worktreeId: "/srv/feature", consoleId: "c")
    #expect(name.hasPrefix("alashost-"))
    #expect(!ZmxSessionName.isAlasName(name))      // sweeps, Open Sessions, pre-freeze migration
    #expect(ZmxSessionName.parseScoped(name) == nil)
}

@Test func aShellLaunchesInTheWorktreeWithTheAgentsPath() throws {
    let zmx = ZmxClient(env: ZmxEnv(binaryURL: URL(fileURLWithPath: "/opt/zmx"), zmxDir: URL(fileURLWithPath: "/tmp/z")))
    let base = ["PATH": "/login/bin:/usr/bin", "TERM": "dumb", "TERM_PROGRAM": "Apple_Terminal", "ZMX_SESSION": "outer", "HOME": "/Users/u"]
    let launch = try #require(HostShellLaunch.make(
        zmx: zmx, sessionName: "alashost-a-b", directory: URL(fileURLWithPath: "/srv/feature"),
        shell: "/bin/zsh", baseEnvironment: base))
    #expect(launch.executable.path == "/opt/zmx")
    #expect(launch.arguments == ["attach", "alashost-a-b", "/bin/zsh", "-l"])
    #expect(launch.directory.path == "/srv/feature")
    #expect(launch.environment == ["PATH": "/login/bin:/usr/bin", "HOME": "/Users/u", "TERM": "xterm-256color",
                                   "COLORTERM": "truecolor", "ZMX_DIR": "/tmp/z"])
}

@Test func zmxIsFoundBesideTheLinkedExecutableElseInTheApp() throws {
    // root/pkg/alas-host/alas-host + root/pkg/zmx/zmx, linked from root/bin/alas-host
    // (the Homebrew layout); a second tree without zmx and an executable fallback.
    #expect(HostShellLaunch.zmxBinary(executable: linked, fallback: missing) == pkgZmx)
    #expect(HostShellLaunch.zmxBinary(executable: bare, fallback: appZmx) == appZmx)
    #expect(HostShellLaunch.zmxBinary(executable: bare, fallback: missing) == nil)
}
```

The test builds the tree under a temp directory and removes it afterwards. Files are made executable with `posixPermissions: 0o755`, and the link uses `createSymbolicLink`.

- [ ] **Step 2: Confirm the package tests fail.** Run `swift test --package-path Packages/AlasCore --filter HostConsolesTests`. Expected: a compile FAIL (`hostShell`, `HostShellLaunch` undefined).

- [ ] **Step 3: Write the CI-only zmx tests** in `AlasTests/ZmxPassiveClientTests.swift`.
  - In `ZmxPassiveClientTests`, add `resizeSpeaksTheDaemonsWire(wire:)` with `@Test(arguments: [ZmxIPC.Wire.v1, .preFreeze])`. A `ZmxFakeDaemonListener` scripted `[.reply(zmxInfoReply(wire: wire)), .closeAfterReceiving(count: 16)]` answers the probe, then records the frame. Expect `ZmxIPCSocket.resize(path: listener.path, rows: 40, columns: 100) == true` and `listener.receivedPerConnection.last == ZmxIPC.encode(.resize, ZmxIPC.sizePayload(rows: 40, cols: 100), wire: wire)`.
  - In `ZmxPassiveClientIntegrationTests` (real bundled zmx, isolated short `/tmp` `ZMX_DIR`), add `aHostShellOutlivesItsLauncherAndTakesAOneShotResize`. Launch with `HostShellLaunch.make(…, shell: "/bin/bash", shellArguments: ["--noediting", "-i"], baseEnvironment: ProcessInfo.processInfo.environment)` and `try await launch.run()`. Then expect `ZmxIPCSocket.probe(path:timeout: .seconds(5)) != .unreachable`. Expect `ZmxIPCSocket.resize(path:rows: 40, columns: 100) == true`. Finally, with the file's `PassiveViewer`, `awaitSize("40 100", stage: "one-shot resize")`. Tear down with `client.killSession(name:)`.

- [ ] **Step 4: Implement** the Interfaces block. Reword the `sizePayload` doc ("Alas never sends either from a viewer") to "Viewers never send either; a host sizes its own shells with `ZmxIPCSocket.resize`". Add a `// ponytail:` note on `resize`: a client that leads after a direct `zmx attach` on the host makes zmx ignore the request, and an upgrade would detach that leader first.

- [ ] **Step 5: Run the package test.** Run `swift test --package-path Packages/AlasCore --filter HostConsolesTests`. Expected: PASS. The `AlasTests` additions are CI's first run.

- [ ] **Step 6: Commit**

```bash
git add Packages/AlasCore AlasTests/ZmxPassiveClientTests.swift
git commit -m "feat(host): launch and size zmx shells without a terminal"
```

---

### Task 3: `HostConsoles` registry and console host

**Files:**
- Create: `Packages/AlasCore/Sources/AlasHostCore/Remote/Console/HostConsoles.swift`
- Modify: `Packages/AlasCore/Sources/AlasModel/Persistence/Paths.swift:193` (`hostConsolesFile`)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/HostConsolesTests.swift`

**Interfaces:**
- Consumes: Task 1 `PeerConsoleHost.Environment(open:resize:)` and `PeerConsoleOpenError`. Task 2 `ZmxSessionName.hostShell`, `HostShellLaunch` and `ZmxIPCSocket.resize`. Existing pieces: `ZmxClient(env:runner:)` (`listSessions`, `killSession`, `socketPath(forSession:)`), `AlasCoreContext.projectAndWorktree(withWorktreeId:)`, `projects.isWorktreeHidden(projectId:path:)`, `projects.isMain(_:in:)`, `RemoteWorktreeSummaryBuilder.make(…, metrics: .unavailable)`, `ACPProcessEnvironment.baseEnvironment()` and `PersistenceStoreProtocol`.
- Produces:
  - `Paths.hostConsolesFile = appSupportRoot/"host-consoles.json"`.
  - `public struct HostConsoleEntry: Codable, Equatable, Sendable { let id: String; let worktreeId: String; var title: String; let zmxName: String; var rows: Int; var columns: Int }` and `public struct HostConsolesFile: Codable, Equatable { var consoles: [HostConsoleEntry] }`, kept in open order.
  - `@_spi(AppHost) @MainActor public final class HostConsoles`. Its init takes:
    - `core: AlasCoreContext` and `zmx: ZmxClient`;
    - `store: any PersistenceStoreProtocol = PersistenceStore()` and `fileURL: URL = Paths.hostConsolesFile`;
    - `launch: @escaping @Sendable (HostShellLaunch) async throws -> Void = { try await $0.run() }`;
    - `applySize: @escaping @Sendable (_ socketPath: String, _ rows: Int, _ columns: Int) -> Bool = ZmxIPCSocket.resize`;
    - `baseEnvironment: @escaping @Sendable () -> [String: String] = { ACPProcessEnvironment.baseEnvironment() }`;
    - `shell: String = HostShellLaunch.loginShell()`.
  - Members:
    - `var isAvailable: Bool` (`zmx.isAvailable`).
    - `func restore() async` keeps entries whose `ZMX_SESSION_PREFIX + zmxName` appears in `zmx.listSessions()`, run in `BlockingWork`. It saves when anything was dropped.
    - `func summaries() -> [PeerConsoleSummary]` first drops entries whose socket file is gone (and saves). It lists entries whose worktree is still configured. `tabIndex` is the entry's position among its worktree's entries, and `projectId`, names and `worktree` come from the project and worktree.
    - `func target(_ consoleId: String) -> PeerConsoleTarget?`.
    - `func open(worktreeId: String) async throws -> String` uses the checks and title rule below.
    - `func resize(_ consoleId: String, rows: Int, columns: Int) async -> Bool` runs `applySize` in `BlockingWork`. On success it stores the size and saves.
    - `func terminate(_ consoleId: String)` drops the entry, saves, and calls `zmx.killSession(name:)` in `BlockingWork.detach`.
    - `func makePeerConsoleHost() -> PeerConsoleHost` wires `consoles: summaries`, `resolve: target`, `setLocalInputSuppressed: { _, _ in }`, `terminate`, `open` and `resize`.
  - `open` checks, in order:
    - `!isAvailable` throws `zmxMissing`.
    - A worktree that isn't configured, or is hidden, throws `worktreeUnavailable`.
    - `project.host != nil` throws `sshProject`.
    - It then calls `await ShellEnvResolver.shared.waitUntilResolved()`, mints `UUID().uuidString` and launches.
    - Only after a successful launch does it append and save the entry with size 24×120. That is the size zmx gives a daemon launched without a TTY, observed with `stty size`.
  - Titles are "Terminal 1", "Terminal 2", …, using the lowest number unused in that worktree.

- [ ] **Step 1: Write the failing tests** in `HostConsolesTests`. Build a `Fixture` like `HeadlessSessionPresenterTests.Fixture`: a temp root, a `ProjectsManager` with project `p` and an optimistic worktree, an `AlasCoreContext`, a short `/tmp` zmx dir, and a `SubprocessRunner` fake. The fake answers `ls --short` from `var live: [String]` and records `kill <name>` into `var killed: [String]`. Its `launch` fake records launches and touches the socket file (`zmx.socketPath(forSession:)`) unless `var launchFails = true`. `applySize` records `"40x100"` and returns `var sizeApplies = true`.

```swift
@Test func openLaunchesAShellAndListsIt() async throws {
    let consoles = fixture.consoles()
    let id = try await consoles.open(worktreeId: fixture.worktree.id)
    #expect(fixture.launches.map(\.directory) == [fixture.worktree.path])
    let summary = try #require(consoles.summaries().first)
    #expect((summary.consoleId, summary.title, summary.worktreeId, summary.rows, summary.columns, summary.tabIndex)
        == (id, "Terminal 1", fixture.worktree.id, 24, 120, 0))
    #expect(consoles.target(id)?.socketPath == fixture.socketPath(of: id))
}

enum Unopenable: CaseIterable { case unknownWorktree, sshProject, noZmx, launchFails }
@Test(arguments: Unopenable.allCases)
func openRefusesWithTheReasonAndRecordsNothing(_ kind: Unopenable) async throws {
    // .unknownWorktree → worktreeUnavailable; .sshProject (project.host = "box") → sshProject;
    // .noZmx (ZmxEnv binaryURL nil) → zmxMissing; .launchFails → notStarted
    await #expect(throws: expected) { try await consoles.open(worktreeId: worktreeId) }
    #expect(consoles.summaries().isEmpty)
    #expect(try fixture.savedFile()?.consoles.isEmpty ?? true)
}

@Test func titlesReuseTheLowestFreeNumber() async throws  // open ×3, terminate "Terminal 2", open → "Terminal 2"

@Test func restoreDropsShellsWhoseSessionIsGone() async throws {
    // two opened shells; a new HostConsoles over the same file with `live` = only the first's zmxName
    await restored.restore()
    #expect(restored.summaries().map(\.consoleId) == [first])
    #expect(try fixture.savedFile()?.consoles.map(\.id) == [first])
}

@Test func listDropsShellsWhoseSocketIsGone() async throws  // remove the socket file → summaries() empty, file empty

@Test func resizeIsRememberedOnlyWhenZmxTookIt() async throws {
    // sizeApplies = false → resize returns false, target rows/columns stay 24×120;
    // sizeApplies = true → true, target and a restored instance report 40×100
}

@Test func terminateKillsTheSessionAndForgetsIt() async throws {
    consoles.terminate(id)
    #expect(consoles.summaries().isEmpty)
    try await eventually { fixture.killed == [zmxName] }
}
```

- [ ] **Step 2: Confirm the tests fail.** Run `swift test --package-path Packages/AlasCore --filter HostConsolesTests`. Expected: a compile FAIL (`HostConsoles` undefined).

- [ ] **Step 3: Implement** `Paths.hostConsolesFile` and `HostConsoles` from the Interfaces block. Persist with `store.write(HostConsolesFile(consoles:), to:)` and log write errors as `HeadlessSessionPresenter.save()` does. Mark `open` with `// ponytail: no per-peer open limit; pairing is the trust boundary (spec). Cap here if a peer misbehaves.`

- [ ] **Step 4: Run the tests.** Run `swift test --package-path Packages/AlasCore --filter HostConsolesTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AlasCore
git commit -m "feat(host): keep a registry of host shells served as peer consoles"
```

---

### Task 4: Serve shells from `alas-host`; package zmx; docs; smoke on the mini

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/HeadlessSessionPresenter.swift:30-36` (stored `peerConsoleHost`)
- Modify: `Packages/AlasCore/Sources/alas-host/main.swift:248-282,310-312,349-353,376-384`
- Modify: `Packages/AlasCore/Sources/AlasModel/Persistence/HostLaunchAgent.swift:43`
- Modify: `scripts/package-alas-host.sh`
- Modify: `docs/headless-host.md` ("What it does not do yet", new "Terminals" section, "Start at login")

**Interfaces:**
- Consumes: Task 3 `HostConsoles` (`restore`, `makePeerConsoleHost`, `isAvailable`), Task 2 `HostShellLaunch.zmxBinary` and `ZmxEnv.resolve(binaryURL:)`, and Task 1 `PeerConsoleCapability.headlessHost`.
- Produces: `HeadlessSessionPresenter.peerConsoleHost: PeerConsoleHost?` becomes a stored `public var`, defaulting to nil.

- [ ] **Step 1: Wire the host in `main.swift`.**
  - Inside the Remote block, build `let zmx = ZmxClient(env: .resolve(binaryURL: HostShellLaunch.zmxBinary(executable: Bundle.main.executableURL)))`.
  - When it's unavailable, write `alas-host: zmx not found beside alas-host or in /Applications/Alas.app; peers can't open terminals here\n` to stderr.
  - Create `let shells = HostConsoles(core: host.coreContext, zmx: zmx)` and set `presenter.peerConsoleHost = shells.makePeerConsoleHost()`.
  - Make the identity `consoleCapabilities: shells.isAvailable ? PeerConsoleCapability.headlessHost : []`, and replace the comment "No terminals here, so a Mac does not offer them".
  - In `startRemote`, `await shells.restore()` before `server.start`.
  - In `stop()`, call `openSessions?.peerConsoleHost?.shutdown()` before `remote?.stop()`.

- [ ] **Step 2: Change the launch agent.** Set `"ProcessType": "Standard"`. Comment: shells and agents started from paired Macs are work the user asked for, and zmx daemons inherit the job's throttling.

- [ ] **Step 3: Package zmx.** In `scripts/package-alas-host.sh`, require `-x "$resources/zmx/zmx"` with the message `error: $resources/zmx/zmx is not an executable`. Stage it with `ditto "$resources/zmx/zmx" "$stage_dir/zmx/zmx"`. Update the header comment: "alas-host/alas-host beside RemoteWeb/ and zmx/zmx, the layout the host looks for its web client (../RemoteWeb) and zmx (../zmx/zmx) in". The cask's `binary` stanza is unchanged, and `update-cask.py` needs nothing.

- [ ] **Step 4: Update the docs** in `docs/headless-host.md`.
  - Remove the "Terminals." and "Run scripts and worktree deletion from a Mac." bullets from "What it does not do yet"; phases 1–2 shipped the latter.
  - Add `## Terminals` before "Start at login". It covers: "New Terminal" on a host worktree in a Mac's peer view; a login shell in the worktree with the agents' PATH; shells survive host restarts; the app doesn't list or kill them and they reappear when the host is back; SSH-project worktrees are refused; zmx ships in the cask zip and otherwise comes from `/Applications/Alas.app`.
  - Add the TCC caveat: "The launch agent can't show privacy prompts, so a shell in a protected folder (Desktop, Documents, Downloads, iCloud Drive, removable volumes) may fail to read it without asking. Keep worktrees outside those folders, or grant alas-host Full Disk Access in System Settings › Privacy & Security."
  - In "Start at login", add: "Rerun `alas-host install-agent` after upgrading from a version before terminals, so the agent runs at standard priority."

- [ ] **Step 5: Run the local checks.** Run `swift test --package-path Packages/AlasCore --filter "HostConsolesTests|HeadlessSessionPresenterTests|HostLaunchAgentTests|HostProtocolTests"`. Expected: PASS. Then run `bash -n scripts/package-alas-host.sh`. Expected: no output.

- [ ] **Step 6: Smoke the real host on the mini (manual).** Use a build of this branch: `swift build --package-path Packages/AlasCore -c release --product alas-host`, with zmx copied to `../zmx/zmx` beside the binary, or `/Applications/Alas.app` installed. Run in a throwaway profile (`ALAS_APP_SUPPORT_DIR=/tmp/ah-smoke`) with Remote on, paired with a laptop on this branch's CI build. Record each result in the PR:
  1. The startup log has no "zmx not found" line, and the laptop shows "New Terminal" for that host.
  2. Opening one yields an attached console you can type in straight away. `pwd` prints the worktree path, and `echo $PATH` starts with the login-shell PATH.
  3. Resizing the laptop window changes `stty size` in the shell.
  4. Restart the agent (`alas-host restart`). The shell keeps its scrollback and `$$`, and `host-consoles.json` still lists it. If launchd killed it, add `"AbandonProcessGroup": true` to the agent plist and repeat.
  5. Type `exit`. Within one list refresh (10 s) the console leaves the peer sidebar.
  6. Close the console from the laptop: `zmx ls` (with this profile's `ZMX_DIR`) no longer lists it.
  7. Quit the host and open the app on the same profile. The app's Settings › Open sessions doesn't list `alashost-*`, and after the app quits the shell is still in `zmx ls`.
  8. Rename the cask's `zmx/zmx`. The startup log names it missing, and the laptop offers no "New Terminal".

- [ ] **Step 7: Commit**

```bash
git add Packages/AlasCore scripts/package-alas-host.sh docs/headless-host.md
git commit -m "feat(host): serve terminals to paired Macs"
```

---

### Task 5: The app host opens a hidden terminal tab

**Files:**
- Modify: `Alas/Sources/App/AppState+PeerConsoles.swift:5-16` (environment `open`; new `openPeerConsole`)

**Interfaces:**
- Consumes: Task 1 `PeerConsoleHost.Environment(open:)` and `PeerConsoleOpenError`. Existing pieces: `openTerminalTabPreparingRemoteZmxIfNeeded(for:isHidden:activates:)`, `projectAndWorktree(withWorktreeId:)`, `config.terminal.keepSessionsAlive` and `terminal.zmxClient.isAvailable`.
- Produces: `func openPeerConsole(worktreeId: String) async throws -> String` on `AppState`.
  - An unknown worktree, or one under a hidden worktree path, throws `worktreeUnavailable`. `project.host != nil` throws `sshProject`.
  - With `!config.terminal.keepSessionsAlive || !terminal.zmxClient.isAvailable`, it throws `PeerConsoleOpenError("This Mac doesn't keep terminal sessions alive (Settings › Terminal › Keep sessions alive across app quit), so it can't share a new terminal.")`.
  - Otherwise it opens with `isHidden: true, activates: false` and returns the tab's single leaf id (`case .terminal(let state) = tab`, `state.root.leaves().first?.id`). Another thrown error becomes `PeerConsoleOpenError((error as? LocalizedError)?.errorDescription ?? PeerConsoleOpenError.notStarted.message)`.
  - No `resize` closure is added, and `remoteServerIdentity()` keeps the default `PeerConsoleCapability.appHost`.

- [ ] **Step 1: Implement** `openPeerConsole` and pass `open: { [weak self] in guard let self else { throw PeerConsoleOpenError.unsupported }; return try await self.openPeerConsole(worktreeId: $0) }`. Comment: hidden, non-activating, so the host user's selection and focus never move. The hidden flag isn't persisted, so the tab shows after this Mac relaunches (spec decision).

- [ ] **Step 2: Verify.** `swift build --package-path Packages/AlasCore` succeeds. The app compile is CI's first. There's no test: this is wiring over `openTerminalTab(isHidden:activates:)`, which `TabsManagerTests` already pins, and Task 1's host tests.

- [ ] **Step 3: Commit**

```bash
git add Alas/Sources/App/AppState+PeerConsoles.swift
git commit -m "feat(remote): open a hidden terminal tab for a peer"
```

---

### Task 6: Peer view — "New Terminal", take control, fit the host to the pane

**Files:**
- Modify: `Alas/Sources/Remote/Native/NativePeerConsoles.swift`
- Modify: `Alas/Sources/Remote/Native/PeerConsoleViewer.swift` (init parameters, resize request, `PeerConsoleLayout.grid`)
- Modify: `Alas/Sources/Remote/Native/NativePeerSessions.swift:205-208` (`onOpened`)
- Modify: `Alas/Sources/Remote/Native/NativePeerSidebarSnapshot.swift:209-216` (`hostWorktreeId`)
- Modify: `Alas/Sources/Sidebar/NativePeerSidebarView.swift:163,171-197` (menu)
- Modify: `Alas/Sources/App/AppState+PeerConsoles.swift:92-115` (`makeNativePeerConsoles`)
- Test: `AlasTests/PeerConsoleClientTests.swift` (`NativePeerConsolesTests`, `PeerConsoleLayoutTests`)

**Interfaces:**
- Consumes: Task 1 requests, events and capabilities.
- Produces:
  - `NativePeerConsoles.init` adds three defaulted parameters: `supportsOpen: @escaping @MainActor (String) -> Bool = { _ in false }`, `supportsResize: same` and `showError: @escaping @MainActor (_ title: String, _ message: String) -> Void = { _, _ in }`.
  - `var onOpened: ((_ serverId: String, _ consoleId: String) -> Void)?`.
  - `func canOpen(serverId: String) -> Bool`, which is `onlinePeers.contains && supportsOpen`.
  - `func openTerminal(serverId: String, worktreeId: String)`, which does nothing unless `canOpen`. It sends `.open(requestId: UUID().uuidString, worktreeId:)` and records `pendingOpens[requestId] = serverId`.
  - In `receive`, `.opened` and `.openFailed` are consumed only for a pending request from the same server, once.
    - `.opened` sets `controlOnOpen = (serverId, consoleId)` and calls `onOpened`.
    - `.openFailed` calls `showError("New Terminal Failed", message)`.
    - `peersChanged` drops pending opens of peers that went offline.
  - The private `open(serverId:consoleId:)` passes `takesControlWhenLive: controlOnOpen matches`, clears it, and passes `supportsResize: supportsResize(serverId)`.
  - `PeerConsoleViewer.init` adds `takesControlWhenLive: Bool = false` and `supportsResize: Bool = false`.
    - With the first flag, the first snapshot that makes the viewer `.live` calls `takeControl()`.
    - With the second, a private `requestHostGrid()` runs at the end of `gridChanged()` and after `apply` in the `.control` case. It sends `.resize(attachmentId:rows:columns:)` only when all of these hold: `isControlling`, `!fitsToPane` (Fit means "show the host's grid", so it never feeds back), a known `pane` and `cellSize`, and a fitted grid that differs from both the host's current `rows`/`columns` and the last one requested.
  - `PeerConsoleLayout.grid(fitting pane: CGSize, cell: CGSize) -> AlasGhostty.SurfaceView.GridSize` is the inverse of `extent`: `max(1, floor(pane / cell) - 1)` per axis.
  - `NativePeerWorktreeGroup.hostWorktreeId: String?` is `host?.snapshot.worktree.id ?? sessions.lazy.compactMap(\.worktreeId).first ?? consoles.lazy.compactMap(\.worktreeId).first`.
  - In the sidebar, `removalMenu` becomes `worktreeMenu`. "New Terminal" comes first and is shown when `client.consoles?.canOpen(serverId: peer.serverId) == true`. It is disabled when `hostWorktreeId == nil`, and a `Divider()` follows it when removal items follow.
  - `makeNativePeerConsoles` wires `supportsOpen`/`supportsResize` from `remotePeers.capabilities` (`openV1`/`resizeV1`) and `showError` to `showFileActionError(title:message:)`.
  - `NativePeerSessions.init` sets `consoles?.onOpened = { [weak self] in self?.selectConsole(serverId: $0, consoleId: $1) }`.

- [ ] **Step 1: Write the failing tests** in `AlasTests/PeerConsoleClientTests.swift`:

```swift
// NativePeerConsolesTests
@Test func openingATerminalNeedsTheCapabilityAndAnswersOnlyItsOwnRequest() {
    var sent: [(String, RemoteClientMessage)] = []
    var opened: [String] = []
    var errors: [String] = []
    let consoles = NativePeerConsoles(
        send: { sent.append(($0, $1)) }, supportsConsoles: { _ in true },
        supportsOpen: { $0 == "srv" }, makeSurface: { _, _, _ in throw CancellationError() },
        showError: { errors.append("\($0): \($1)") })
    consoles.onOpened = { opened.append("\($0)/\($1)") }
    consoles.peersChanged(online: ["srv", "old"])
    sent.removeAll()

    consoles.openTerminal(serverId: "old", worktreeId: "w")
    #expect(sent.isEmpty)
    consoles.openTerminal(serverId: "srv", worktreeId: "w")
    guard case .console(.open(let first, "w")) = sent.last?.1 else { Issue.record("no open"); return }
    consoles.receive(serverId: "old", .opened(requestId: first, consoleId: "x"))
    consoles.receive(serverId: "srv", .opened(requestId: first, consoleId: "c"))
    consoles.receive(serverId: "srv", .opened(requestId: first, consoleId: "c"))
    #expect(opened == ["srv/c"])

    consoles.openTerminal(serverId: "srv", worktreeId: "w")
    guard case .console(.open(let second, _)) = sent.last?.1 else { Issue.record("no open"); return }
    consoles.receive(serverId: "srv", .openFailed(requestId: second, message: "SSH"))
    #expect(errors == ["New Terminal Failed: SSH"])
}

// PeerConsoleLayoutTests
@Test(arguments: [CGSize(width: 648, height: 400), CGSize(width: 655, height: 415), CGSize(width: 10, height: 10)])
func theFittedGridFitsThePane(pane: CGSize) {
    let cell = CGSize(width: 8, height: 16)
    let grid = PeerConsoleLayout.grid(fitting: pane, cell: cell)
    let extent = PeerConsoleLayout.extent(rows: grid.rows, columns: grid.columns, cell: cell)
    #expect(grid.rows >= 1 && grid.columns >= 1)
    #expect(pane.width < 16 || extent.width <= pane.width)
    #expect(pane.height < 32 || extent.height <= pane.height)
}
```

Also check the grid exactly: `grid(fitting: CGSize(width: 648, height: 400), cell: CGSize(width: 8, height: 16)) == .init(rows: 24, columns: 80)`, matching the existing 80×24 → 648×400 fixture.

- [ ] **Step 2: Implement** the Interfaces block. Mark `requestHostGrid` with `// ponytail: one request per pane change while dragging; debounce if hosts see bursts.`

- [ ] **Step 3: Verify.** `swift build --package-path Packages/AlasCore` succeeds. The app build and these tests are CI's first run. In the CI log, check that `NativePeerConsolesTests` and `PeerConsoleLayoutTests` report their tests under ✔, not just the XCTest-bridge "0 tests" line.

- [ ] **Step 4: Commit**

```bash
git add Alas/Sources AlasTests/PeerConsoleClientTests.swift
git commit -m "feat(remote): open a terminal on a paired Mac from the peer view"
```

---

### Task 7: End-to-end check against an app host (manual, after CI is green)

No code changes. Use this branch's CI app build on both Macs, paired, with "Keep sessions alive" on for the host. Record each result in the PR:

- [ ] **Step 1:** Use the context menu "New Terminal" on a host worktree. The laptop shows the console attached and controlled. On the host, the selected worktree, the active tab and the key window are unchanged, and the new tab is not in the tab strip.
- [ ] **Step 2:** Resizing the laptop pane sends no resize: the host advertises no `peerConsoleResize.v1`. The console keeps the host's grid, and Fit still works.
- [ ] **Step 3:** With "Keep sessions alive" off on the host, "New Terminal" shows "New Terminal Failed" with the Settings message.
- [ ] **Step 4:** Against a host on `main` before this branch, the laptop offers no "New Terminal", and existing consoles still list, attach and close.
