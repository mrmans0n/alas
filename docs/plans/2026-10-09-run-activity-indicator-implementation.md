# Run activity pill and hidden runs: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show live run state in an activity pill next to the tab bar's ▶ button, and let a run script start without a visible console tab.

**Architecture:** A hidden run still opens its terminal session (capture and completion monitoring need it); only its tab carries an in-memory `isHidden` flag that `CenterTabComposition` filters out and `TabsManager.activate` clears. A pure `RunActivityPresentation` turns the worktree's `RunRecord`s and undismissed `RunScriptFailure`s into the pill state and run list; `RunActivityPill` renders it. The `# alas-console:` header sets each script's default; ⌥ in the ▶ menu and ⌥↵ in the ⌘R palette flip it for one launch.

**Tech stack:** Swift 5.9+, SwiftUI (macOS 15), Swift Testing, xcodegen.

**Spec:** `docs/plans/2026-10-09-run-activity-indicator-design.md`

## Global constraints

- Code, comments, logs and UI strings in English.
- Tests use Swift Testing (`import Testing`), never XCTest. Follow the AGENTS.md testing policy: extend existing suites, one behavior per test, `@Test(arguments:)` for variants, no fixed `Task.sleep` synchronization.
- No `.serialized`, `@MainActor` or `scripts/ci-swift-test-policy.tsv` entries beyond what the extended suite already uses.
- New source or test files require running `xcodegen` and committing `Alas.xcodeproj` with them. The project lists files explicitly.
- Commit titles use Conventional Commits. No agent attribution anywhere.
- Focused test command (replace the suite name):
  ```bash
  xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
    -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/<Suite> test
  ```
  Check the `Test run with N tests in M suites` line; a misspelled suite runs nothing and still passes.
- Build-only command:
  ```bash
  xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
    -skipPackagePluginValidation -skipMacroValidation -quiet build
  ```
- In a fresh worktree, initialize submodules first: `git -c protocol.file.allow=always submodule update --init --recursive`.
- Missing or unknown `alas-console` values mean `shown`. A script without the header behaves exactly as today.
- The hidden flag is never persisted.
- The pill's success state lasts 4 seconds. The pill caps at 160 pt.

## Review focus

Inputs the spec implies that are easy to get wrong. Each has a test in the task named.

1. Restarting a run the user opened with ⌥ (console shown on a hidden-by-default script) keeps the console visible. Task 3, `restartKeepsTheCurrentTabVisibility`.
2. Running a hidden script whose previous run already finished (`alas-on-exit: keep` leaves an idle hidden shell) reruns it in the background instead of popping the old console open. Task 3, `runningAFinishedHiddenScriptRerunsItInTheBackground`.
3. Closing the active tab when its neighbor is a hidden run never makes the hidden tab active, and closing the last visible tab leaves no active tab while the hidden run keeps going. Task 2, `closingTheActiveTabNeverSelectsAHiddenTab`.
4. Relaunching the app with a hidden run tab on disk brings it back visible. Task 2, `hiddenFlagIsNotPersisted`.
5. A stopped run or a lost observation after a success does not keep showing the stale success. Task 4, the `.none` rows of `pillFollowsPrecedence`.

---

### Task 1: `alas-console` header

**Files:**
- Modify: `Alas/Sources/RunScripts/RunScript.swift`
- Modify: `Alas/Sources/RunScripts/RunScriptStore.swift:159-177`
- Modify: `Alas/Sources/RunScripts/RunScriptWritingHelp.swift:27-34`
- Test: `AlasTests/RunScriptMetadataTests.swift`

**Interfaces:**
- Produces: `enum RunScriptConsole: String { case shown, hidden; var flipped: RunScriptConsole }`, `RunScript.console: RunScriptConsole` (a `var`, default `.shown`), `RunScript.flippedConsoleRunTitle: String`, `RunScriptMetadata.parse(...)` result field `console`.

- [ ] **Step 1: Write the failing test.** Append to `RunScriptMetadataTests`:

```swift
    @Test(arguments: zip(
        ["# alas-console: hidden\n", "# alas-console: shown\n", "# alas-console: Hidden\n", "echo hi\n"],
        [RunScriptConsole.hidden, .shown, .shown, .shown]
    ))
    func consoleHeaderSetsTheDefault(contents: String, expected: RunScriptConsole) {
        #expect(RunScriptMetadata.parse(fileName: "a.sh", contents: contents).console == expected)
    }
```

- [ ] **Step 2: Run it and confirm it fails to compile** (`RunScriptConsole` is undefined).

Run the focused command with `AlasTests/RunScriptMetadataTests`.

- [ ] **Step 3: Implement.** In `RunScript.swift`, after `RunScriptOnExit`:

```swift
/// Whether a run's terminal tab is shown when the run starts.
enum RunScriptConsole: String, Sendable, Hashable {
    case shown
    /// The tab stays out of the tab strip until something activates it.
    case hidden

    var flipped: RunScriptConsole { self == .shown ? .hidden : .shown }
}
```

In `RunScript`, after `var endpoint: URL?`:

```swift
    /// Declared as `# alas-console:`. ⌥ flips it for one launch.
    var console: RunScriptConsole = .shown
```

and after `var id: String { key }`:

```swift
    /// Menu title for running once against the console default.
    var flippedConsoleRunTitle: String {
        console == .shown ? "Run \(displayName) in Background" : "Run \(displayName) with Console"
    }
```

In `RunScriptMetadata`, change the pattern, the return type and the loop:

```swift
    nonisolated(unsafe) private static let pattern = /^#\s*alas-(name|on-exit|cwd|url|console):\s*(.+?)\s*$/

    static func parse(
        fileName: String,
        contents: String
    ) -> (displayName: String, onExit: RunScriptOnExit, cwd: String?, endpoint: URL?, console: RunScriptConsole) {
        var name: String?
        var onExit = RunScriptOnExit.keep
        var cwd: String?
        var endpoint: URL?
        var console = RunScriptConsole.shown
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false).prefix(headerLineLimit) {
            guard let match = line.firstMatch(of: pattern) else { continue }
            let value = String(match.2)
            switch match.1 {
            case "name":    name = value
            case "on-exit": onExit = RunScriptOnExit(rawValue: value) ?? .keep
            case "cwd":     cwd = value
            case "url":     endpoint = RunEndpointPolicy.endpoint(from: value)
            case "console": console = RunScriptConsole(rawValue: value) ?? .shown
            default:        break
            }
        }
        let fallback = (fileName as NSString).deletingPathExtension
        return (name ?? (fallback.isEmpty ? fileName : fallback), onExit, cwd, endpoint, console)
    }
```

In `RunScriptStore.script(...)`, pass the parsed value:

```swift
            isExecutable: isExecutable,
            endpoint: meta.endpoint,
            console: meta.console
        )
```

In `RunScriptWritingHelp.prompt`, after the `alas-url` explanation line:

```
        # alas-console: hidden
        Use hidden for long-running or noisy scripts I don't need to watch, such as dev servers. Omit it otherwise.
```

- [ ] **Step 4: Run `AlasTests/RunScriptMetadataTests` and confirm it passes.** Also run `AlasTests/RunScriptWritingHelpTests`.

- [ ] **Step 5: Commit.**

```bash
git add Alas/Sources/RunScripts/RunScript.swift Alas/Sources/RunScripts/RunScriptStore.swift \
  Alas/Sources/RunScripts/RunScriptWritingHelp.swift AlasTests/RunScriptMetadataTests.swift
