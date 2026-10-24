# Run Consoles on a Headless Host Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On `alas-host` with zmx, every run script runs in a zmx console listed by `HostConsoles`, follows the script's on-exit setting, and opens from the peer Run tab.

**Architecture:** `HostConsoles` becomes the headless `RunLauncher` (installed on `HeadlessHostEnvironment` by `HostConsoles.install`). A run launches exactly as the app hosts one: the user's login shell inside `zmx attach`, with the captured command (`RunScriptCommand`) injected as a startup script by `StartupScriptInstaller.plan`. The command's own ending (`exit` for close, `return` for keep) decides whether the shell and so the zmx session ends. Registry entries gain an optional `scriptKey`; everything else (listing, attach, resize, terminate, removal guards, restore) is #2193's code unchanged. Without zmx, or with a login shell other than zsh/bash, launches fall through to `HeadlessRunLauncher`.

**Tech Stack:** Swift 5.9+, SwiftPM package `Packages/AlasCore` (`AlasHostCore`, `AlasPlatform`), SwiftUI app target (Run tab only), Swift Testing, zmx 0.8.1.

**Spec:** `docs/superpowers/specs/2026-10-24-host-run-consoles-design.md`

## Global Constraints

- Swift Testing (`import Testing`), not XCTest; extend the existing suites (`HostConsolesTests`, run tests in AlasHostTests and AlasCoreContextTests).
- No UI imports in the package: `Packages/AlasCore` must not import SwiftUI, AppKit, WebKit, GhosttyKit, MLX, `TreeSitterPack` or `FffC`; anything the app uses from it is `public`.
- Conventional Commits (`type(scope): summary`) with no attribution of any kind: no `Co-Authored-By` trailers, no "Generated with" footers.
- "No change to how runs behave locally in the app."
- "No undiscoverable daemons. Every run session the host starts is registered before it can outlive the launch, or killed. Reuse #2193's kill-then-forget helper."
- "No regression for older peers. Run consoles are ordinary consoles to them." Old `host-consoles.json` files must still decode.
- "Without zmx, headless runs stay plain processes as today, and no console is listed."
- "Runs for SSH-project worktrees on the headless host. They are refused as today." (`"Remote projects can only run scripts in a terminal."`)
- Session names keep the `alashost-` prefix.
- The app target can't be built on the dev machine: app-side tests (AlasTests) run in CI only; package logic goes RED/GREEN locally with `swift test --package-path Packages/AlasCore`.
- Never synchronize with a fixed `Task.sleep`; use `eventually` (`Tests/AlasCoreTests/TestSupport/Eventually.swift`) or `waitForStartingRunsForTesting()`. Git stays real.
- No new `.serialized`, `@MainActor` beyond the suite's existing one, or `scripts/ci-swift-test-policy.tsv` entries.
- Check the `Test run with N tests in M suites` line; a filter that matches nothing passes silently.

## zmx behaviour (verified on `/Applications/Alas.app/Contents/Resources/zmx/zmx`, 0.8.1, temporary `ZMX_DIR`)

- The session ends when its command exits: the socket is removed within ~100 ms and `zmx ls` no longer lists it. This held for `zmx attach name /bin/sh -c '…'` and for an interactive `zsh -l -i` whose rc file ends in `exit 4`.
- An interactive `zsh -l -i` whose rc file runs a command and then returns stays at a prompt. The session lives on, and `zmx history` still has the command's output. This is the keep behaviour.
- If the command exits before the `attach` client connects (`exit 0` or `true` straight away), `zmx attach` exits **1** with `cannot connect to session "…": FileNotFound`, although the command ran. Anything that takes 300 ms or more returned 0. So a non-zero `attach` does not prove the run never started.
- `zmx kill name` exits 0. The socket is gone at once and the child process gets SIGHUP within about 0.5 s. Killing a session that is already gone exits 1, which `HostConsoles.stop` already treats as stopped because the socket is gone.
- **Mechanism chosen:** no wrapper. The run's shell is the login shell with the captured command as its startup script, exactly as `AppRunLauncher` does it. Its `close` branch ends in `exit "$exit_code"`, which ends the session. Its `keep` branch ends in `return`, which leaves the shell at a prompt with the output above until the console is terminated. A `cmd; exec $SHELL` or read-loop wrapper would mean a second code path that the app doesn't have.

## Review Focus

