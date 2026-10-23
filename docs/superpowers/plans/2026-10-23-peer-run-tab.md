# Peer Run Tab (Phase 2, PR 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Mac paired with a host gets a Run tab in the peer right pane. The tab lists the selected host worktree's run scripts with the local row presentation, offers Run, Stop, Rerun and a finished run's output, and stays current from host events.

**Architecture:** The host protocol gains `listRunScripts(worktree:)` and `restartRun(scriptKey:worktree:)`, which answer with a new wire type `HostRunScript`, plus the `host.runs.scripts.v1` capability. Host-protocol runs start with the script's own console setting and pass a new `activatesConsole: false` through `AlasCoreContext.startRun` and `RunLaunchRequest` to `AppRunLauncher`, so an app host never switches its active tab. On the Mac, a UI-free `PeerRuns` in the package joins the listing with the channel's `RunRecord`s and maps row actions to requests and replies to outcomes. The app's `NativePeerHosts` exposes runs and requests per peer, and a new `NativePeerRunTabView` renders rows with the existing `RunTabPresentation`/`RunRowView`.

**Tech Stack:** Swift 5.9+, SwiftUI/AppKit (app only), Swift Testing, SwiftPM package `Packages/AlasCore`, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-23-peer-runs-and-worktrees-design.md` (goals 5-7 only. Goals 1-4 shipped in PR 1, `c0f63183b`, plan `docs/superpowers/plans/2026-10-23-peer-worktree-controls.md`.)

## Global Constraints

- PR 2 scope, verbatim: "The Run tab and the run requests."
- "Add `.run` to the peer-available tabs. Rows reuse the local Run tab's presentation (`RunTabPresentation`): status labels, detail ("exit 42 · 12s · 3m ago") and allowed actions."
- "Actions are Run, Stop and Rerun. Rerun uses a new host restart request. Edit and Open Terminal are not offered."
- "A finished run's output is shown on request via `runOutput`, as the local "Open report" does."
- "A run started or stopped elsewhere, locally on the host or by another client, updates the tab from host events."
- "A run started from a peer behaves like one started on that Mac: the script's `alas-console` setting decides whether its terminal tab is visible. It never changes what is selected or focused on the host's screen. `listRunScripts` lists what the host's Run tab lists."
- "`listRunScripts(worktree:)` returns the worktree's scripts: key, name, scope, and the metadata the row needs. It is backed by the server's existing script discovery." "`restartRun(scriptKey:worktree:)` follows `RunsAPI.restart` semantics." Capability string: `host.runs.scripts.v1`.
- "Older Macs never send these requests. A new Mac checks the capability before showing the Run tab, so an older host shows no Run tab rather than a broken one."
- "No regression for older hosts or older Macs. New requests are gated on capabilities, and new response or error cases must not break older decoders."
- Non-goals: "Live run output while a run is going, and terminals on a headless host." "Run history beyond each script's latest record." (`RunRecord` keeps only the latest run per (worktree, script).) "Creating, editing or scheduling run scripts remotely." "Web/phone client changes."
- "The core package gains no UI imports." From AGENTS.md: `Packages/AlasCore` "must not import SwiftUI, AppKit, WebKit, or anything the app builds outside SwiftPM … Anything the app or tests use from the package must be `public`."
- AGENTS.md: use Swift Testing (`import Testing`), not XCTest. Extend the existing suite for the type under test before creating a file. One behavior per test, with `@Test(arguments:)` for variants. Never synchronize with a fixed `Task.sleep`; poll with `eventually`. No SwiftUI view tests: extract the decision into a plain function and test that.
- AGENTS.md: Conventional Commits (`type(scope): summary`). No `Co-Authored-By`, no generated-by footers, no agent attribution anywhere.
- AGENTS.md: keep code, comments, logs, and UI strings in English.
- AGENTS.md: a new app source file is compiled only after `xcodegen` regenerates `Alas.xcodeproj`. Commit the regenerated project with it.
- AGENTS.md: for changes under `Packages/AlasCore`, run `swift test --package-path Packages/AlasCore` first, filtered to the touched suites. `AlasTests` cannot run on this machine: CI gives them their first run and the app its first full compile. App logic therefore lives in plain types. App-side tests are written here but verified in CI. Report exactly which local checks ran.

## Review Focus

1. **Rerun after a run has finished.** On an app host, the finished run's kept console must be replaced, not joined by a second one. The request must be `restartRun`, never `startRun`. Test: Task 3 `commandsMapToTheirRequests`.
2. **Mixed versions.** A host with the host channel but without `host.runs.scripts.v1` (older, or headless before this PR) shows no Run tab. A `.run` tab left selected from another worktree falls back to the first available tab. Test: Task 4 `peerTabsOfferRunOnlyWhenTheHostServesScripts`.
3. **A run the listing lacks.** A run started on the host for a script the listing does not include (the script was deleted meanwhile, or the listing failed) still shows while it is active, so the user can stop it. Runs of another worktree with the same script key never show. Test: Task 3 `rowsListTheHostsScriptsThenActiveRunsItDoesNotList`.
4. **Output asked for at the wrong time.** Asking for output of a run that has not finished, or one the host has forgotten, shows a message rather than an empty sheet. Test: Task 3 `repliesBecomeDoneARefusalOrOutput`.
5. **A peer restarts a run the host user had moved to the background.** The restart keeps the console hidden, because the open console's visibility wins over the script default, as a local restart does. It never activates a tab. Test: Task 2 `hostProtocolRunsFollowTheConsoleSettingAndNeverActivate`.

---

### Task 1: Host — `listRunScripts`, `restartRun`, `host.runs.scripts.v1`

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocol.swift:72-73,121,173-176` (request cases, `HostRunScript`, response case)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocolServer.swift:243-256,365-370`
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteProtocol.swift:1457-1465` (`HostProtocolCapability`)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/HostProtocolTests.swift`, `Packages/AlasCore/Tests/AlasCoreTests/HostProtocolServerTests.swift`

**Interfaces:**
- Consumes: `HostProtocolServer.ScriptDiscovery` (`discoverScripts`), `AlasCoreContext.runExecutionTarget(for:in:)`, `RunsAPI.restart(_:in:isHidden:caller:)`.
- Produces:
  - `HostRequest.listRunScripts(worktree: WorktreeRef)` and `HostRequest.restartRun(scriptKey: String, worktree: WorktreeRef)`, appended after `stopRun`. Doc: "(`host.runs.scripts.v1`)".
  - `HostResponse.runScripts(scripts: [HostRunScript])`.
  - `public struct HostRunScript: Codable, Equatable, Sendable { var scope: RunScriptScope; var fileName: String; var name: String; var cwd: String?; var target: RunExecutionTarget; var key: String { "\(scope.rawValue):\(fileName)" } }`, with `public init(scope:fileName:name:cwd:target:)` and `public init(_ script: RunScript, target: RunExecutionTarget)` (`name` = `displayName`). `target` is where a run executes (the host and working directory), for the row's location line.
  - `HostProtocolCapability.runsScriptsV1 = "host.runs.scripts.v1"`, appended to `served`.

- [ ] **Step 1: Write the failing protocol tests** in `HostProtocolTests`

Add to the `clientMessagesRoundTrip` arguments `HostClientMessage(id: 20, request: .listRunScripts(worktree: ref))` and `HostClientMessage(id: 21, request: .restartRun(scriptKey: "repo:dev.sh", worktree: ref))`. Add to `serverMessagesRoundTrip` `.response(id: 13, result: .runScripts(scripts: [HostRunScript(scope: .repo, fileName: "dev.sh", name: "Dev", cwd: "web", target: RunExecutionTarget(host: nil, workingDirectory: "/srv/feature/web"))]))`. Pin it in `encodingIsPinned`:

```swift
#expect(try json(HostServerMessage.response(id: 4, result: .runScripts(scripts: [HostRunScript(
    scope: .repo, fileName: "dev.sh", name: "Dev", cwd: nil, target: RunExecutionTarget(host: nil, workingDirectory: "/srv/feature")
)]))) == #"{"response":{"id":4,"result":{"runScripts":{"scripts":[{"fileName":"dev.sh","name":"Dev","scope":"repo","target":{"workingDirectory":"\/srv\/feature"}}]}}}}"#)
```

- [ ] **Step 2: Write the failing server tests** in `HostProtocolServerTests`

```swift
/// The listing is the server's discovery with each script's run location;
/// an archived worktree is refused as an unknown one is.
@Test func runScriptsAreListedForListedWorktreesOnly() async throws {
    let fixture = try Fixture()
    let server = HostProtocolServer(host: fixture.host) { _, _ in [Self.devScript(cwd: "web")] }
    let client = Client()
    let connection = server.connect(caller: .remotePeer(deviceID: "d"), send: client.receive)
    let ref = WorktreeRef(projectID: "p", path: fixture.worktree.path.path)
    await connection.receive(HostClientMessage(id: 1, request: .listRunScripts(worktree: ref)))
    fixture.projects.setWorktreeHidden(projectId: "p", path: fixture.worktree.path, hidden: true)
    await connection.receive(HostClientMessage(id: 2, request: .listRunScripts(worktree: ref)))
    #expect(client.messages == [
        .response(id: 1, result: .runScripts(scripts: [HostRunScript(
            scope: .repo, fileName: "dev.sh", name: "Dev", cwd: "web",
            target: RunExecutionTarget(host: nil, workingDirectory: "/srv/feature/web")
        )])),
        .response(id: 2, result: .failure(error: .notFound(what: "worktree /srv/feature in project p"))),
    ])
}
```

Parameterize the existing `runsDoNotStartInArchivedWorktrees(archivedDuringDiscovery:)` over the request as well: `@Test(arguments: [false, true], [false, true]) func runsDoNotStartInArchivedWorktrees(archivedDuringDiscovery: Bool, restart: Bool)`. Send `.restartRun(…)` when `restart` is true and keep the expected refusal unchanged. Add `static func devScript(cwd: String? = nil, console: RunScriptConsole = .shown, fileURL: URL = URL(fileURLWithPath: "/srv/feature/dev.sh")) -> RunScript` to the suite, and use it in place of the inline `RunScript(…)` literals there and in `shutdownWaitsForARequestStillBeingServed`.

- [ ] **Step 3: Run to verify they fail**

Run: `swift test --package-path Packages/AlasCore --filter 'HostProtocolTests|HostProtocolServerTests'`
Expected: the build FAILS with "type 'HostRequest' has no member 'listRunScripts'".

- [ ] **Step 4: Implement**

- `HostProtocol.swift`: add the two cases, the response case and `HostRunScript` after `HostWorktreeRead`. Synthesized `Codable` encodes the nil `cwd` and `target.host` as absent, which the pin relies on.
- `HostProtocolServer.swift`:
  - Replace `archivedRunRefusal(_:)` with `private func isArchived(_ ref: WorktreeRef) throws -> Bool` and `private static let archivedRunStart = HostResponse.runStart(start: .refused(title: "Worktree archived", message: "Unarchive the worktree to run scripts in it."))`.
  - Extract `.startRun`'s discovery into `private func runnableScript(_ scriptKey: String, in ref: WorktreeRef) async throws -> RunScript?`. It returns nil when the worktree is archived, before or after discovery. It throws `notFound(what: "script \(scriptKey)")` when no script has the key.
  - `.startRun` and `.restartRun` both call `runnableScript`, then return `Self.archivedRunStart` on nil. `.restartRun` then returns `.runStart(start: host.runs.restart(script, in: try worktree(ref), caller: caller))`. Task 2 adds the console and activation arguments.
  - `.listRunScripts`: `let listed = try worktree(ref)`. Throw `notFound(what: "worktree \(ref.path) in project \(ref.projectID)")` when `isWorktreeHidden`, as `.readWorktree` does. Then answer `.runScripts(scripts: await discoverScripts(listed.path, projectHost).map { HostRunScript($0, target: host.core.runExecutionTarget(for: $0, in: listed)) })`, where `projectHost` is looked up as `.startRun` does.
- `RemoteProtocol.swift`: `public static let runsScriptsV1 = "host.runs.scripts.v1"`, with the doc line "Hosts that serve `listRunScripts` and `restartRun`". Append it to `served`.

- [ ] **Step 5: Run to verify they pass**

Run: `swift test --package-path Packages/AlasCore --filter 'HostProtocolTests|HostProtocolServerTests|HostSessionsTests|HostSocketServerTests'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocol.swift Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocolServer.swift Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteProtocol.swift Packages/AlasCore/Tests/AlasCoreTests/HostProtocolTests.swift Packages/AlasCore/Tests/AlasCoreTests/HostProtocolServerTests.swift
git commit -m "feat(host): list run scripts and restart runs over the host protocol"
```

---

### Task 2: Host-protocol runs follow the console setting and never take focus

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext+Runs.swift:23-34,136-221,262-276` (`RunLaunchRequest`, `startRun`, `restartRun`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost.swift:383-393` (`RunsAPI.start`, `.restart`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocolServer.swift` (`.startRun`, `.restartRun`)
- Modify: `Alas/Sources/App/AppState+RunScripts.swift:624-634` (`AppRunLauncher.launch`)
- Modify: `Alas/Sources/App/AppState.swift:7414-7456,7504-7576` (`openTerminalTabPreparingRemoteZmxIfNeeded`, `openTerminalTab`)
- Modify: `Alas/Sources/Center/TabsManager.swift:367-379` (`appendTerminal(worktreeId:…)`)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/HostProtocolServerTests.swift`

**Interfaces:**
- Consumes: Task 1's `.startRun`/`.restartRun` handling and `devScript(cwd:console:fileURL:)`.
- Produces:
  - `RunLaunchRequest.activatesConsole: Bool`, documented as "A shown console becomes its worktree's active tab; false for runs asked for from elsewhere, which leave the host's screen alone."
  - `AlasCoreContext.startRun(_:in:isHidden:activatesConsole: Bool = true, onSettled:)` and `restartRun(_:in:isHidden:activatesConsole: Bool = true, onSettled:)`.
  - `RunsAPI.start(_:in:isHidden:activatesConsole: Bool = true, caller:)` and `RunsAPI.restart(_:in:isHidden:activatesConsole: Bool = true, caller:)`.
  - App: `openTerminalTabPreparingRemoteZmxIfNeeded(…, isHidden:, activates: Bool = true)`, `openTerminalTab(…, isHidden:, activates: Bool = true)`, `TabsManager.appendTerminal(worktreeId:title:sessionId:runScriptKey:isHidden:activates: Bool = true)`.

- [ ] **Step 1: Write the failing test** in `HostProtocolServerTests`

Give `Fixture.init` an `environment: (any AlasHostEnvironment)? = nil` parameter and pass it to `AlasCoreContext` when it is set. Add a private test double:

```swift
@MainActor private final class RecordingRunEnvironment: AlasHostEnvironment {
    final class Launcher: RunLauncher {
        var requests: [RunLaunchRequest] = []
        func launch(_ request: RunLaunchRequest, in core: AlasCoreContext) async throws -> RunLaunch {
            requests.append(request)
            return .unobservable
        }
    }
    let launcher = Launcher()
    var openConsoleIsHidden: Bool?
    var runLauncher: any RunLauncher { launcher }
    func runConsoleIsHidden(scriptKey: String, worktreeID: String) -> Bool? { openConsoleIsHidden }
}
```

```swift
/// A run asked for over the host protocol is shown as the script says, or
/// for a restart as its open console is, and never becomes the active tab.
@Test(arguments: [
    (restart: false, console: RunScriptConsole.hidden, openConsoleIsHidden: Bool?.some(false), hidden: true),
    (restart: false, console: .shown, openConsoleIsHidden: nil, hidden: false),
    (restart: true, console: .shown, openConsoleIsHidden: true, hidden: true),
    (restart: true, console: .hidden, openConsoleIsHidden: nil, hidden: true),
])
func hostProtocolRunsFollowTheConsoleSettingAndNeverActivate(
    restart: Bool, console: RunScriptConsole, openConsoleIsHidden: Bool?, hidden: Bool
) async throws {
    let environment = RecordingRunEnvironment()
    environment.openConsoleIsHidden = openConsoleIsHidden
    let fixture = try Fixture(environment: environment)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("alas-run-\(UUID().uuidString).sh")
    try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
    let server = HostProtocolServer(host: fixture.host) { _, _ in [Self.devScript(console: console, fileURL: file)] }
    let connection = server.connect(caller: .remotePeer(deviceID: "d"), send: Client().receive)
    let ref = WorktreeRef(projectID: "p", path: fixture.worktree.path.path)
    await connection.receive(HostClientMessage(id: 1, request: restart
        ? .restartRun(scriptKey: "repo:dev.sh", worktree: ref) : .startRun(scriptKey: "repo:dev.sh", worktree: ref)))
    await fixture.host.core.waitForStartingRunsForTesting()
    #expect(environment.launcher.requests.map(\.isHidden) == [hidden])
    #expect(environment.launcher.requests.map(\.activatesConsole) == [false])
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path Packages/AlasCore --filter HostProtocolServerTests`
Expected: the build FAILS with "value of type 'RunLaunchRequest' has no member 'activatesConsole'".

- [ ] **Step 3: Implement**

- `AlasCoreContext+Runs.swift`: thread `activatesConsole` from `restartRun` to `startRun` to `RunLaunchRequest`. `PendingRunLaunch` does not need it.
- `AlasHost.swift`: `RunsAPI.start`/`.restart` forward it.
- `HostProtocolServer.swift`, both with `activatesConsole: false`, because whoever asks over the host protocol is not at this Mac's screen:
  - `.startRun` passes `isHidden: script.console == .hidden`.
  - `.restartRun` passes `isHidden: host.core.startingRunIsHidden(scriptKey: script.key, worktreeID: worktree.id) ?? host.core.environment.runConsoleIsHidden(scriptKey: script.key, worktreeID: worktree.id) ?? (script.console == .hidden)`. This is the order of the local `currentRunConsole`.
- App: `AppRunLauncher.launch` passes `activates: request.activatesConsole`. `openTerminalTabPreparingRemoteZmxIfNeeded` passes it to `openTerminalTab`, and `openTerminalTab` passes it to `tabs.appendTerminal`. `appendTerminal` calls `append(tab, to: worktreeId, activate: activates && !isHidden)`. Other callers keep the defaults, so local and plugin runs still activate.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path Packages/AlasCore --filter 'HostProtocolServerTests|AlasHostTests'`
Expected: PASS. The app changes compile in CI, and the existing `AlasTests/RunScriptLaunchTests` there must stay green.

- [ ] **Step 5: Commit**

```bash
git add Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext+Runs.swift Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost.swift Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocolServer.swift Packages/AlasCore/Tests/AlasCoreTests/HostProtocolServerTests.swift Alas/Sources/App/AppState+RunScripts.swift Alas/Sources/App/AppState.swift Alas/Sources/Center/TabsManager.swift
git commit -m "feat(host): start peer runs with the script's console and without taking focus"
```

---

### Task 3: `PeerRuns` — rows, requests and replies for a peer's Run tab

**Files:**
- Create: `Packages/AlasCore/Sources/AlasHostCore/Remote/Peer/PeerRuns.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/PeerRunsTests.swift`

**Interfaces:**
- Consumes: `HostRunScript`, `HostRequest.restartRun`/`.listRunScripts` (Task 1), `PeerWorktreeRemoval.message(for:)`, `RunReportOutputPresentation.make(for:)`.
- Produces:
  - `public enum PeerRuns` containing:
    - `struct Row: Equatable, Sendable { var script: HostRunScript; var record: RunRecord? }` with a public init.
    - `enum Command: Equatable, Sendable { case start, stop, restart, output(runID: String) }`.
    - `enum Reply: Equatable, Sendable { case done, refused(title: String, message: String), output(RunReportOutputPresentation) }`.
    - `static func rows(scripts: [HostRunScript]?, runs: [RunRecord], worktreeID: String) -> [Row]`, where `scripts` is nil when the listing failed.
    - `static func perform(_ command: Command, on row: Row, in worktree: WorktreeRef, request: (HostRequest) async -> HostResponse) async -> Reply`.

- [ ] **Step 1: Write the failing tests**

Fixture helpers: `record(_ key: String, worktreeID: String = "w", status: RunStatus, id: String = UUID().uuidString) -> RunRecord` (`scriptName` = the file name without its extension), and `script(_ scope: RunScriptScope, _ fileName: String) -> HostRunScript`.

```swift
@Test func rowsListTheHostsScriptsThenActiveRunsItDoesNotList() {
    let build = record("repo:build.sh", status: .finished(.succeeded))
    let deploy = record("repo:deploy.sh", status: .running)
    let runs = [build, deploy, record("repo:gone.sh", status: .finished(.succeeded)),
                record("repo:build.sh", worktreeID: "other", status: .running)]
    let rows = PeerRuns.rows(scripts: [script(.repo, "build.sh"), script(.global, "lint.sh")], runs: runs, worktreeID: "w")
    #expect(rows.map(\.script.key) == ["repo:build.sh", "global:lint.sh", "repo:deploy.sh"])
    #expect(rows.map(\.record) == [build, nil, deploy])
    #expect(rows[2].script == HostRunScript(scope: .repo, fileName: "deploy.sh", name: "deploy", cwd: nil, target: deploy.target))
    #expect(PeerRuns.rows(scripts: nil, runs: runs, worktreeID: "w").map(\.script.key) == ["repo:deploy.sh"])
}

@Test(arguments: [
    (PeerRuns.Command.start, RunStatus?.none, "start"),
    (.start, .finished(.failed(exitCode: 1)), "restart"),
    (.restart, .running, "restart"),
    (.stop, .running, "stop"),
    (.output(runID: "r1"), .finished(.succeeded), "output"),
])
func commandsMapToTheirRequests(command: PeerRuns.Command, status: RunStatus?, expected: String) async {
    let ref = WorktreeRef(projectID: "p", path: "/srv/feature")
    let row = PeerRuns.Row(script: script(.repo, "dev.sh"), record: status.map { record("repo:dev.sh", status: $0, id: "r1") })
    var sent: [HostRequest] = []
    _ = await PeerRuns.perform(command, on: row, in: ref) { sent.append($0); return .done }
    let requests: [String: HostRequest] = [
        "start": .startRun(scriptKey: "repo:dev.sh", worktree: ref), "restart": .restartRun(scriptKey: "repo:dev.sh", worktree: ref),
        "stop": .stopRun(scriptKey: "repo:dev.sh", worktree: ref), "output": .runOutput(runID: "r1", projectID: "p"),
    ]
    #expect(sent == [requests[expected]!])
}

@Test(arguments: [
    (HostResponse.runStart(start: .started(runID: "r")), PeerRuns.Reply.done),
    (.runStart(start: .refused(title: "Run Script Failed", message: "Busy")), .refused(title: "Run Script Failed", message: "Busy")),
    (.runStart(start: .projectUnavailable), .refused(title: "Run Script Failed", message: "The project is no longer available on the host.")),
    (.failure(error: .notFound(what: "script repo:dev.sh")), .refused(title: "Run Script Failed", message: "The host has no script repo:dev.sh.")),
    (.failure(error: .operationInProgress), .refused(title: "Run Script Failed", message: PeerWorktreeRemoval.message(for: .operationInProgress))),
    (.runOutput(output: .text("", truncated: false)), .output(.document(text: "No output was produced.", isTruncated: false))),
    (.runOutput(output: .unavailable), .output(.unavailable)),
    (.runOutput(output: .notFinished), .refused(title: "Run Output", message: "This run has not finished yet.")),
    (.runOutput(output: .unknownRun), .refused(title: "Run Output", message: "The host no longer has this run's output.")),
])
func repliesBecomeDoneARefusalOrOutput(response: HostResponse, expected: PeerRuns.Reply) async {
    let command: PeerRuns.Command = if case .runOutput = response { .output(runID: "r1") } else { .start }
    let row = PeerRuns.Row(script: script(.repo, "dev.sh"), record: record("repo:dev.sh", status: .finished(.succeeded), id: "r1"))
    #expect(await PeerRuns.perform(command, on: row, in: WorktreeRef(projectID: "p", path: "/srv/feature")) { _ in response } == expected)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path Packages/AlasCore --filter PeerRunsTests`
Expected: the build FAILS with "cannot find 'PeerRuns' in scope".

- [ ] **Step 3: Implement `PeerRuns.swift`**

- `rows` follows the local `RunTabView.activeOrAllScripts` rule. First come the listed scripts in order, each with its record for (`worktreeID`, key). Then come the active records of `worktreeID` whose key is not listed, sorted by scope `rawValue`, then by `scriptName` with `localizedStandardCompare`. Each of these becomes a `HostRunScript` built from the record: scope and file name split from `scriptKey` at the first `:` (skip the record if the scope does not parse), `name: scriptName`, `cwd: nil`, `target: record.target`. With nil `scripts`, only those active rows are listed.
- `perform` sends one request:
  - `.start` sends `restartRun` when `row.record?.status` is `.finished`, and `startRun` otherwise. Rerun replaces the kept console, as `RunsAPI.startOrRestart` does.
  - `.restart` sends `restartRun`, `.stop` sends `stopRun`, and `.output(id)` sends `runOutput(runID: id, projectID: worktree.projectID)`.
  - Add `// ponytail: Rerun races a run started elsewhere since the last event and restarts it; send the seen run id if that bites.`
- Reply mapping. The title is `"Run Output"` for `.output` and `"Run Script Failed"` otherwise.
  - `.done`, `.runStart(.started)` and `.runStart(.alreadyStarting)` map to `.done`.
  - `.runStart(.refused(t, m))` maps to `.refused(t, m)`, and `.runStart(.projectUnavailable)` to the message above.
  - `.runOutput(.text(t, truncated))` maps to `.output(.make(for: .available(text: t, truncated: truncated)))`, and `.unavailable` to `.output(.unavailable)`. `.notFinished` and `.unknownRun` map to the refusals above.
  - `.failure(.notFound(what))` maps to `.refused(title, "The host has no \(what).")`, because the shared message names a worktree. Any other `.failure(e)` maps to `.refused(title, PeerWorktreeRemoval.message(for: e))`.
  - Any other response maps to `.refused(title, "The host sent an unexpected reply.")`.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --package-path Packages/AlasCore --filter 'PeerRunsTests|PeerHostChannelTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AlasCore/Sources/AlasHostCore/Remote/Peer/PeerRuns.swift Packages/AlasCore/Tests/AlasCoreTests/PeerRunsTests.swift
git commit -m "feat(remote): map a peer's run rows and actions to host requests"
```

---

### Task 4: Peer tab set and peer row presentation

**Files:**
- Modify: `Alas/Sources/Right/RightPaneState.swift:14-18` (`RightPaneTab.peerAvailable`)
- Modify: `Alas/Sources/Right/RunTabPresentation.swift:24-33,57-71,179-181,195-216`
- Test: `AlasTests/RightPaneTabTests.swift`, `AlasTests/RunTabPresentationTests.swift`

**Interfaces:**
- Consumes: `PeerRuns.Row` (Task 3).
- Produces:
  - `RightPaneTab.peerAvailable(isFolder: Bool = false, servesRuns: Bool = false) -> [Self]`. It appends `.run` after `.agent` when `servesRuns` is true. Its doc changes to "schedules belong to this Mac; Run needs a host that serves `host.runs.scripts.v1`".
  - `RunRowInput.isEditable: Bool = true`. `.edit` is appended only when it is true.
  - `RunTabPresentation.row(_ input: RunRowInput, now: Date, hostLabel: String? = nil)`. The tooltip reads `"\(target.host ?? hostLabel ?? target.hostLabel) · \(target.workingDirectory)"`.
  - `RunTabPresentation.peerRow(_ row: PeerRuns.Row, hostName: String, now: Date) -> RunRowPresentation`. It builds `RunScript(scope:, fileName:, fileURL: URL(fileURLWithPath: fileName), displayName: name, onExit: .keep, cwd:, isExecutable: true)` (the file URL is never read) and a `RunRowInput` with `hasTerminal: false`, `hasReport` true when the record is `.finished`, `target: record?.target ?? script.target` and `isEditable: false`. It then calls `row(…, hostLabel: hostName)`.

- [ ] **Step 1: Write the failing tests**

In `RightPaneTabTests`, replace `peerTabsDropChangesOnlyForFolders` with:

```swift
@Test(arguments: [
    (false, false, [RightPaneTab.changes, .files, .agent]),
    (true, false, [RightPaneTab.files, .agent]),
    (false, true, [RightPaneTab.changes, .files, .agent, .run]),
    (true, true, [RightPaneTab.files, .agent, .run]),
])
func peerTabsOfferRunOnlyWhenTheHostServesScripts(isFolder: Bool, servesRuns: Bool, expected: [RightPaneTab]) {
    #expect(RightPaneTab.peerAvailable(isFolder: isFolder, servesRuns: servesRuns) == expected)
}
```

In `RunTabPresentationTests`:

```swift
/// A peer's row reads as the local one, without Edit or Terminal, and
/// names the host instead of this Mac.
@Test func peerRowsOfferRunStopRerunAndOutputOnly() {
    let script = HostRunScript(scope: .repo, fileName: "dev.sh", name: "Dev Server", cwd: nil, target: RunExecutionTarget(host: nil, workingDirectory: "/wt"))
    let finished = RunTabPresentation.peerRow(
        PeerRuns.Row(script: script, record: record(status: .finished(.failed(exitCode: 42)), finishedAt: epoch.addingTimeInterval(75))),
        hostName: "Studio", now: epoch.addingTimeInterval(75 + 3_600))
    #expect(finished.detail == "exit 42 · 1m 15s · 1h ago")
    #expect(finished.actions == [.start(label: "Rerun"), .showReport(runID: "run-1")])
    #expect(finished.locationDetail == "Studio · /wt")
    let running = RunTabPresentation.peerRow(PeerRuns.Row(script: script, record: record(status: .running)), hostName: "Studio", now: epoch)
    #expect(running.actions == [.stop, .restart])
}
```

- [ ] **Step 2: Implement** the interfaces above. `RunTabView` keeps calling `row(_:now:)` unchanged.

- [ ] **Step 3: Verify**

There is no local run (AlasTests need CI). Run `swift test --package-path Packages/AlasCore --filter PeerRunsTests` to confirm the package still builds. In CI, `-only-testing AlasTests/RightPaneTabTests -only-testing AlasTests/RunTabPresentationTests` must PASS, with both suites named in the `Test run with N tests in M suites` line.

- [ ] **Step 4: Commit**

```bash
git add Alas/Sources/Right/RightPaneState.swift Alas/Sources/Right/RunTabPresentation.swift AlasTests/RightPaneTabTests.swift AlasTests/RunTabPresentationTests.swift
git commit -m "feat(remote): present a peer's run rows with the local Run tab's rules"
```

---

### Task 5: The Run tab in the peer right pane

**Files:**
- Modify: `Alas/Sources/Remote/Native/NativePeerHosts.swift`
- Create: `Alas/Sources/Right/NativePeerRunTabView.swift`
- Modify: `Alas/Sources/Right/NativePeerRightPaneView.swift` (tabs, `shownTab`, `tabContent`, rail count, refresh)
- Modify: `Alas/Sources/Right/RunTabView.swift:492,515` (`RunScopeHeader`, `RunRowView` from `private` to internal)
- Modify: `Alas.xcodeproj/project.pbxproj` (regenerated)

**Interfaces:**
- Consumes: `PeerRuns` (Task 3), `RightPaneTab.peerAvailable(isFolder:servesRuns:)` and `RunTabPresentation.peerRow(_:hostName:now:)` (Task 4), `HostProtocolCapability.runsScriptsV1` (Task 1).
- Produces:
  - `NativePeerHosts` becomes `@Observable` (`@ObservationIgnored` on `onChange`) and gains:
    - `private(set) var runs: [String: [RunRecord]]`, keyed by `serverId`. It is set next to `worktrees` in the channel's `onChange` (`channel.state?.runs`) and cleared in `stop()`.
    - `func servesRuns(serverId: String) -> Bool`, which is `runs[serverId] != nil && supports(serverId, HostProtocolCapability.runsScriptsV1)`.
    - `func runScripts(in worktree: PeerHostWorktree, serverId: String) async -> [HostRunScript]?`. It returns nil when the host does not serve runs, refused, or did not answer.
    - `func perform(_ command: PeerRuns.Command, on row: PeerRuns.Row, in worktree: PeerHostWorktree, serverId: String) async -> PeerRuns.Reply`. When the host does not serve runs it answers `.refused(title: "Run Script Failed", message: FederatedSessionsProvider.peerUnavailableMessage)`.
  - `struct NativePeerRunTabView: View { let hosts: NativePeerHosts; let serverId: String; let worktree: PeerHostWorktree; let hostName: String; let refreshGeneration: Int }`.

- [ ] **Step 1: `NativePeerHosts`.** Both request methods build `WorktreeRef(projectID: worktree.snapshot.worktree.projectId, path: worktree.snapshot.worktree.path.path)` and go through `channels[serverId]?.request`. `perform` is `PeerRuns.perform(command, on: row, in: ref) { await channel.request($0) }`.

- [ ] **Step 2: `NativePeerRunTabView`.**
  - **Loading.** `@State var scripts: [HostRunScript]?` is loaded in `.task(id: "\(serverId)|\(worktree.snapshot.worktree.id)|\(refreshGeneration)")`. Assign it only if `!Task.isCancelled` after the await, so a late listing for a worktree no longer shown is dropped. Show `RightPaneLoadingSkeletonView(activeTab: .run)` until the first answer.
  - **Rows.** Rows are `PeerRuns.rows(scripts:runs: hosts.runs[serverId] ?? [], worktreeID: worktree.snapshot.worktree.id)`, grouped by `RunScriptScope.allCases` under `RunScopeHeader`. Each is a `RunRowView(presentation: RunTabPresentation.peerRow(row, hostName:, now:), onAction:)`, and `now` ticks every 15 s as `RunTabView` does.
  - **Listing failed.** When `scripts` is nil after the answer, show a `NativePeerRailMessage(text: "\(hostName) did not list this worktree's run scripts.")` above any active rows.
  - **No rows.** Show the text "No run scripts yet", then "Add a script to \(RunScriptStore.repoScriptsRelativeDir) on \(hostName) to build, test, or serve this worktree."
  - **Actions.** Map `.start` → `.start`, `.stop` → `.stop`, `.restart` → `.restart` and `.showReport(id)` → `.output(runID: id)`, and ignore the rest. `.refused(t, m)` calls `hosts.showError(t, m)`. `.output(p)` sets `@State var output: PeerRunOutput?` (a private `Identifiable` struct holding `runID`, the script name and `p`), which drives a `.sheet(item:)`.
  - **Output sheet.** The sheet shows the script name as title and the text, monospaced, selectable and scrollable. A truncated text gets "Only the end of the output was kept.", and `.unavailable` gets "This run's output was not kept.". A Close button ends it. There are no endpoint, terminal or edit controls.

- [ ] **Step 3: Wire `NativePeerRightPaneView`.**
  - Compute `let tabs = RightPaneTab.peerAvailable(isFolder: isFolder, servesRuns: runTarget != nil)` once. Here `runTarget` is `(serverId, PeerHostWorktree)` when `client.selectedWorktree`, `client.selectedWorktreeGroup?.host` and `client.hosts?.servesRuns(serverId:)` are all present.
  - Pass `tabs` to the rail and to the `.alasSelectRightPaneTab` guard.
  - Replace `shownTab` with `tabs.contains(activeTab) ? activeTab : tabs[0]`, which keeps the folder rule and drops a `.run` tab the host no longer serves.
  - In `tabContent`, show `.run` with `NativePeerRunTabView(…, hostName: client.selectedWorktreePeer?.name ?? "The host", refreshGeneration:)` ahead of the `canReadWorkspace` gate, because runs do not need a session.
  - Pass `activeRunCount` as the active records of the selected worktree in `hosts.runs`.
  - The toolbar refresh also bumps `@State var runRefreshGeneration`.
  - Update the type's doc comment: Run is offered by hosts that serve scripts.

- [ ] **Step 4: Regenerate and verify.**

Run `xcodegen` from the repo root, then `swift test --package-path Packages/AlasCore --filter 'PeerRunsTests|HostProtocolServerTests|HostProtocolTests'`, which must PASS. CI then runs the app's first full build plus the `RightPaneTabTests` and `RunTabPresentationTests` suites from Task 4.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Remote/Native/NativePeerHosts.swift Alas/Sources/Right/NativePeerRunTabView.swift Alas/Sources/Right/NativePeerRightPaneView.swift Alas/Sources/Right/RunTabView.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(remote): add the Run tab to the peer right pane"
```