git commit -m "feat(run): parse alas-console header"
```

---

### Task 2: Hidden terminal tabs

**Files:**
- Modify: `Alas/Sources/Center/Tab.swift` (`Tab.isRestorable` area at 123, `TerminalTabState` at 801-882)
- Modify: `Alas/Sources/Center/TabsManager.swift` (`appendTerminal` at 348, `activate` at 2115, `close` at 2179, private helpers near `append` at 2303)
- Modify: `Alas/Sources/Center/CenterPaneView.swift:9-53` (`CenterTabComposition`)
- Test: `AlasTests/TabsManagerTests.swift`, `AlasTests/Workspace/CenterTabCompositionTests.swift`

**Interfaces:**
- Produces: `TerminalTabState.isHidden: Bool` (default `false`, not encoded), `Tab.isHiddenRunTab: Bool`, `TabsManager.appendTerminal(worktreeId:title:sessionId:runScriptKey:isHidden:)` (new `isHidden: Bool = false`). `TabsManager.activate(worktreeId:tabId:)` clears the flag. `CenterTabComposition` never contains hidden tabs.

- [ ] **Step 1: Write the failing tests.** Append to `TabsManagerTests`:

```swift
    @Test func hiddenTerminalStaysInactiveUntilActivated() {
        let mgr = TabsManager()
        let visible = mgr.appendTerminal(worktreeId: "wt", title: "zsh", sessionId: "s1")
        let hidden = mgr.appendTerminal(
            worktreeId: "wt", title: "dev", sessionId: "s2", runScriptKey: "repo:dev.sh", isHidden: true
        )
        #expect(hidden.isHiddenRunTab)
        #expect(mgr.activeTabId(forWorktree: "wt") == visible.id)

        mgr.activate(worktreeId: "wt", tabId: hidden.id)

        #expect(mgr.activeTabId(forWorktree: "wt") == hidden.id)
        #expect(mgr.tabs(forWorktree: "wt").first { $0.id == hidden.id }?.isHiddenRunTab == false)
    }

    @Test func closingTheActiveTabNeverSelectsAHiddenTab() {
        let mgr = TabsManager()
        let left = mgr.appendTerminal(worktreeId: "wt", title: "a", sessionId: "a")
        _ = mgr.appendTerminal(worktreeId: "wt", title: "dev", sessionId: "dev", runScriptKey: "repo:dev.sh", isHidden: true)
        let closing = mgr.appendTerminal(worktreeId: "wt", title: "b", sessionId: "b")
        mgr.close(worktreeId: "wt", tabId: closing.id)
        #expect(mgr.activeTabId(forWorktree: "wt") == left.id)

        _ = mgr.appendTerminal(worktreeId: "only-hidden", title: "dev", sessionId: "dev2", runScriptKey: "repo:dev.sh", isHidden: true)
        let last = mgr.appendTerminal(worktreeId: "only-hidden", title: "c", sessionId: "c")
        mgr.close(worktreeId: "only-hidden", tabId: last.id)
        #expect(mgr.activeTabId(forWorktree: "only-hidden") == nil)
        #expect(mgr.tabs(forWorktree: "only-hidden").count == 1)
    }

    @Test func hiddenFlagIsNotPersisted() throws {
        var state = TerminalTabState(id: "t", title: "dev", sessionId: "s", runScriptKey: "repo:dev.sh")
        state.isHidden = true

        let decoded = try JSONDecoder().decode(Tab.self, from: JSONEncoder().encode(Tab.terminal(state)))

        #expect(!decoded.isHiddenRunTab)
        guard case .terminal(let restored) = decoded else {
            Issue.record("expected terminal tab")
            return
        }
        #expect(restored.runScriptKey == "repo:dev.sh")
    }
```

Append to `CenterTabCompositionTests`:

```swift
    @Test func hiddenRunTabsAreLeftOutOfTheCenter() {
        let visible = Tab.terminal(.init(id: "visible", title: "zsh", sessionId: "s1"))
        var hiddenState = TerminalTabState(id: "hidden", title: "dev", sessionId: "s2", runScriptKey: "repo:dev.sh")
        hiddenState.isHidden = true

        let composition = CenterTabComposition(
            worktreeTabs: [visible, .terminal(hiddenState)],
            activeWorktreeTabId: visible.id
        )

        #expect(composition.tabs.map(\.id) == ["visible"])
        #expect(composition.activeId == "visible")
    }
```

- [ ] **Step 2: Run `AlasTests/TabsManagerTests` and `AlasTests/CenterTabCompositionTests`; confirm they fail to compile** (`isHidden` is undefined).

- [ ] **Step 3: Implement.**

`Tab.swift`, inside `TerminalTabState` after `var runScriptLeafId: String?`:

```swift
    /// Started in the background: kept out of the center until activated.
    /// Deliberately not in `CodingKeys`, so a restored tab comes back visible.
    var isHidden = false
```

`Tab.swift`, inside `enum Tab` after `isRestorable`:

```swift
    /// A run-script terminal started in the background. The center leaves it
    /// out until something activates it.
    var isHiddenRunTab: Bool {
        if case .terminal(let state) = self { return state.isHidden }
        return false
    }
```

`TabsManager.swift`, replace the worktree `appendTerminal`:

```swift
    @discardableResult
    func appendTerminal(
        worktreeId: String,
        title: String,
        sessionId: String,
        runScriptKey: String? = nil,
        isHidden: Bool = false
    ) -> Tab {
        var state = TerminalTabState(id: UUID().uuidString, title: title, sessionId: sessionId, runScriptKey: runScriptKey)
        state.isHidden = isHidden
        let tab = Tab.terminal(state)
        append(tab, to: worktreeId, activate: !isHidden)
        return tab
    }
```

`TabsManager.swift`, replace `activate(worktreeId:tabId:)`:

```swift
    func activate(worktreeId: String, tabId: TabID) {
        var file = byWorktree[worktreeId] ?? TabsFile(tabs: [], activeTabId: nil)
        // The active tab is never hidden: activating a background run's tab reveals it.
        if let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
           case .terminal(var state) = file.tabs[idx], state.isHidden {
            state.isHidden = false
            file.tabs[idx] = .terminal(state)
        }
        file.activeTabId = tabId
        byWorktree[worktreeId] = file
        persist(worktreeId)
    }
```

`TabsManager.swift`, in `close(worktreeId:tabId:)`, replace the `if wasActive { … }` block:

```swift
        if wasActive {
            file.activeTabId = Self.activeTabAfterClosing(at: idx, in: file.tabs)
        }
```

and add next to the private `append`:

```swift
    /// The nearest tab to a closed position, left first, that may become
    /// active. Hidden run tabs never qualify: the active tab is never hidden.
    private static func activeTabAfterClosing(at index: Int, in tabs: [Tab]) -> TabID? {
        let left = tabs[..<index].last { !$0.isHiddenRunTab }
        return (left ?? tabs[index...].first { !$0.isHiddenRunTab })?.id
    }