1. A close-mode script that exits before `zmx attach` connects makes `attach` exit 1. The run's outcome should come from its `.done` file, not read "launch failed". (Task 1, `aRunWhoseAttachFailsSettlesByItsCompletion`)
2. Rerunning a keep-mode script whose finished console is still open should leave one console for the script, not two. (Task 2, `stoppingOrRerunningARunEndsItsConsole(.rerun)`)
3. A peer terminates a running run's console. The run should settle and stop reading Running. (Task 2, `terminatingARunConsoleSettlesItsRun`)
4. The worktree is claimed or deleted while a run's `attach` is in flight. The session should be killed, the launch should fail, and the previous record should be restored. (Task 2, parameterized `aShellLaunchedWhileItsWorktreeGoesIsKilled`)
5. Without zmx, or with a login shell like fish, runs should stay plain processes with no console. (Task 1, `withoutZmxOrAnInjectableShellARunIsAPlainProcess`)

---

### Task 1: Headless runs launch in zmx consoles

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Console/HostConsoles.swift` (entry field, `install`, a `RunLauncher` extension at the bottom of the same file so it reaches the private members)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Console/HostShellLaunch.swift:23-57`
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHostEnvironment.swift:227` (`HeadlessHostEnvironment`)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/HostConsolesTests.swift`