```

With no hidden tabs this matches the old rule: the left neighbor, or the new first tab when index 0 closed.

`CenterPaneView.swift`, `CenterTabComposition.init(worktreeTabs:activeWorktreeTabId:)`:

```swift
    init(
        worktreeTabs: [Tab],
        activeWorktreeTabId: TabID?
    ) {
        let visible = worktreeTabs.filter { !$0.isHiddenRunTab }
        tabs = visible
        if visible.contains(where: { $0.id == activeWorktreeTabId }) {
            activeId = activeWorktreeTabId
        } else if activeWorktreeTabId != nil {
            activeId = visible.first?.id
        } else {
            activeId = nil
        }
    }
```

In the shared initializer change the first line to:

```swift
        let shared = sharedTabs.filter { $0.isSharedSessionTab && !$0.isHiddenRunTab }
```

- [ ] **Step 4: Run both suites; confirm they pass.** Also run `AlasTests/StartupRecoveryTests` (it pins composition fallback).

- [ ] **Step 5: Commit.**

```bash
git add Alas/Sources/Center/Tab.swift Alas/Sources/Center/TabsManager.swift Alas/Sources/Center/CenterPaneView.swift \
  AlasTests/TabsManagerTests.swift AlasTests/Workspace/CenterTabCompositionTests.swift
git commit -m "feat(tabs): support hidden run-script terminal tabs"
```

---

### Task 3: Launch runs hidden

**Files:**
- Modify: `Alas/Sources/App/AppState.swift:7675-7717` (`openTerminalTabPreparingRemoteZmxIfNeeded`), `:7763-7833` (`openTerminalTab`)
- Modify: `Alas/Sources/App/AppState+RunScripts.swift:249-328` (tab lookups, run/restart/stop/focus), `:408-565` (`launchScript`, `startScriptLaunch`)
- Test: `AlasTests/RunScriptLaunchTests.swift`

**Interfaces:**
- Consumes: Task 1 `RunScriptConsole`, `RunScript.console`. Task 2 `appendTerminal(…, isHidden:)`, `Tab.isHiddenRunTab`, `TabsManager.activate` reveal.
- Produces on `AppState`:
  - `runOrFocusScript(_:in:console: RunScriptConsole? = nil)`
  - `restartScript(_:in:presentsLaunchFailure:console: RunScriptConsole? = nil) -> RunScriptLaunchStart`
  - `launchScript(_:in:presentsLaunchFailure:console: RunScriptConsole? = nil) -> RunScriptLaunchStart`
  - `startScriptLaunch(_:in:presentsLaunchFailure:console: RunScriptConsole? = nil) -> RunScriptLaunchStart`
  - `scriptTab(scriptKey: String, worktreeID: String) -> Tab?`
  - `runningScriptTab(scriptKey: String, worktreeID: String) -> Tab?`
  - `stopScript(scriptKey: String, in: Worktree)`
  - `focusScriptTerminal(scriptKey: String, in: Worktree)`
  - `restartScript(scriptKey: String, in: Worktree)`
  - `openTerminalTabPreparingRemoteZmxIfNeeded(…, isHidden: Bool = false)` and `openTerminalTab(…, isHidden: Bool = false)`

- [ ] **Step 1: Write the failing tests.** Append inside `RunScriptLaunchTests`, before `makeAppStateFixture`:

```swift
    @MainActor
    @Test(arguments: [
        (RunScriptConsole.hidden, RunScriptConsole?.none, true),
        (.shown, .hidden, true),
        (.hidden, .shown, false),
    ])
    func launchConsoleDecidesWhetherTheRunTabTakesFocus(
        scriptDefault: RunScriptConsole,
        override: RunScriptConsole?,
        startsHidden: Bool
    ) async throws {
        let fixture = try makeAppStateFixture(waiter: { _ in
            RunScriptCompletion(exitCode: 0, transcript: nil, truncated: false)
        })
        let other = fixture.state.tabs.appendTerminal(worktreeId: fixture.worktree.id, title: "Other", sessionId: "other")
        var script = fixture.script
        script.console = scriptDefault

        fixture.state.runOrFocusScript(script, in: fixture.worktree, console: override)
        await finishPendingLaunches(fixture.state)
        await fixture.state.waitForRunScriptCompletionTasksForTesting()

        let runTab = try #require(fixture.state.scriptTab(for: script, in: fixture.worktree))
        #expect(runTab.isHiddenRunTab == startsHidden)
        #expect(fixture.state.tabs.activeTabId(forWorktree: fixture.worktree.id) == (startsHidden ? other.id : runTab.id))
    }

    @MainActor
    @Test func runningAFinishedHiddenScriptRerunsItInTheBackground() async throws {
        let fixture = try makeAppStateFixture(waiter: { _ in
            RunScriptCompletion(exitCode: 0, transcript: nil, truncated: false)
        })
        let other = fixture.state.tabs.appendTerminal(worktreeId: fixture.worktree.id, title: "Other", sessionId: "other")
        var script = fixture.script
        script.console = .hidden
        fixture.state.runOrFocusScript(script, in: fixture.worktree)
        await finishPendingLaunches(fixture.state)
        await fixture.state.waitForRunScriptCompletionTasksForTesting()
        let firstRunID = try #require(fixture.state.runRecords.record(worktreeID: fixture.worktree.id, scriptKey: script.key)?.id)

        fixture.state.runOrFocusScript(script, in: fixture.worktree)
        await finishPendingLaunches(fixture.state)
        await fixture.state.waitForRunScriptCompletionTasksForTesting()

        let record = try #require(fixture.state.runRecords.record(worktreeID: fixture.worktree.id, scriptKey: script.key))
        #expect(record.id != firstRunID)
        let runTabs = fixture.state.tabs.tabs(forWorktree: fixture.worktree.id).filter { tab in
            guard case .terminal(let state) = tab else { return false }
            return state.runScriptKey == script.key
        }
        #expect(runTabs.count == 1)
        #expect(runTabs.first?.isHiddenRunTab == true)
        #expect(fixture.state.tabs.activeTabId(forWorktree: fixture.worktree.id) == other.id)
    }

    @MainActor
    @Test func restartKeepsTheCurrentTabVisibility() async throws {
        let fixture = try makeAppStateFixture(waiter: { _ in
            RunScriptCompletion(exitCode: 0, transcript: nil, truncated: false)
        })
        var script = fixture.script
        script.console = .hidden
        fixture.state.runOrFocusScript(script, in: fixture.worktree, console: .shown)
        await finishPendingLaunches(fixture.state)
        await fixture.state.waitForRunScriptCompletionTasksForTesting()

        fixture.state.restartScript(script, in: fixture.worktree)
        await finishPendingLaunches(fixture.state)
        await fixture.state.waitForRunScriptCompletionTasksForTesting()

        let runTab = try #require(fixture.state.scriptTab(for: script, in: fixture.worktree))
        #expect(!runTab.isHiddenRunTab)
        #expect(fixture.state.tabs.activeTabId(forWorktree: fixture.worktree.id) == runTab.id)
    }
```

- [ ] **Step 2: Run `AlasTests/RunScriptLaunchTests`; confirm it fails to compile** (`console:` argument does not exist).

- [ ] **Step 3: Thread `isHidden` through terminal opening.** In `AppState.swift`, add a trailing parameter `isHidden: Bool = false` to both `openTerminalTabPreparingRemoteZmxIfNeeded` and `openTerminalTab`. Pass it along in the former's `return try openTerminalTab(…, runScriptKey: runScriptKey, isHidden: isHidden)`, and in the latter change the append to:

```swift
        let tab = tabs.appendTerminal(
            worktreeId: worktree.id, title: title, sessionId: opened.id,
            runScriptKey: runScriptKey, isHidden: isHidden
        )
```

- [ ] **Step 4: Replace the lookup/run/restart/stop/focus block** in `AppState+RunScripts.swift` (from the `scriptTab` doc comment at 249 through `focusScriptTerminal` at 328) with:

```swift
    /// The tab hosting this script in this worktree, live session or not.
    /// Stopping or restarting has to reach a stale tab too — otherwise a
    /// relaunch would leave the old one stranded beside the new one.
    func scriptTab(for script: RunScript, in worktree: Worktree) -> Tab? {
        scriptTab(scriptKey: script.key, worktreeID: worktree.id)
    }

    func scriptTab(scriptKey: String, worktreeID: String) -> Tab? {
        tabs.tabs(forWorktree: worktreeID).first { tab in
            guard case .terminal(let state) = tab else { return false }
            return state.runScriptKey == scriptKey
        }
    }

    /// The script's tab *with a live shell behind it*. Used to decide whether
    /// there is a terminal worth jumping to — never to decide whether the
    /// command itself is still running; `runRecords` owns that.
    func runningScriptTab(for script: RunScript, in worktree: Worktree) -> Tab? {
        runningScriptTab(scriptKey: script.key, worktreeID: worktree.id)
    }

    func runningScriptTab(scriptKey: String, worktreeID: String) -> Tab? {
        tabs.tabs(forWorktree: worktreeID).first { tab in
            guard case .terminal(let state) = tab,
                  state.runScriptKey == scriptKey,
                  let runScriptLeafId = state.runScriptLeafId,
                  let leaf = state.root.find(leafId: runScriptLeafId)?.leaf
            else { return false }
            return terminal.registry.session(for: leaf.sessionId) != nil
        }
    }

    /// Enter/click semantics: focus the script's open tab when it exists,
    /// otherwise launch a new one. One tab per (script, worktree).
    /// `console` overrides the script's `alas-console` default for this run.
    func runOrFocusScript(_ script: RunScript, in worktree: Worktree, console: RunScriptConsole? = nil) {
        if let existing = scriptTab(for: script, in: worktree), existing.isHiddenRunTab,
           runRecords.record(worktreeID: worktree.id, scriptKey: script.key)?.status.isActive != true {
            // An idle background console was never shown; rerun instead of
            // popping it open.
            restartScript(script, in: worktree, console: console)
            return
        }
        if let existing = runningScriptTab(for: script, in: worktree) {
            // Activation reveals a hidden tab: clicking a running script means "show me".
            activateWorktreeCenterTab(worktreeId: worktree.id, tabId: existing.id)
            return
        }
        launchScript(script, in: worktree, console: console)
    }

    /// Restart repeats the run the way it was shown: without an explicit
    /// `console`, an existing tab's visibility wins over the script default.
    @discardableResult
    func restartScript(
        _ script: RunScript,
        in worktree: Worktree,
        presentsLaunchFailure: Bool = true,
        console: RunScriptConsole? = nil
    ) -> RunScriptLaunchStart {
        let launchKey = PendingRunScriptLaunchKey(worktreeID: worktree.id, scriptKey: script.key)
        if pendingScriptLaunches[launchKey] != nil {
            stopScript(script, in: worktree)
            return launchScript(script, in: worktree, presentsLaunchFailure: presentsLaunchFailure, console: console)
        }
        var resolvedConsole = console
        if let existing = scriptTab(for: script, in: worktree) {
            resolvedConsole = resolvedConsole ?? (existing.isHiddenRunTab ? .hidden : .shown)
            let capture = stoppedRunHistoryCapture(worktreeID: worktree.id, scriptKey: script.key)
            let finalized = runRecords.markStopped(worktreeID: worktree.id, scriptKey: script.key, at: Date())
            archiveFinalizedRun(finalized, capture: capture)
            closeTab(worktreeId: worktree.id, tabId: existing.id)
        }
        return launchScript(script, in: worktree, presentsLaunchFailure: presentsLaunchFailure, console: resolvedConsole)
    }

    /// Restart from a run record, which only knows the script key. Resolves
    /// the script with the same scan the ▶ menu uses.
    func restartScript(scriptKey: String, in worktree: Worktree) {
        guard let script = RunScriptStore.scripts(worktreeRoot: worktree.path).first(where: { $0.key == scriptKey }) else {
            showFileActionError(title: "Run Script Failed", message: "This script no longer exists.")
            return
        }
        restartScript(script, in: worktree)
    }

    func stopScript(_ script: RunScript, in worktree: Worktree) {
        stopScript(scriptKey: script.key, in: worktree)
    }

    /// Stop an in-flight run by closing the terminal that hosts it. The record
    /// is marked stopped *before* the close so the monitor-cancellation path
    /// can't relabel a deliberate stop as a lost process.
    func stopScript(scriptKey: String, in worktree: Worktree) {
        let launchKey = PendingRunScriptLaunchKey(worktreeID: worktree.id, scriptKey: scriptKey)
        if let pending = pendingScriptLaunches.removeValue(forKey: launchKey) {
            let finalized = runRecords.markStopped(worktreeID: worktree.id, scriptKey: scriptKey, at: Date())
            archiveFinalizedRun(finalized, capture: .unavailable)
            pendingScriptLaunchTasks.removeValue(forKey: pending.id)?.cancel()
            return
        }
        guard let existing = scriptTab(scriptKey: scriptKey, worktreeID: worktree.id) else {
            // Nothing left to stop: whatever we thought was running is gone,
            // and we never saw it exit.
            let finalized = runRecords.markLostObservation(worktreeID: worktree.id, scriptKey: scriptKey, at: Date())
            archiveFinalizedRun(finalized, capture: .unavailable)
            return
        }
        let capture = stoppedRunHistoryCapture(worktreeID: worktree.id, scriptKey: scriptKey)
        let finalized = runRecords.markStopped(worktreeID: worktree.id, scriptKey: scriptKey, at: Date())
        archiveFinalizedRun(finalized, capture: capture)
        closeTab(worktreeId: worktree.id, tabId: existing.id)
    }

    func focusScriptTerminal(_ script: RunScript, in worktree: Worktree) {
        focusScriptTerminal(scriptKey: script.key, in: worktree)
    }

    /// Reveal the terminal a run is (or was) hosted in. Scoped to `worktree`
    /// so a same-named script in another worktree is never focused.
    /// Activation also un-hides a background run's tab.
    func focusScriptTerminal(scriptKey: String, in worktree: Worktree) {
        guard let existing = runningScriptTab(scriptKey: scriptKey, worktreeID: worktree.id) else { return }
        activateWorktreeCenterTab(worktreeId: worktree.id, tabId: existing.id)
    }