**Interfaces:**
- Consumes: `RunLauncher`, `RunLaunchRequest`, `RunLaunch.hosted(sessionID:)`, `HeadlessRunLauncher.shared` (`AlasCoreContext+Runs.swift`); `StartupScriptInstaller.plan(shell:startupScript:sessionId:) throws -> Plan` and `supportsStartupScriptInjection(shell:)`; `ZmxSessionName.hostShell(worktreeId:consoleId:)`.
- Produces:
  - `HostConsoleEntry.scriptKey: String?` (nil means a shell; absent in #2193 files). Init gains `scriptKey: String? = nil` as the last parameter. Synthesized `Codable` stays: an optional decodes as nil when the key is missing.
  - `HostShellLaunch.make(zmx:sessionName:directory:shell:shellArguments:environmentOverrides: [String: String] = [:], baseEnvironment:) -> HostShellLaunch?`. Overrides are applied after the inherited-key filter, before `TERM`, `COLORTERM` and `ZMX_DIR`.
  - `@_spi(AppHost) public weak var runLauncherOverride: (any RunLauncher)?` on `HeadlessHostEnvironment`, plus `public var runLauncher: any RunLauncher { runLauncherOverride ?? HeadlessRunLauncher.shared }`. Weak, because `HostConsoles` holds `core`, which holds the environment.
  - `extension HostConsoles: RunLauncher` with `refusal(for:in:project:)`, `launch(_:in:)`, `hostSessionExists(_:)` and `hostSessionIsIdle(_:)` in this task (the ending members are in Task 2).
  - The fixture's `Fixture.runScript(onExit:) throws -> RunScript` writes `<worktree>/.alas/scripts/dev.sh` (`exit 0`, display name `"Dev"`, `isExecutable: false`). `Fixture.complete(runID:exitCode:) throws` writes `"<code>\t1.0\n"` to `RunScriptCompletionMonitor.paths(runID:host: nil).paths.completion`. `Fixture.consoles(zmx:shell:)` gains `shell: String = "/bin/zsh"`, and the fixture core is built with `runHostGrace: RunHostGrace(local: .milliseconds(200), any: .milliseconds(200))` (short enough for `eventually`, but not zero, so an already-written `.done` wins over the idle check). Tests install the launcher with `(fixture.core.environment as! HeadlessHostEnvironment).runLauncherOverride = consoles`.

- [ ] **Step 1: Write the failing tests** in `HostConsolesTests` under a new `// MARK: - Runs`

```swift
@Test func aConsolesFileFromBeforeRunsReadsAsShells() throws {
    let json = #"{"consoles":[{"id":"c","worktreeId":"w","title":"Terminal 1","zmxName":"alashost-a-b","rows":24,"columns":120}]}"#
    let file = try JSONDecoder().decode(HostConsolesFile.self, from: Data(json.utf8))
    #expect(file.consoles.map(\.scriptKey) == [nil])
}

@Test func aRunLaunchesInAShellThatSourcesTheCapturedCommand() async throws {
    // fixture + consoles installed as the run launcher; script = fixture.runScript(onExit: .keep)
    // guard case .started(let runID) = fixture.core.startRun(script, in: fixture.worktree); await waitForStartingRunsForTesting()
    let launch = try #require(fixture.launches.first)
    #expect(Array(launch.arguments.dropFirst(2)) == ["/bin/zsh", "-l", "-i"])
    let rc = try String(contentsOfFile: #require(launch.environment["ZDOTDIR"]) + "/.zshrc", encoding: .utf8)
    #expect(rc.contains("__alas_run_script_capture") && rc.contains(script.fileURL.path))
    let record = try #require(fixture.core.runRecords.record(worktreeID: fixture.worktree.id, scriptKey: script.key))
    let summary = try #require(consoles.summaries().first)
    #expect((record.sessionID, summary.title) == (summary.consoleId, "Dev"))
    #expect(try fixture.savedFile()?.consoles.map(\.scriptKey) == [script.key])
    try fixture.complete(runID: runID, exitCode: 0)
    try await eventually { await fixture.core.runRecords.record(worktreeID: fixture.worktree.id, scriptKey: script.key)?.status == .finished(.succeeded) }
    #expect(consoles.summaries().map(\.consoleId) == [summary.consoleId]) // keep: the console stays
}

@Test func aRunWhoseAttachFailsSettlesByItsCompletion() async throws {
    // launchFails = true; startRun → runID; fixture.complete(runID:, exitCode: 3) before awaiting the launch
    #expect(fixture.killed == fixture.launches.map { $0.arguments[1] })
    #expect(consoles.summaries().isEmpty)
    try await eventually { /* record status */ == .finished(.failed(exitCode: 3)) }
}

enum NoConsole: CaseIterable { case noZmx, fish }
@Test(arguments: NoConsole.allCases)
func withoutZmxOrAnInjectableShellARunIsAPlainProcess(_ kind: NoConsole) async throws {
    // consoles(zmx: binaryURL nil when .noZmx, shell: "/opt/homebrew/bin/fish" when .fish), installed as launcher
    #expect(try await fixture.core.runScript(script, in: fixture.worktree) == .succeeded)
    #expect(fixture.launches.isEmpty)
    #expect(consoles.summaries().isEmpty)
    #expect(fixture.core.runRecords.record(worktreeID: fixture.worktree.id, scriptKey: script.key)?.sessionID == nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Packages/AlasCore --filter HostConsolesTests`
Expected: compile failure, because `scriptKey` and `runLauncherOverride` aren't defined yet.

- [ ] **Step 3: Implement the entry field, the `make` overrides, the environment override, and the launcher**

`HostConsoles.install` also sets `(core.environment as? HeadlessHostEnvironment)?.runLauncherOverride = consoles`. `alas-host/main.swift` is unchanged.

`refusal` returns `HeadlessRunLauncher.shared.refusal(for:in:project:)`, which still refuses SSH.

`launch(_ request:in core:)`, in this order:
1. If `!isAvailable || !StartupScriptInstaller.supportsStartupScriptInjection(shell: shell)`, return `try await HeadlessRunLauncher.shared.launch(request, in: core)`.
2. `try admittedWorktree(request.worktree.id)`, then `await ShellEnvResolver.shared.waitUntilResolved()`.
3. Kill and forget earlier consoles for this script with `_ = await stop(entries.filter { $0.worktreeId == … && $0.scriptKey == request.script.key })`. There is one console per script and worktree, as in the app.
4. Set `id = UUID().uuidString` and `name = ZmxSessionName.hostShell(worktreeId:consoleId: id)`. Build `plan = try StartupScriptInstaller.plan(shell: shell, startupScript: request.command, sessionId: id)` and `HostShellLaunch.make(…, shellArguments: plan.args, environmentOverrides: plan.envOverrides, …)`; if `make` returns nil, throw `PeerConsoleOpenError.zmxMissing`.
5. `try await launch(shellLaunch)`. On error, kill the session by name (as `open` does) and **return `.hosted(sessionID: id)`** with no entry. The core's idle check then settles the run by its `.done` file, or as Unknown after the grace period.
6. Check `try admittedWorktree(…)` again. On failure, kill the session and rethrow.
7. With no suspension in between, append `HostConsoleEntry(id:, worktreeId:, title: request.script.displayName, zmxName: name, rows: launchRows, columns: launchColumns, scriptKey: request.script.key)`, `save()`, and return `.hosted(sessionID: id)`.

`hostSessionExists(id)` is `pruneExited(); return entries.contains { $0.id == id }`. `hostSessionIsIdle(id)` is its negation, because a gone socket means the shell exited.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path Packages/AlasCore --filter HostConsolesTests`
Expected: every `HostConsolesTests` test passes (✔), and the run line counts the 4 new tests (5 cases).

- [ ] **Step 5: Commit**

```bash
git add Packages/AlasCore/Sources/AlasHostCore/Remote/Console/HostConsoles.swift Packages/AlasCore/Sources/AlasHostCore/Remote/Console/HostShellLaunch.swift Packages/AlasCore/Sources/AlasHostCore/Core/AlasHostEnvironment.swift Packages/AlasCore/Tests/AlasCoreTests/HostConsolesTests.swift
git commit -m "feat(alas-host): run scripts in zmx consoles"
```

### Task 2: A run's console ends with the run

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Console/HostConsoles.swift` (`restore`, `pruneExited`, `stop`, and the `RunLauncher` extension)
- Modify: `Packages/AlasCore/Sources/AlasPlatform/Zmx/StartupScriptInstaller.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/HostConsolesTests.swift`

**Interfaces:**
- Consumes: Task 1's `scriptKey`, its launcher, and the fixture helpers; `AlasCoreContext.stopRun(scriptKey:in:)`, `restartRun(_:in:)`, and `runHostClosed(sessionID:)`.
- Produces:
  - `private func forget(_ ids: Set<String>)` in `HostConsoles` is the single removal path for `restore`, `pruneExited` and `stop`. It removes the entries and calls `save()`. For each forgotten entry it calls `StartupScriptInstaller.removeArtifacts(sessionId: entry.id)`, and for each run entry also `core.runHostClosed(sessionID: entry.id)`.
  - `public static func removeArtifacts(sessionId: String)` in `StartupScriptInstaller` removes `rcfiles/<id>/` and `rcfiles/<id>.bashrc` under `Paths.appSupportRoot`, best effort. It is the package twin of the app's private `TerminalService.cleanupRcfile`, which stays as it is.
  - `hostsRun(scriptKey:worktreeID:) -> Bool` returns true after `pruneExited()` when an entry matches both. `endRunHost(scriptKey:worktreeID:)` and `endRunHost(sessionID:worktreeID:)` call `Task { await stop(matching) }`, which kills and then forgets. `runHostIsActive` keeps its default, false, because a headless host has no active tab.

- [ ] **Step 1: Write the failing tests**

```swift
enum Ending: CaseIterable { case stop, rerun }
@Test(arguments: Ending.allCases)
func stoppingOrRerunningARunEndsItsConsole(_ ending: Ending) async throws {
    // keep script started and launched; first = consoles.summaries()[0].consoleId; firstName = launches[0].arguments[1]
    // .stop: fixture.core.stopRun(scriptKey: script.key, in: fixture.worktree)
    // .rerun: fixture.complete(runID:, exitCode: 0); await finished; fixture.core.startRun(script, in: fixture.worktree); waitForStartingRunsForTesting()
    try await eventually { await MainActor.run { fixture.killed.first == firstName } }
    let expected = ending == .stop ? 0 : 1
    try await eventually { await MainActor.run { consoles.summaries().count == expected && !consoles.summaries().contains { $0.consoleId == first } } }
    if ending == .stop { #expect(/* record status */ == .finished(.stopped)) }
}

@Test func terminatingARunConsoleSettlesItsRun() async throws {
    // run launched, no .done written
    await consoles.terminate(consoleId)
    try await eventually { /* record status */ == .finished(.unknown) }
}
```

Parameterize the existing `aShellLaunchedWhileItsWorktreeGoesIsKilled` as `@Test(arguments: DuringLaunch.allCases, [false, true]) func …(_ during: DuringLaunch, isRun: Bool)`. For `isRun`, launch with `startRun` instead of `open`, then expect `fixture.core.runRecords.record(worktreeID:scriptKey:) == nil` (rolled back) as well as the existing `killed == launches` names and empty summaries and saved file. The removal side needs no new test: run entries are entries, so `deletingAWorktreeClosesItsShells` and `aProjectWithAnOpenShellIsNotForgotten` already cover them.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Packages/AlasCore --filter HostConsolesTests`
Expected: `stoppingOrRerunningARunEndsItsConsole` fails because nothing is killed, and `terminatingARunConsoleSettlesItsRun` times out on Running.

- [ ] **Step 3: Implement `forget`, `removeArtifacts` and the ending members** with the signatures above. `stop`'s kill-then-forget logic stays the same; only its removal goes through `forget`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path Packages/AlasCore --filter HostConsolesTests`, then `swift test --package-path Packages/AlasCore --filter "AlasHostTests|AlasCoreContextTests|HostProtocolServerTests"` (run behaviour for the other launchers is unchanged).
Expected: all pass (✔), and the run lines name the suites.

- [ ] **Step 5: Commit**

```bash
git add Packages/AlasCore/Sources/AlasHostCore/Remote/Console/HostConsoles.swift Packages/AlasCore/Sources/AlasPlatform/Zmx/StartupScriptInstaller.swift Packages/AlasCore/Tests/AlasCoreTests/HostConsolesTests.swift
git commit -m "feat(alas-host): end a run's console with the run"
```

### Task 3: Run tab opens a host run's console

**Files:**
- Modify: `Alas/Sources/Right/RunTabPresentation.swift:80-101` (`peerRow`)
- Modify: `Alas/Sources/Right/NativePeerRunTabView.swift:6-11,70-73,97-105`
- Modify: `Alas/Sources/Right/NativePeerRightPaneView.swift:98-104`
- Test: `AlasTests/RunTabPresentationTests.swift:300-312` (extend the existing peer test)

**Interfaces:**
- Consumes: `RunRowAction.openTerminal` (already exists, labelled "Terminal" in the row); `RunRecord.sessionID`; `NativePeerConsoles.consoles: [String: [PeerConsoleSummary]]`; `NativePeerSessions.selectConsole(serverId:consoleId:)`, which selects the console and attaches to it.
- Produces:
  - `static func peerRow(_ row: PeerRuns.Row, hostName: String, consoleIds: Set<String>, now: Date) -> RunRowPresentation`, where `hasTerminal = row.record?.sessionID.map(consoleIds.contains) ?? false`.
  - `NativePeerRunTabView` gains `let consoleIds: Set<String>` and `let openConsole: (String) -> Void`. `perform(.openTerminal, on: row)` calls `openConsole(sessionID)` for `row.record?.sessionID` and sends nothing to the host.

- [ ] **Step 1: Extend `peerRowsOfferRunStopRerunAndOutputOnly`** (rename it `peerRowsOfferTheHostsActionsAndItsListedConsole`). Pass `consoleIds: []` to the existing assertions, which stay the same. Add:

```swift
let hosted = PeerRuns.Row(script: script, record: record(status: .running, sessionID: "console-1"))
#expect(RunTabPresentation.peerRow(hosted, hostName: "Studio", consoleIds: ["console-1"], now: epoch).actions == [.stop, .restart, .openTerminal])
#expect(RunTabPresentation.peerRow(hosted, hostName: "Studio", consoleIds: ["other"], now: epoch).actions == [.stop, .restart])
```

If the suite's `record(…)` helper has no `sessionID:` parameter yet, add one defaulting to nil.

- [ ] **Step 2: Implement** `peerRow`'s new parameter and the view's two properties. In `NativePeerRightPaneView`, pass `consoleIds: Set(client.consoles?.consoles[runTarget.serverId]?.map(\.consoleId) ?? [])` and `openConsole: { client.selectConsole(serverId: runTarget.serverId, consoleId: $0) }`.

- [ ] **Step 3: Verify in CI only** (the app can't be built here). After pushing, the CI `build-test` lane must show `RunTabPresentationTests` passing. Before pushing, run `swiftformat --lint Alas/Sources/Right AlasTests/RunTabPresentationTests.swift` if it's installed.

- [ ] **Step 4: Commit**

```bash
git add Alas/Sources/Right/RunTabPresentation.swift Alas/Sources/Right/NativePeerRunTabView.swift Alas/Sources/Right/NativePeerRightPaneView.swift AlasTests/RunTabPresentationTests.swift
git commit -m "feat(remote): open a host run's console from the Run tab"
```

### Task 4: Manual mini smoke (controller)

- [ ] **Step 1:** Install the branch's `alas-host` on the mini, restart it, and pair it from the Mac. Then check each of these:
  1. A keep script (e.g. `npm run dev`) started from the Mac Run tab shows **Terminal**. It opens the live console, and typing reaches it.
  2. When the run finishes, the record reads Succeeded or Failed and the console stays with its output.
  3. **Rerun** leaves exactly one console for the script.
  4. A close script's console disappears when it ends, and its Report shows the output.
  5. **Stop** on a long run removes the console and the record reads Stopped.
  6. Terminating a running run's console from the console list makes the record settle as Unknown.
  7. After `alas-host restart`, a kept console is still listed and attachable.
  8. Deleting the worktree removes its run consoles.
  9. With `ALAS_ZMX_BINARY=/nonexistent`, a run still completes as a plain process and no console is listed.
- [ ] **Step 2:** With the mini's `ZMX_DIR`, `zmx ls --short | grep alashost-` lists only the consoles the Mac shows, and `ls "<profile>/rcfiles"` has no directory for a forgotten console.