```

- [ ] **Step 5: Pass the console into the launch.** In `launchScript`, add the trailing parameter and forward it:

```swift
    @discardableResult
    func launchScript(
        _ script: RunScript,
        in worktree: Worktree,
        presentsLaunchFailure: Bool = true,
        console: RunScriptConsole? = nil
    ) -> RunScriptLaunchStart {
        let result = startScriptLaunch(script, in: worktree, presentsLaunchFailure: presentsLaunchFailure, console: console)
```

In `startScriptLaunch`, add `console: RunScriptConsole? = nil` as the last parameter. Directly above `let launchID = UUID()`, add:

```swift
        let isHidden = (console ?? script.console) == .hidden
```

and pass it to the opener inside the task:

```swift
                    let tab = try await openTerminalTabPreparingRemoteZmxIfNeeded(
                        for: worktree,
                        startupScriptSuffix: suffix,
                        includeUserStartupScript: true,
                        titleOverride: script.displayName,
                        runScriptKey: script.key,
                        isHidden: isHidden
                    )
```

Scheduled runs (`AppState+RunSchedules.swift`), plugins (`AppState+Plugins.swift`) and the Run tab keep calling without `console:`, so they follow the header.

- [ ] **Step 6: Run `AlasTests/RunScriptLaunchTests`, `AlasTests/AppStateRunRecordTests` and `AlasTests/AppStateRunScheduleTests`; confirm all pass.**

- [ ] **Step 7: Commit.**

```bash
git add Alas/Sources/App/AppState.swift Alas/Sources/App/AppState+RunScripts.swift AlasTests/RunScriptLaunchTests.swift
git commit -m "feat(run): launch scripts with a hidden console"
```

---

### Task 4: Activity presentation

**Files:**
- Create: `Alas/Sources/RunScripts/RunActivityPresentation.swift`
- Create: `AlasTests/RunActivityPresentationTests.swift`
- Modify: `Alas.xcodeproj` (regenerated)

**Interfaces:**
- Consumes: `RunRecord`, `RunStatus`, `RunOutcome` (`RunRecord.swift`), `RunScriptFailure` (`RunScriptFailure.swift`).
- Produces: `RunActivityInput`, `RunActivityPresentation` with `Pill`, `Row`, `RowAction`, `make(input:now:)`, `successLinger`.

- [ ] **Step 1: Write the failing tests** in `AlasTests/RunActivityPresentationTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

struct RunActivityPresentationTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 1_000)

    private static func record(
        _ name: String,
        _ status: RunStatus,
        started: TimeInterval = -60,
        finished: TimeInterval? = nil
    ) -> RunRecord {
        RunRecord(
            id: "run-\(name)",
            scriptKey: "repo:\(name).sh",
            scriptName: name,
            worktreeID: "wt",
            branch: "main",
            target: RunExecutionTarget(host: nil, workingDirectory: "/wt"),
            status: status,
            startedAt: now.addingTimeInterval(started),
            finishedAt: finished.map { now.addingTimeInterval($0) }
        )
    }

    private static func failure(_ name: String, completed: TimeInterval = -30) -> RunScriptFailure {
        RunScriptFailure(
            id: "failure-\(name)",
            runID: "run-\(name)",
            scriptKey: "repo:\(name).sh",
            scriptName: name,
            worktreeID: "wt",
            branch: "main",
            exitCode: 1,
            completedAt: now.addingTimeInterval(completed)
        )
    }

    struct PillCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let input: RunActivityInput
        let pill: RunActivityPresentation.Pill
        let flagsFailure: Bool
    }

    static let pillCases: [PillCase] = [
        PillCase(
            testDescription: "one active run wins over a failure and flags it",
            input: RunActivityInput(records: [record("dev", .running)], failures: [failure("build")]),
            pill: .running(scriptKey: "repo:dev.sh", name: "dev", startedAt: now.addingTimeInterval(-60)),
            flagsFailure: true
        ),
        PillCase(
            testDescription: "several active runs collapse to a count",
            input: RunActivityInput(records: [record("dev", .running), record("web", .starting, started: -1)]),
            pill: .runningMany(count: 2),
            flagsFailure: false
        ),
        PillCase(
            testDescription: "a single starting run",
            input: RunActivityInput(records: [record("web", .starting, started: -1)]),
            pill: .starting(scriptKey: "repo:web.sh", name: "web"),
            flagsFailure: false
        ),
        PillCase(
            testDescription: "an undismissed failure wins over a recent success",
            input: RunActivityInput(
                records: [record("test", .finished(.succeeded), finished: -1)],
                failures: [failure("build")]
            ),
            pill: .failed(failureID: "failure-build", runID: "run-build", name: "build", exitCode: 1),
            flagsFailure: false
        ),
        PillCase(
            testDescription: "a recent success",
            input: RunActivityInput(records: [record("test", .finished(.succeeded), finished: -1)]),
            pill: .succeeded(name: "test", duration: 59),
            flagsFailure: false
        ),
        PillCase(
            testDescription: "a later stop hides an earlier success",
            input: RunActivityInput(records: [
                record("test", .finished(.succeeded), finished: -2),
                record("lint", .finished(.stopped), finished: -1),
            ]),
            pill: .none,
            flagsFailure: false
        ),
        PillCase(
            testDescription: "a lost observation shows nothing",
            input: RunActivityInput(records: [record("lint", .finished(.unknown), finished: -1)]),
            pill: .none,
            flagsFailure: false
        ),
    ]

    @Test(arguments: pillCases)
    func pillFollowsPrecedence(_ testCase: PillCase) {
        let presentation = RunActivityPresentation.make(input: testCase.input, now: Self.now)
        #expect(presentation.pill == testCase.pill)
        #expect(presentation.hasUndismissedFailure == testCase.flagsFailure)
    }

    @Test func successLingersForFourSeconds() {
        let justInside = RunActivityPresentation.make(
            input: RunActivityInput(records: [Self.record("test", .finished(.succeeded), finished: -3.5)]),
            now: Self.now
        )
        #expect(justInside.pill == .succeeded(name: "test", duration: 56.5))
        #expect(justInside.expiresAt == Self.now.addingTimeInterval(0.5))

        let expired = RunActivityPresentation.make(
            input: RunActivityInput(records: [Self.record("test", .finished(.succeeded), finished: -4)]),
            now: Self.now
        )
        #expect(expired.pill == .none)
        #expect(expired.expiresAt == nil)
    }

    @Test func rowsListActiveRunsBeforeFailuresAndOfferOutputOnlyForLiveTerminals() {
        let presentation = RunActivityPresentation.make(
            input: RunActivityInput(
                records: [Self.record("dev", .running, started: -120), Self.record("lint", .running, started: -5)],
                failures: [Self.failure("build", completed: -50), Self.failure("test", completed: -10)],
                liveTerminalKeys: ["repo:dev.sh"]
            ),
            now: Self.now
        )
        #expect(presentation.rows.map(\.name) == ["lint", "dev", "test", "build"])
        #expect(presentation.rows.map(\.actions) == [
            [.restart, .stop],
            [.output, .restart, .stop],
            [.report, .rerun],
            [.report, .rerun],
        ])
    }
}
```

The times are chosen to be exact in binary floating point (`1000 − 3.5 = 996.5`, `996.5 − 940 = 56.5`), so `==` is safe. Exactly 4 s after finishing, the success is gone (`now < finishedAt + 4` is false).

- [ ] **Step 2: Create an empty `Alas/Sources/RunScripts/RunActivityPresentation.swift` (`import Foundation`), run `xcodegen`, then run `AlasTests/RunActivityPresentationTests` and confirm it fails to compile.**

- [ ] **Step 3: Implement** `RunActivityPresentation.swift`:

```swift
import Foundation

/// What the tab bar's run activity pill reads: the selected worktree's runs.
struct RunActivityInput: Equatable, Sendable {
    var records: [RunRecord] = []
    /// Undismissed failures, the same ones the failure banner shows.
    var failures: [RunScriptFailure] = []
    /// Script keys whose run tab still has a live shell to show.
    var liveTerminalKeys: Set<String> = []
}

/// Pure decision for the activity pill and its run list.
struct RunActivityPresentation: Equatable {
    enum Pill: Equatable, Sendable {
        case none
        case starting(scriptKey: String, name: String)
        case running(scriptKey: String, name: String, startedAt: Date)
        case runningMany(count: Int)
        case succeeded(name: String, duration: TimeInterval)
        case failed(failureID: String, runID: String, name: String, exitCode: Int32)
    }

    enum RowAction: Hashable, Sendable {
        case output, restart, stop, report, rerun

        var title: String {
            switch self {
            case .output:  "Output"
            case .restart: "Restart"
            case .stop:    "Stop"
            case .report:  "Report"
            case .rerun:   "Rerun"
            }
        }
    }

    struct Row: Equatable, Identifiable {
        enum Kind: Equatable {
            case starting
            case running
            case failed(exitCode: Int32)
        }

        let runID: String
        let scriptKey: String
        let name: String
        let kind: Kind
        /// Start time for active runs, completion time for failures.
        let since: Date
        let actions: [RowAction]

        var id: String { runID }
    }

    /// How long a success stays on the pill.
    static let successLinger: TimeInterval = 4

    let pill: Pill
    /// A failure is waiting while runs are active; the pill marks it.
    let hasUndismissedFailure: Bool
    let rows: [Row]
    /// When the pill changes without new input: the end of a success linger.
    let expiresAt: Date?

    static func make(input: RunActivityInput, now: Date) -> RunActivityPresentation {
        let active = input.records
            .filter(\.status.isActive)
            .sorted { $0.startedAt > $1.startedAt }
        let failures = input.failures.sorted { $0.completedAt > $1.completedAt }
        let activeRows = active.map { record in
            Row(
                runID: record.id,
                scriptKey: record.scriptKey,
                name: record.scriptName,
                kind: record.status == .starting ? .starting : .running,
                since: record.startedAt,
                actions: (input.liveTerminalKeys.contains(record.scriptKey) ? [.output] : []) + [.restart, .stop]
            )
        }
        let failureRows = failures.map { failure in
            Row(
                runID: failure.runID,
                scriptKey: failure.scriptKey,
                name: failure.scriptName,
                kind: .failed(exitCode: failure.exitCode),
                since: failure.completedAt,
                actions: [.report, .rerun]
            )
        }

        var expiresAt: Date?
        let pill: Pill
        switch active.count {
        case 0:
            if let failure = failures.first {
                pill = .failed(failureID: failure.id, runID: failure.runID, name: failure.scriptName, exitCode: failure.exitCode)
            } else if let (success, finishedAt) = recentSuccess(in: input.records, now: now) {
                pill = .succeeded(name: success.scriptName, duration: finishedAt.timeIntervalSince(success.startedAt))
                expiresAt = finishedAt.addingTimeInterval(successLinger)
            } else {
                pill = .none
            }
        case 1:
            let run = active[0]
            pill = run.status == .starting
                ? .starting(scriptKey: run.scriptKey, name: run.scriptName)
                : .running(scriptKey: run.scriptKey, name: run.scriptName, startedAt: run.startedAt)
        default:
            pill = .runningMany(count: active.count)
        }

        return RunActivityPresentation(
            pill: pill,
            hasUndismissedFailure: !active.isEmpty && !failures.isEmpty,
            rows: activeRows + failureRows,
            expiresAt: expiresAt
        )
    }

    /// The newest finished run, when it succeeded inside the linger window.
    /// A later stop, failure or lost run hides an earlier success.
    private static func recentSuccess(in records: [RunRecord], now: Date) -> (RunRecord, Date)? {
        guard let (newest, finishedAt) = records
            .compactMap({ record in record.finishedAt.map { (record, $0) } })
            .max(by: { $0.1 < $1.1 }),
              newest.status == .finished(.succeeded),
              now < finishedAt.addingTimeInterval(successLinger)
        else { return nil }
        return (newest, finishedAt)
    }
}
```

If the compiler rejects tuple destructuring in `if let (a, b) = …` / `guard let (a, b) = …`, bind the tuple to one name and read `.0`/`.1`.

- [ ] **Step 4: Run `AlasTests/RunActivityPresentationTests`; confirm 3 tests (9 cases) pass.**

- [ ] **Step 5: Commit.**

```bash
git add Alas/Sources/RunScripts/RunActivityPresentation.swift AlasTests/RunActivityPresentationTests.swift Alas.xcodeproj
git commit -m "feat(run): derive run activity pill state"
```

---

### Task 5: Activity pill and ⌥ menu items in the tab bar

**Files:**
- Create: `Alas/Sources/Center/RunActivityPill.swift`
- Modify: `Alas/Sources/Center/TabBarView.swift:44-49` (properties), `:108-116` (trailing controls), `:579-622` (`RunScriptMenu`)
- Modify: `Alas/Sources/Center/CenterPaneView.swift:355-360` (TabBarView arguments) and a new private helper
- Modify: `AlasTests/TouchTargetSmokeTests.swift` (six `onRunScript:` closures)
- Modify: `Alas.xcodeproj` (regenerated)

**Interfaces:**
- Consumes: Task 3 key-based `AppState` methods, Task 4 `RunActivityInput`/`RunActivityPresentation`, Task 1 `RunScript.flippedConsoleRunTitle`, `RunScriptConsole.flipped`.
- Produces: `RunActivityActions`, `RunActivityPill(input:actions:)`. `TabBarView.onRunScript` becomes `(RunScript, RunScriptConsole?) -> Void`; new `TabBarView.runActivity: RunActivityInput` and `runActivityActions: RunActivityActions`, both defaulted.

This task is UI wiring and composition, so per the testing policy it adds no tests. It is verified by the build, the existing touch-target smoke suite, and Task 7.

- [ ] **Step 1: Create `Alas/Sources/Center/RunActivityPill.swift`:**

```swift
import SwiftUI

/// What the activity pill and its run list can do. Runs are addressed by
/// script key, reports by run ID, failures by failure ID.
struct RunActivityActions {
    var stop: (String) -> Void = { _ in }
    var restart: (String) -> Void = { _ in }
    var showOutput: (String) -> Void = { _ in }
    var showReport: (String) -> Void = { _ in }
    var dismissFailure: (String) -> Void = { _ in }
}

/// Xcode-style activity pill beside ▶: what is running, for how long, and
/// how the last run ended. Clicking it opens the run list.
struct RunActivityPill: View {
    let input: RunActivityInput
    let actions: RunActivityActions

    @Environment(\.theme) private var theme
    @State private var showsRuns = false
    /// Bumped when a success linger ends so `body` re-reads the clock.
    @State private var clockTick = 0

    var body: some View {
        let _ = clockTick
        let presentation = RunActivityPresentation.make(input: input, now: Date())
        if presentation.pill != .none {
            pill(presentation)
        }
    }

    private func pill(_ presentation: RunActivityPresentation) -> some View {
        HStack(spacing: 2) {
            Button { showsRuns.toggle() } label: {
                HStack(spacing: 5) {
                    leadingMark(presentation)
                    summary(presentation.pill)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show runs")
            trailingButton(presentation.pill)
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.color(isFailure(presentation.pill) ? "del" : "fg"))
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .frame(height: 20)
        .frame(maxWidth: 160)
        .background(Capsule().fill(tint(presentation.pill).opacity(0.14)))
        .background(Capsule().fill(theme.color("bg-2")))
        .popover(isPresented: $showsRuns, arrowEdge: .bottom) {
            RunActivityList(rows: presentation.rows, actions: actions) { showsRuns = false }
        }
        .task(id: presentation.expiresAt) {
            guard let expiresAt = presentation.expiresAt else { return }
            do {
                try await Task.sleep(for: .seconds(max(0, expiresAt.timeIntervalSinceNow)))
            } catch {
                return
            }
            clockTick &+= 1
        }
        .accessibilityIdentifier("run-activity-pill")
    }

    @ViewBuilder
    private func leadingMark(_ presentation: RunActivityPresentation) -> some View {
        switch presentation.pill {
        case .starting:
            ProgressView().controlSize(.mini)
        case .running, .runningMany:
            Circle()
                .fill(theme.color(presentation.hasUndismissedFailure ? "del" : "add"))
                .frame(width: 7, height: 7)
        case .succeeded:
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.color("add"))
        case .failed:
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func summary(_ pill: RunActivityPresentation.Pill) -> some View {
        switch pill {
        case .starting(_, let name):
            Text(name).lineLimit(1)
            Text("Starting…").foregroundStyle(theme.color("fg-muted"))
        case .running(_, let name, let startedAt):
            Text(name).lineLimit(1)
            Text(startedAt, style: .timer).monospacedDigit().foregroundStyle(theme.color("fg-muted"))
        case .runningMany(let count):
            Text("\(count) running")
        case .succeeded(let name, let duration):
            Text(name).lineLimit(1)
            Text(Duration.seconds(duration).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
                .foregroundStyle(theme.color("fg-muted"))
        case .failed(_, _, let name, let exitCode):
            Text(name).lineLimit(1)
            Text("exit \(exitCode)").opacity(0.75)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func trailingButton(_ pill: RunActivityPresentation.Pill) -> some View {
        switch pill {
        case .starting(let scriptKey, _), .running(let scriptKey, _, _):
            iconButton("stop.fill", help: "Stop") { actions.stop(scriptKey) }
        case .runningMany:
            iconButton("chevron.down", help: "Show runs") { showsRuns.toggle() }
        case .failed(let failureID, _, _, _):
            iconButton("xmark", help: "Dismiss") { actions.dismissFailure(failureID) }
        case .succeeded, .none:
            EmptyView()
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.color("fg-muted"))
        .help(help)
    }

    private func isFailure(_ pill: RunActivityPresentation.Pill) -> Bool {
        if case .failed = pill { return true }
        return false
    }

    private func tint(_ pill: RunActivityPresentation.Pill) -> Color {
        switch pill {
        case .failed: theme.color("del")
        case .succeeded: theme.color("add")
        default: .clear
        }
    }
}

/// The popover behind the pill: active runs, then undismissed failures.
private struct RunActivityList: View {
    let rows: [RunActivityPresentation.Row]
    let actions: RunActivityActions
    let dismiss: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    mark(row.kind)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name).font(.system(size: 12)).lineLimit(1)
                        detail(row)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.color("fg-muted"))
                    }
                    Spacer(minLength: 12)
                    ForEach(row.actions, id: \.self) { action in
                        Button(action.title) { perform(action, on: row) }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
        }
        .padding(6)
        .frame(minWidth: 280)
    }

    @ViewBuilder
    private func mark(_ kind: RunActivityPresentation.Row.Kind) -> some View {
        switch kind {
        case .starting:
            ProgressView().controlSize(.mini)
        case .running:
            Circle().fill(theme.color("add")).frame(width: 7, height: 7)
        case .failed:
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.color("del"))
        }
    }

    @ViewBuilder
    private func detail(_ row: RunActivityPresentation.Row) -> some View {
        switch row.kind {
        case .starting:
            Text("Starting…")
        case .running:
            Text(row.since, style: .timer).monospacedDigit()
        case .failed(let exitCode):
            Text("exit \(exitCode) · \(row.since, style: .relative) ago")
        }
    }

    private func perform(_ action: RunActivityPresentation.RowAction, on row: RunActivityPresentation.Row) {
        dismiss()
        switch action {
        case .output:          actions.showOutput(row.scriptKey)
        case .restart, .rerun: actions.restart(row.scriptKey)
        case .stop:            actions.stop(row.scriptKey)
        case .report:          actions.showReport(row.runID)
        }
    }
}
```

Run `xcodegen`.

- [ ] **Step 2: TabBarView properties.** Replace `let onRunScript: (RunScript) -> Void` with:

```swift
    /// `nil` console runs with the script's `alas-console` default.
    let onRunScript: (RunScript, RunScriptConsole?) -> Void
```

and after `let onEditScripts: () -> Void` add:

```swift
    var runActivity = RunActivityInput()
    var runActivityActions = RunActivityActions()
```

- [ ] **Step 3: TabBarView trailing controls.** Replace the `RunScriptMenu(…)` call and its `.padding(.trailing, …)` with:

```swift
        HStack(spacing: 4) {
            RunScriptMenu(
                loadScripts: loadRunScripts,
                isRunning: isScriptRunning,
                onRun: onRunScript,
                onRestart: onRestartScript,
                onNew: onNewRunScript,
                onEdit: onEditScripts
            )
            RunActivityPill(input: runActivity, actions: runActivityActions)
        }
        .padding(.trailing, rightSidebarHidden && pluginCommands.isEmpty ? 2 : 8)
```

- [ ] **Step 4: ⌥ alternates in `RunScriptMenu`.** Change `let onRun: (RunScript) -> Void` to `let onRun: (RunScript, RunScriptConsole?) -> Void`, and replace the script `Button { onRun(script) } label: { … }` with:

```swift
                            Button {
                                onRun(script, nil)
                            } label: {
                                if running {
                                    Label(script.displayName, systemImage: "circle.fill")
                                } else {
                                    Text(script.displayName)
                                }
                            }
                            .modifierKeyAlternate(.option) {
                                Button(script.flippedConsoleRunTitle) { onRun(script, script.console.flipped) }
                            }
```

- [ ] **Step 5: Wire CenterPaneView.** Change the run arguments of `TabBarView(…)`:

```swift
                onRunScript: { script, console in state.runOrFocusScript(script, in: worktree, console: console) },
                onRestartScript: { script in state.restartScript(script, in: worktree) },
                onNewRunScript: { scope in state.newRunScript(scope: scope, in: worktree) },
                onEditScripts: { state.openRunScriptPaletteOverlay(mode: .edit) },
                runActivity: runActivityInput(for: worktree),
                runActivityActions: RunActivityActions(
                    stop: { state.stopScript(scriptKey: $0, in: worktree) },
                    restart: { state.restartScript(scriptKey: $0, in: worktree) },
                    showOutput: { state.focusScriptTerminal(scriptKey: $0, in: worktree) },
                    showReport: { state.openRunReport(worktreeID: worktree.id, runID: $0) },
                    dismissFailure: { state.dismissRunScriptFailure(id: $0, worktreeID: worktree.id) }
                ),
```

and add a private helper in `CenterPaneView`:

```swift
    private func runActivityInput(for worktree: Worktree) -> RunActivityInput {
        let records = state.runRecords.records(worktreeID: worktree.id)
        return RunActivityInput(
            records: records,
            failures: state.runScriptFailures(in: worktree.id),
            liveTerminalKeys: Set(records.filter(\.status.isActive).map(\.scriptKey).filter {
                state.runningScriptTab(scriptKey: $0, worktreeID: worktree.id) != nil
            })
        )
    }
```

- [ ] **Step 6: Update `TouchTargetSmokeTests`.** Change all six `onRunScript: { _ in },` to `onRunScript: { _, _ in },`.

- [ ] **Step 7: Build, then run `AlasTests/TouchTargetSmokeTests`; confirm both pass.**

- [ ] **Step 8: Commit.**

```bash
git add Alas/Sources/Center/RunActivityPill.swift Alas/Sources/Center/TabBarView.swift \
  Alas/Sources/Center/CenterPaneView.swift AlasTests/TouchTargetSmokeTests.swift Alas.xcodeproj
git commit -m "feat(run): show run activity pill in the tab bar"
```

---

### Task 6: ⌥↵ in the ⌘R palette

**Files:**
- Modify: `Alas/Sources/RunScripts/RunScriptPaletteEnvironment.swift`
- Modify: `Alas/Sources/RunScripts/RunScriptPaletteModel.swift:113-129`
- Modify: `Alas/Sources/RunScripts/RunScriptDialog.swift:228-240` (footer), `:256-289` (`handleKey`, `activate`)
- Modify: `Alas/Sources/App/AppState+RunScripts.swift` (`runScriptPaletteEnvironment`)
- Modify: `AlasTests/RunScriptPaletteModelTests.swift`, `AlasTests/AppStateOverlayTests.swift:150`

**Interfaces:**
- Consumes: Task 3 `runOrFocusScript(_:in:console:)`, Task 1 `RunScriptConsole.flipped`.
- Produces: `RunScriptPaletteEnvironment.run: (RunScript, RunScriptConsole?) -> Void`, `RunScriptPaletteModel.activateSelection(environment:flipsConsole:)`.

This adds no new tests: flipping is one ternary that forwards to the run path, and Task 3 already tests console behavior. The existing tests are updated to the new signature, and `enterRunsSelectedScript` now also pins that a plain ↵ passes no override.

- [ ] **Step 1: Environment.** Replace `var run: (RunScript) -> Void` with:

```swift
    /// `nil` console runs with the script's `alas-console` default.
    var run: (RunScript, RunScriptConsole?) -> Void
```

- [ ] **Step 2: Model.** Replace `activateSelection`:

```swift
    /// Enter: run/focus or edit a script depending on mode, or create a new one from the trailing rows.
    /// `flipsConsole` (⌥↵) runs once against the script's console default.
    func activateSelection(environment env: RunScriptPaletteEnvironment, flipsConsole: Bool = false) {
        let rows = rows()
        guard rows.indices.contains(selectedIndex) else { return }
        switch rows[selectedIndex] {
        case .script(let script):
            switch mode {
            case .run:
                env.run(script, flipsConsole ? script.console.flipped : nil)
            case .edit:
                env.edit(script)
            }
        case .newRepoScript:      env.newScript(.repo)
        case .newGlobalScript:    env.newScript(.global)
        case .header:             break
        }
    }
```

- [ ] **Step 3: Dialog.** In `handleKey`, replace the `.return` case:

```swift
        case .return:
            if appState.runScriptPalette.mode == .edit {
                activate()
            } else if press.modifiers.contains(.command) {
                restart()
            } else {
                activate(flipsConsole: press.modifiers.contains(.option))
            }
            return .handled
```

Replace `activate()`:

```swift
    private func activate(flipsConsole: Bool = false) {
        guard let environment else { return }
        appState.runScriptPalette.activateSelection(environment: environment, flipsConsole: flipsConsole)
        close()
    }
```

In `footer`, after `label("⌘↵ restart")`:

```swift
                label(appState.runScriptPalette.selectedScript()?.console == .hidden ? "⌥↵ with console" : "⌥↵ in background")
```

- [ ] **Step 4: AppState environment.** In `runScriptPaletteEnvironment(worktree:)`:

```swift
            run: { [weak self] script, console in self?.runOrFocusScript(script, in: worktree, console: console) },
```

- [ ] **Step 5: Update tests.** In `RunScriptPaletteModelTests`:
  - change the helper parameter to `onRun: @escaping (RunScript, RunScriptConsole?) -> Void = { _, _ in }`;
  - in `enterRunsSelectedScript`, record both values and assert the override is `nil`:

```swift
    @Test func enterRunsSelectedScript() {
        var ran: RunScript?
        var console: RunScriptConsole??
        let model = RunScriptPaletteModel()
        let env = environment(scripts: [script("build")], onRun: { ran = $0; console = $1 })
        model.load(environment: env)
        model.activateSelection(environment: env)
        #expect(ran == script("build"))
        #expect(console == .some(nil))
    }
```

  - change every other `onRun: { ran = $0 }` in the file to `onRun: { script, _ in ran = script }`.

  In `AppStateOverlayTests`, change `run: { _ in },` to `run: { _, _ in },`.

- [ ] **Step 6: Run `AlasTests/RunScriptPaletteModelTests` and `AlasTests/AppStateOverlayTests`; confirm both pass.**

- [ ] **Step 7: Commit.**

```bash
git add Alas/Sources/RunScripts/RunScriptPaletteEnvironment.swift Alas/Sources/RunScripts/RunScriptPaletteModel.swift \
  Alas/Sources/RunScripts/RunScriptDialog.swift Alas/Sources/App/AppState+RunScripts.swift \
  AlasTests/RunScriptPaletteModelTests.swift AlasTests/AppStateOverlayTests.swift
git commit -m "feat(run): flip the console with option-return in the run palette"
```

---

### Task 7: Smoke run

The user runs Alas itself, and a dev build shares its bundle ID. Ask before launching a second instance.

- [ ] **Step 1: Build** with the build-only command and locate the app: `xcodebuild -project Alas.xcodeproj -scheme Alas -showBuildSettings | grep -m1 ' BUILT_PRODUCTS_DIR'`.
- [ ] **Step 2: Add two throwaway repo scripts** in a scratch worktree under `.alas/scripts/`:
  - `bg-ok.sh`: `# alas-console: hidden`, `sleep 3`
  - `bg-fail.sh`: `# alas-console: hidden`, `sleep 2; echo boom; exit 3`
- [ ] **Step 3: Exercise and observe, with screenshots:**
  1. ▶ → `bg-ok`: no tab appears; the pill shows a spinner, then `bg-ok 0:0x` with ■, then `✓ bg-ok 3s`, which disappears after about 4 s.
  2. ▶ → `bg-fail`: the pill turns red (`✕ bg-fail exit 3`), the failure banner appears, focus doesn't move.
  3. Pill → popover → Report opens the run report. Pill × dismisses both the pill and the banner.
  4. Hold ⌥ in the ▶ menu: items read "Run bg-ok with Console"; picking it opens and focuses the tab.
  5. Run both: the pill shows `2 running`; the popover lists both with Output/Restart/Stop. Output reveals the tab and leaves it in the strip.
  6. ⌘R, select `bg-ok`: the footer shows `⌥↵ with console`; ⌥↵ opens it visibly.
  7. ⌘1–9 and the tab context menu's "Close All Tabs" never touch a hidden run.
- [ ] **Step 4: Delete the throwaway scripts.** Report the observed results.
