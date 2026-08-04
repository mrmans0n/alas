# Reopen Closed Tabs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fixed `Command-Shift-T` action that reopens explicitly closed Alas tabs from a session-only app-wide history, including cross-worktree restoration and fresh reconstruction of closed terminal layouts.

**Architecture:** `AppState` owns a bounded `ClosedTabHistory` containing complete local/global tab snapshots plus collection-local placement anchors. Tab managers provide narrow snapshot-insertion APIs, while `AppState` alone decides which closures are user initiated, switches worktrees, recreates terminal resources transactionally, and consumes history entries only after success.

**Tech Stack:** Swift 5.9+, SwiftUI, Observation, AppKit command menus and notifications, Ghostty terminal integration, Swift Testing, XcodeGen, XcodeBuild.

## Global Constraints

- Keep code, comments, logs, and UI strings in English.
- Keep the history process-local and capped at exactly 50 entries.
- Use the fixed `Command-Shift-T` shortcut; do not add a configurable shortcut action.
- Explicit close actions are reopenable; automatic lifecycle cleanup is not.
- Reopened terminal panes use fresh identities and shells at their prior `lastCwd`; never revive a process or rerun a Run Script.
- Do not change tab persistence formats or add dependencies.
- Tests use Swift Testing (`import Testing`), not XCTest.
- Run Xcode and test commands serially.

---

## File Structure

- Create `Alas/Sources/Center/ClosedTabHistory.swift`: value types for local/global snapshots, placement anchors, the bounded LIFO history, and pure terminal-tree remapping.
- Create `AlasTests/ClosedTabHistoryTests.swift`: pure ordering, capacity, placement, purge, and tree-remapping tests.
- Modify `Alas/Sources/Center/TabsManager.swift`: insert or focus a saved worktree tab using a resolved placement.
- Modify `Alas/Sources/Center/GlobalTabsManager.swift`: insert or focus a saved global tab using a resolved placement.
- Modify `AlasTests/TabsManagerTests.swift`: local snapshot restoration tests.
- Modify `AlasTests/GlobalTabsManagerTests.swift`: global snapshot restoration tests.
- Modify `Alas/Sources/App/AppState.swift`: observable history state, explicit-close capture, reopen orchestration, terminal session creation/rollback, and cleanup purging.
- Create `AlasTests/ClosedTabAppStateTests.swift`: user-close boundaries, cross-worktree restoration, stable-ID focus, stale-entry skipping, and transactional terminal tests.
- Modify `Alas/Sources/Center/CenterPaneView.swift`: route global close buttons through the explicit user-close API.
- Modify `Alas/Sources/App/AlasApp.swift`: add the menu command and fixed key equivalent.
- Modify `Alas/Sources/App/RootView.swift`: receive the reopen notification and launch the async operation.
- Modify `Alas/Sources/Shortcuts/ShortcutAction.swift`: reserve the fixed key combination.
- Modify `AlasTests/ShortcutReservationsTests.swift`: prove reservation and conflict prevention.
- Modify `AlasTests/SurfaceViewShortcutTests.swift`: prove Ghostty yields the key equivalent to the app.
- Modify `AlasTests/ShortcutRecorderValidationTests.swift`: prove the fixed combination cannot be assigned elsewhere.
- Regenerate `Alas.xcodeproj/project.pbxproj` after adding source and test files.

---

### Task 1: Closed-tab history and placement model

**Files:**
- Create: `Alas/Sources/Center/ClosedTabHistory.swift`
- Create: `AlasTests/ClosedTabHistoryTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` via `rtk xcodegen`

**Interfaces:**
- Produces: `ClosedTabSnapshot`, `ClosedTabPlacement`, `ClosedTabEntry`, and `ClosedTabHistory`.
- Produces: `ClosedTabPlacement.insertionIndex(in:) -> Int` for both tab managers.
- Produces: `PaneNode.replacingLeaves(using:) -> PaneNode` for terminal reconstruction in Task 4.

- [ ] **Step 1: Add failing history tests**

Create `AlasTests/ClosedTabHistoryTests.swift` with fixtures based on terminal tabs because they require no filesystem state:

```swift
import Testing
@testable import Alas

struct ClosedTabHistoryTests {
    private func tab(_ id: String) -> Tab {
        .terminal(.init(id: id, title: id, sessionId: "session-\(id)"))
    }

    private func entry(_ id: String, worktreeID: String = "wt") -> ClosedTabEntry {
        ClosedTabEntry(
            snapshot: .worktree(worktreeID: worktreeID, tab: tab(id)),
            placement: .init(previousID: nil, nextID: nil, ordinal: 0)
        )
    }

    @Test func popsNewestEntryFirst() {
        var history = ClosedTabHistory()
        history.record(entry("a"))
        history.record(entry("b"))

        #expect(history.last?.snapshot.tabID == "b")
        history.remove(id: history.last!.id)
        #expect(history.last?.snapshot.tabID == "a")
    }

    @Test func retainsOnlyFiftyNewestEntries() {
        var history = ClosedTabHistory()
        for index in 0..<51 { history.record(entry("tab-\(index)")) }

        #expect(history.count == 50)
        #expect(history.entries.first?.snapshot.tabID == "tab-1")
        #expect(history.last?.snapshot.tabID == "tab-50")
    }

    @Test func placementPrefersNextThenPreviousThenOrdinal() {
        let beforeC = ClosedTabPlacement(previousID: "a", nextID: "c", ordinal: 1)
        #expect(beforeC.insertionIndex(in: ["a", "c"]) == 1)
        #expect(beforeC.insertionIndex(in: ["a", "d"]) == 1)
        #expect(beforeC.insertionIndex(in: ["d"]) == 1)
        #expect(beforeC.insertionIndex(in: []) == 0)
    }

    @Test func purgeRemovesOnlyMatchingWorktreeEntries() {
        var history = ClosedTabHistory()
        history.record(entry("a", worktreeID: "first"))
        history.record(entry("b", worktreeID: "second"))
        history.purge(worktreeID: "first")

        #expect(history.entries.map(\.snapshot.tabID) == ["b"])
    }
}
```

Also add a bulk-order regression that records `a`, `c`, `d` in visible order and proves removal yields `d`, `c`, `a`. Add placement regressions reconstructing `[a, b, c, d]` from `[b]` with saved anchors for `a`, `c`, and `d`.

- [ ] **Step 2: Regenerate the project and verify the new suite fails**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -derivedDataPath /tmp/alas-reopen-tabs-dd test -only-testing:AlasTests/ClosedTabHistoryTests
```

Expected: build failure because `ClosedTabHistory`, `ClosedTabEntry`, and related types do not exist.

- [ ] **Step 3: Implement the bounded history and placement algorithm**

Create `Alas/Sources/Center/ClosedTabHistory.swift` with these concrete shapes:

```swift
import Foundation

enum ClosedTabSnapshot: Equatable {
    case worktree(worktreeID: String, tab: Tab)
    case global(GlobalTab)

    var tabID: TabID {
        switch self {
        case .worktree(_, let tab): tab.id
        case .global(let tab): tab.id
        }
    }

    var worktreeID: String? {
        guard case .worktree(let worktreeID, _) = self else { return nil }
        return worktreeID
    }
}

struct ClosedTabPlacement: Equatable {
    let previousID: TabID?
    let nextID: TabID?
    let ordinal: Int

    init(tabID: TabID, orderedIDs: [TabID]) {
        guard let index = orderedIDs.firstIndex(of: tabID) else {
            previousID = nil
            nextID = nil
            ordinal = orderedIDs.count
            return
        }
        previousID = index > orderedIDs.startIndex ? orderedIDs[index - 1] : nil
        nextID = orderedIDs.indices.contains(index + 1) ? orderedIDs[index + 1] : nil
        ordinal = index
    }

    init(previousID: TabID?, nextID: TabID?, ordinal: Int) {
        self.previousID = previousID
        self.nextID = nextID
        self.ordinal = ordinal
    }

    func insertionIndex(in currentIDs: [TabID]) -> Int {
        if let nextID, let index = currentIDs.firstIndex(of: nextID) { return index }
        if let previousID, let index = currentIDs.firstIndex(of: previousID) { return index + 1 }
        return min(max(ordinal, 0), currentIDs.count)
    }
}

struct ClosedTabEntry: Identifiable, Equatable {
    let id: UUID
    let snapshot: ClosedTabSnapshot
    let placement: ClosedTabPlacement

    init(id: UUID = UUID(), snapshot: ClosedTabSnapshot, placement: ClosedTabPlacement) {
        self.id = id
        self.snapshot = snapshot
        self.placement = placement
    }
}

struct ClosedTabHistory: Equatable {
    static let capacity = 50
    private(set) var entries: [ClosedTabEntry] = []
    var last: ClosedTabEntry? { entries.last }
    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    mutating func record(_ entry: ClosedTabEntry) {
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    mutating func record(contentsOf newEntries: [ClosedTabEntry]) {
        for entry in newEntries { record(entry) }
    }

    mutating func remove(id: ClosedTabEntry.ID) {
        entries.removeAll { $0.id == id }
    }

    mutating func purge(worktreeID: String) {
        entries.removeAll { $0.snapshot.worktreeID == worktreeID }
    }
}
```

Add a pure recursive helper which preserves split IDs/axis/fraction while replacing leaves from an old-ID keyed dictionary:

```swift
extension PaneNode {
    func replacingLeaves(using replacements: [String: PaneLeaf]) -> PaneNode {
        switch self {
        case .leaf(let leaf): return replacements[leaf.id].map(PaneNode.leaf) ?? self
        case .split(var split):
            split.children = split.children.map { $0.replacingLeaves(using: replacements) }
            return .split(split)
        }
    }
}
```

Add tests proving split axis, fraction, child order, and `lastCwd` survive while replacement leaf IDs are used.

- [ ] **Step 4: Run the focused tests**

Run the same `xcodebuild ... -only-testing:AlasTests/ClosedTabHistoryTests` command.

Expected: PASS for every history, placement, capacity, purge, and pane-remapping test.

- [ ] **Step 5: Commit the model**

```bash
git add Alas/Sources/Center/ClosedTabHistory.swift AlasTests/ClosedTabHistoryTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(tabs): model closed tab history"
```

---

### Task 2: Snapshot insertion in tab managers

**Files:**
- Modify: `Alas/Sources/Center/TabsManager.swift`
- Modify: `Alas/Sources/Center/GlobalTabsManager.swift`
- Modify: `AlasTests/TabsManagerTests.swift`
- Modify: `AlasTests/GlobalTabsManagerTests.swift`

**Interfaces:**
- Consumes: `ClosedTabPlacement.insertionIndex(in:)` from Task 1.
- Produces: `TabsManager.restore(tab:worktreeID:placement:) -> TabID`.
- Produces: `GlobalTabsManager.restore(tab:placement:) -> TabID`.

- [ ] **Step 1: Add failing local and global restoration tests**

Add to `TabsManagerTests`:

```swift
@Test func restoreInsertsAtAnchoredPositionAndActivates() {
    let worktreeID = "tabs-manager-restore-position"
    let manager = TabsManager(store: RestoreMemoryStore())
    let first = manager.appendTerminal(worktreeId: worktreeID, title: "a", sessionId: "a")
    let restored = Tab.terminal(.init(id: "b", title: "b", sessionId: "b"))
    let third = manager.appendTerminal(worktreeId: worktreeID, title: "c", sessionId: "c")

    let id = manager.restore(
        tab: restored,
        worktreeID: worktreeID,
        placement: .init(previousID: first.id, nextID: third.id, ordinal: 1)
    )

    #expect(id == restored.id)
    #expect(manager.tabs(forWorktree: worktreeID).map(\.id) == [first.id, restored.id, third.id])
    #expect(manager.activeTabId(forWorktree: worktreeID) == restored.id)
}
```

Add this store inside `TabsManagerTests` so the new tests never touch shared tab files:

```swift
private struct RestoreMemoryStore: PersistenceStoreProtocol {
    func write<T: Encodable>(_: T, to _: URL) throws {}
    func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
}
```

Add a second test where `restored.id` is already present; assert the existing tab is activated, the count is unchanged, and persisted ordering is unchanged.

Add equivalent Mission tests to `GlobalTabsManagerTests`, using the existing `GlobalTabsHarness`, and assert both anchored insertion and stable-ID focus-without-duplication.

- [ ] **Step 2: Run manager suites and verify failure**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -derivedDataPath /tmp/alas-reopen-tabs-dd test -only-testing:AlasTests/TabsManagerTests -only-testing:AlasTests/GlobalTabsManagerTests
```

Expected: build failure because both `restore` methods are missing.

- [ ] **Step 3: Implement narrow restore methods**

Add to `TabsManager` near `activate`:

```swift
@discardableResult
func restore(tab: Tab, worktreeID: String, placement: ClosedTabPlacement) -> TabID {
    var file = byWorktree[worktreeID] ?? TabsFile(tabs: [], activeTabId: nil)
    if file.tabs.contains(where: { $0.id == tab.id }) {
        file.activeTabId = tab.id
    } else {
        let index = placement.insertionIndex(in: file.tabs.map(\.id))
        file.tabs.insert(tab, at: index)
        file.activeTabId = tab.id
    }
    byWorktree[worktreeID] = file
    persist(worktreeID)
    return tab.id
}
```

Add the analogous method to `GlobalTabsManager`, using `tabs`, `activeTabId`, and `try? persist()`.

- [ ] **Step 4: Run both manager suites**

Run the Task 2 focused command again.

Expected: PASS, including existing persistence and migration tests.

- [ ] **Step 5: Commit manager restoration**

```bash
git add Alas/Sources/Center/TabsManager.swift Alas/Sources/Center/GlobalTabsManager.swift AlasTests/TabsManagerTests.swift AlasTests/GlobalTabsManagerTests.swift
git commit -m "feat(tabs): restore closed tab snapshots"
```

---

### Task 3: Explicit-close capture and non-terminal reopening

**Files:**
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `Alas/Sources/Center/CenterPaneView.swift`
- Modify: `Alas/Sources/App/RootView.swift`
- Create: `AlasTests/ClosedTabAppStateTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` via `rtk xcodegen`

**Interfaces:**
- Consumes: history and manager restore APIs from Tasks 1-2.
- Produces: `AppState.canReopenClosedTab: Bool`.
- Produces: `AppState.requestCloseGlobalTab(tabID:)` for user-facing global closure.
- Produces: `AppState.reopenLastClosedTab() async` for Task 5 command wiring.
- Keeps `closeGlobalTab`, `closeTab`, and `cleanupWorktreeState` as raw lifecycle operations that never record history themselves.

- [ ] **Step 1: Add failing AppState boundary tests**

Create `AlasTests/ClosedTabAppStateTests.swift` as a serialized main-actor suite. Define a local no-op `PersistenceStoreProtocol`, plus a helper that creates a `ProjectConfig`, two `Worktree` values, and an `AppState` whose `projectsManager` contains them. Follow the concrete fixture construction used in `AgentTerminalLaunchTests` and `AppStatePersistenceTests`.

Add these tests with explicit assertions:

```swift
@Test func explicitCloseRecordsAndReopenSwitchesWorktree() async throws {
    let fixture = makeFixture()
    let tab = fixture.state.tabs.appendEditor(
        worktreeId: fixture.second.id,
        title: "README.md",
        relativePath: "README.md"
    )
    fixture.state.selectWorktree(id: fixture.first.id)

    fixture.state.requestCloseTab(worktreeId: fixture.second.id, tabId: tab.id)
    #expect(fixture.state.canReopenClosedTab)

    await fixture.state.reopenLastClosedTab()

    #expect(fixture.state.selectedWorktreeId == fixture.second.id)
    #expect(fixture.state.tabs.activeTabId(forWorktree: fixture.second.id) == tab.id)
    #expect(!fixture.state.canReopenClosedTab)
}

@Test func automaticCloseDoesNotRecordHistory() {
    let fixture = makeFixture()
    let tab = fixture.state.tabs.appendEditor(
        worktreeId: fixture.first.id,
        title: "README.md",
        relativePath: "README.md"
    )

    fixture.state.closeTab(worktreeId: fixture.first.id, tabId: tab.id)

    #expect(!fixture.state.canReopenClosedTab)
}
```

Add coverage for:

- `requestCloseGlobalTab` recording and reopening a Mission;
- stable-ID Mission already reopened manually, which is focused without duplication;
- `closeCenterTabs` recording mixed global/local IDs in the supplied visible order;
- a canceled confirmation not recording history, using an injectable confirmation seam described in Step 3;
- cleanup purging entries owned by a removed worktree;
- a stale top entry being discarded and the next valid entry reopening during the same call;
- `isReopeningClosedTab` preventing two overlapping reopen attempts.

- [ ] **Step 2: Regenerate and verify the AppState suite fails**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -derivedDataPath /tmp/alas-reopen-tabs-dd test -only-testing:AlasTests/ClosedTabAppStateTests
```

Expected: build failure because AppState has no history or reopen API.

- [ ] **Step 3: Add observable history state and capture helpers**

In `AppState`, add:

```swift
private(set) var closedTabHistory = ClosedTabHistory()
private(set) var isReopeningClosedTab = false
var canReopenClosedTab: Bool { !isReopeningClosedTab && !closedTabHistory.isEmpty }
```

Inject close confirmation without changing production behavior:

```swift
typealias CloseTabConfirmer = @MainActor (CloseTabConfirmationPolicy.Prompt) -> Bool
@ObservationIgnored private let closeTabConfirmer: CloseTabConfirmer?
```

Add `closeTabConfirmer: CloseTabConfirmer? = nil` to `AppState.init`; `confirmCloseTab` calls it when present and otherwise shows the existing `NSAlert`.

Add a pure capture helper that walks the requested visible `tabIDs` in order, reads each snapshot before removal, and computes placement against the complete owning collection:

```swift
private func closedTabEntries(worktreeID: String, tabIDs: [TabID]) -> [ClosedTabEntry] {
    let global = globalTabs.tabs
    let local = tabs.tabs(forWorktree: worktreeID)
    return tabIDs.compactMap { tabID in
        if let tab = global.first(where: { $0.id == tabID }) {
            return ClosedTabEntry(
                snapshot: .global(tab),
                placement: .init(tabID: tabID, orderedIDs: global.map(\.id))
            )
        }
        guard let tab = local.first(where: { $0.id == tabID }) else { return nil }
        return ClosedTabEntry(
            snapshot: .worktree(worktreeID: worktreeID, tab: tab),
            placement: .init(tabID: tabID, orderedIDs: local.map(\.id))
        )
    }
}
```

After confirmation succeeds, `requestCloseTab` records its one captured entry immediately before calling raw `closeTab`. Add `requestCloseGlobalTab(tabID:)` with the same record-then-raw-close ordering. Update the global close closure in `CenterPaneView`, the no-worktree `GlobalMissionTabBarView` close closure in `RootView`, and the global branch of `handleCloseCenterShortcut` to use the request method.

In `closeCenterTabs`, capture all entries before any removal, record them in supplied visible order, then run the existing global/local cleanup. Do not add recording to `closeTab`, `closeGlobalTab`, `closeAllTabs`, process-exit handling, or manager removal methods.

At the beginning of `cleanupWorktreeState(worktreeId:)`, call `closedTabHistory.purge(worktreeID:)`. This covers deletion, archival, failed optimistic cleanup, and missing-worktree reconciliation without making them record closures.

- [ ] **Step 4: Implement non-terminal reopen orchestration**

Add `reopenLastClosedTab() async` with an in-flight guard and identity-based consumption:

```swift
func reopenLastClosedTab() async {
    guard !isReopeningClosedTab else { return }
    isReopeningClosedTab = true
    defer { isReopeningClosedTab = false }

    while let entry = closedTabHistory.last {
        switch entry.snapshot {
        case .global(let tab):
            _ = globalTabs.restore(tab: tab, placement: entry.placement)
            closedTabHistory.remove(id: entry.id)
            return

        case .worktree(let worktreeID, let tab):
            guard worktree(withId: worktreeID) != nil else {
                closedTabHistory.remove(id: entry.id)
                continue
            }
            if case .terminal = tab {
                await reopenTerminalTab(entry: entry, worktreeID: worktreeID, tab: tab)
                return
            }
            selectWorktree(id: worktreeID)
            _ = tabs.restore(tab: tab, worktreeID: worktreeID, placement: entry.placement)
            activateWorktreeCenterTab(worktreeId: worktreeID, tabId: tab.id)
            closedTabHistory.remove(id: entry.id)
            return
        }
    }
}
```

Declare the terminal branch as a private async method that Task 4 will fill. For Task 3, make it report `Reopen Tab Failed` and retain the entry; the tests in this task use only non-terminal snapshots.

- [ ] **Step 5: Run focused AppState and manager tests**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -derivedDataPath /tmp/alas-reopen-tabs-dd test -only-testing:AlasTests/ClosedTabAppStateTests -only-testing:AlasTests/TabsManagerTests -only-testing:AlasTests/GlobalTabsManagerTests -only-testing:AlasTests/AppStatePersistenceTests
```

Expected: PASS. In particular, the existing missing-Mission cleanup tests must continue to use raw closure without unexpected history side effects.

- [ ] **Step 6: Commit explicit closure and non-terminal reopen**

```bash
git add Alas/Sources/App/AppState.swift Alas/Sources/Center/CenterPaneView.swift Alas/Sources/App/RootView.swift AlasTests/ClosedTabAppStateTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(tabs): reopen explicitly closed tabs"
```

---

### Task 4: Transactional terminal-tab reconstruction

**Files:**
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `AlasTests/ClosedTabAppStateTests.swift`

**Interfaces:**
- Consumes: `PaneNode.replacingLeaves(using:)`, `ClosedTabEntry`, and `TabsManager.restore`.
- Completes: the private `AppState.reopenTerminalTab(entry:worktreeID:tab:) async` branch introduced in Task 3.
- Reuses: `terminalSessionOpener`, `prepareRemoteAccelerationIfNeeded(for:)`, `closeTerminalSession`, and `fileActionErrorHandler`.

- [ ] **Step 1: Add failing terminal reconstruction tests**

Extend `ClosedTabAppStateTests` with a fixture whose injected `terminalSessionOpener` records each `forcedCwd` and returns deterministic fresh IDs.

Create a closed terminal snapshot with a vertical split, non-default fraction, two old leaf IDs and distinct `lastCwd` values, the second leaf focused, and non-nil Run Script fields. Record it through an explicit close, invoke reopen, then assert:

```swift
#expect(openedCwds == ["/tmp/first", "/tmp/second"])
guard case .terminal(let reopened) = fixture.state.tabs.activeTab(forWorktree: fixture.worktree.id) else {
    Issue.record("Expected reopened terminal")
    return
}
#expect(reopened.id == original.id)
#expect(reopened.root.leaves().map(\.id) == ["fresh-1", "fresh-2"])
#expect(reopened.root.leaves().map(\.lastCwd) == ["/tmp/first", "/tmp/second"])
#expect(reopened.focusedLeafId == "fresh-2")
#expect(reopened.runScriptKey == nil)
#expect(reopened.runScriptLeafId == nil)
```

Pattern-match the reopened root and assert the original split axis, fraction, split ID, and child order.

Add a failure test where the opener succeeds once and throws on the second call. Capture the error title, then assert no terminal tab was inserted, `canReopenClosedTab` becomes true again after the operation, the same entry remains last, and the first fresh session is absent from harness ownership after rollback.

- [ ] **Step 2: Run the terminal-focused tests and verify failure**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -derivedDataPath /tmp/alas-reopen-tabs-dd test -only-testing:AlasTests/ClosedTabAppStateTests
```

Expected: terminal tests FAIL because the Task 3 temporary failure branch does not reconstruct sessions.

- [ ] **Step 3: Implement fresh-session opening without appending a tab**

Add a private helper next to `openTerminalTab` so it can access the existing private injected opener:

```swift
private func openTerminalSessionForReopen(
    worktree: Worktree,
    project: ProjectConfig,
    forcedCwd: URL?
) throws -> OpenedTerminalSession {
    let opened: OpenedTerminalSession
    if let terminalSessionOpener {
        opened = try terminalSessionOpener(
            worktree, project, config.terminal, themeStore.current,
            forcedCwd, nil, true, [:], []
        )
    } else {
        let leafID = UUID().uuidString
        let session = try terminal.openSession(
            worktree: worktree,
            project: project,
            cfg: config.terminal,
            theme: themeStore.current,
            forcedCwd: forcedCwd,
            leafId: leafID
        )
        opened = .init(id: session.id, foregroundPid: { [weak session] in
            session?.surface.foregroundPid
        })
    }
    harness.detector.register(sessionId: opened.id, pidProvider: opened.foregroundPid)
    return opened
}
```

Do not pass a startup script suffix or Run Script environment. This intentionally creates ordinary fresh shells.

- [ ] **Step 4: Implement transactional tree reconstruction and rollback**

Replace the Task 3 temporary terminal failure branch with logic that:

1. Resolves the `Worktree` and `ProjectConfig`.
2. Awaits `prepareRemoteAccelerationIfNeeded(for:)`.
3. Traverses `oldState.root.leaves()` in render order.
4. Opens one session per old leaf using `oldLeaf.lastCwd.map(URL.init(fileURLWithPath:))`.
5. Builds `replacements[oldLeaf.id] = PaneLeaf(id: opened.id, sessionId: opened.id, lastCwd: oldLeaf.lastCwd)` and maps the old focused ID to the fresh ID.
6. Replaces leaves in the old tree, clears both Run Script fields, inserts the reconstructed `.terminal` tab, switches worktree, activates it, and removes `entry.id` from history.

Use this exact rollback shape:

```swift
var openedIDs: [String] = []
do {
    // Open and collect every replacement, then insert only after all succeed.
} catch {
    let projectPath = project.path
    for id in openedIDs {
        closeTerminalSession(id: id, worktreeId: worktreeID, projectPath: projectPath)
    }
    showFileActionError(title: "Reopen Tab Failed", message: error.localizedDescription)
}
```

The catch path must not remove `entry.id`. Because `isReopeningClosedTab` is reset by the outer `defer`, the menu becomes enabled again for retry. If a new tab is closed while the async reconstruction is suspended, identity-based removal consumes only the attempted entry and leaves the newer entry on top.

- [ ] **Step 5: Run terminal and existing terminal lifecycle suites**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -derivedDataPath /tmp/alas-reopen-tabs-dd test -only-testing:AlasTests/ClosedTabAppStateTests -only-testing:AlasTests/TabsManagerPaneTests -only-testing:AlasTests/AppStateKeepSessionsAliveTests -only-testing:AlasTests/AgentTerminalLaunchTests
```

Expected: PASS, including partial-failure rollback and existing persistent-terminal behavior.

- [ ] **Step 6: Commit terminal reconstruction**

```bash
git add Alas/Sources/App/AppState.swift AlasTests/ClosedTabAppStateTests.swift
git commit -m "feat(terminal): rebuild reopened tab layouts"
```

---

### Task 5: Menu command, notification, and Ghostty reservation

**Files:**
- Modify: `Alas/Sources/App/AlasApp.swift`
- Modify: `Alas/Sources/App/RootView.swift`
- Modify: `Alas/Sources/Shortcuts/ShortcutAction.swift`
- Modify: `AlasTests/ShortcutReservationsTests.swift`
- Modify: `AlasTests/SurfaceViewShortcutTests.swift`
- Modify: `AlasTests/ShortcutRecorderValidationTests.swift`

**Interfaces:**
- Consumes: `AppState.canReopenClosedTab` and `AppState.reopenLastClosedTab()` from Task 3.
- Produces: `Notification.Name.alasReopenClosedTab`.
- Reserves: `ShortcutBinding(key: "t", modifiers: [.command, .shift])`.

- [ ] **Step 1: Add failing shortcut tests**

Extend `ShortcutReservationsTests.defaultsIncludeStandardsAndTabSwitchers`:

```swift
let reopen = ShortcutBinding(key: "t", modifiers: [.command, .shift])
#expect(ShortcutAction.reservedBindings.contains(reopen))
#expect(ShortcutReservations.defaultReserved.contains(reopen))
#expect(ShortcutReservations.snapshot(from: .defaults).contains(reopen))
```

Add to `ShortcutRecorderValidationTests`:

```swift
@Test func rejectsReservedReopenClosedTabShortcut() {
    let binding = ShortcutBinding(key: "t", modifiers: [.command, .shift])
    #expect(ShortcutRecorder.validate(binding) == .reserved)
}
```

Extend `SurfaceViewShortcutTests` with an `NSEvent` for `t` plus Command and Shift and assert `isReservedAppKeyEquivalent` returns true.

- [ ] **Step 2: Run shortcut suites and verify failure**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -derivedDataPath /tmp/alas-reopen-tabs-dd test -only-testing:AlasTests/ShortcutReservationsTests -only-testing:AlasTests/SurfaceViewShortcutTests -only-testing:AlasTests/ShortcutRecorderValidationTests
```

Expected: FAIL because the fixed shortcut has not been reserved.

- [ ] **Step 3: Reserve the fixed shortcut**

Add this entry to `ShortcutAction.reservedBindings` next to Command-W:

```swift
.init(key: "t", modifiers: [.command, .shift]),
```

Do not add a `ShortcutAction` case; the command is intentionally fixed like Close Tab.

- [ ] **Step 4: Wire the app command and notification**

In `AlasApp`, add the button immediately after Close Tab:

```swift
Button("Reopen Closed Tab") {
    NotificationCenter.default.post(name: .alasReopenClosedTab, object: nil)
}
.keyboardShortcut("t", modifiers: [.command, .shift])
.disabled(!state.canReopenClosedTab)
```

In `Notification.Name`, add:

```swift
static let alasReopenClosedTab = Notification.Name("AlasReopenClosedTab")
```

In `RootBaseHandlers`, add a receiver directly after `.alasCloseTab`:

```swift
.onReceive(NotificationCenter.default.publisher(for: .alasReopenClosedTab)) { _ in
    Task { @MainActor in
        await state.reopenLastClosedTab()
    }
}
```

Keep the receiver independent of `selectedWorktree()` because history resolves and switches its own worktree.

- [ ] **Step 5: Run shortcut and closed-tab suites**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -derivedDataPath /tmp/alas-reopen-tabs-dd test -only-testing:AlasTests/ShortcutReservationsTests -only-testing:AlasTests/SurfaceViewShortcutTests -only-testing:AlasTests/ShortcutRecorderValidationTests -only-testing:AlasTests/ClosedTabHistoryTests -only-testing:AlasTests/ClosedTabAppStateTests
```

Expected: PASS. Manually inspect the built app's tab command menu to confirm **Reopen Closed Tab** displays `Shift-Command-T`, is disabled initially, enables after an explicit close, and works while a terminal has focus.

- [ ] **Step 6: Commit command integration**

```bash
git add Alas/Sources/App/AlasApp.swift Alas/Sources/App/RootView.swift Alas/Sources/Shortcuts/ShortcutAction.swift AlasTests/ShortcutReservationsTests.swift AlasTests/SurfaceViewShortcutTests.swift AlasTests/ShortcutRecorderValidationTests.swift
git commit -m "feat(tabs): add reopen closed tab shortcut"
```

---

### Task 6: Final regression and repository verification

**Files:**
- Modify only files needed to fix regressions discovered by verification.

**Interfaces:**
- Consumes the complete feature from Tasks 1-5.
- Produces a clean, formatted, fully verified branch.

- [ ] **Step 1: Regenerate and inspect generated membership**

```bash
rtk xcodegen
git status --short
git diff --check
```

Expected: the two new Swift files appear in the generated project, and `git diff --check` reports no whitespace errors. Commit `Alas.xcodeproj/project.pbxproj` if Task 1 or Task 3 regeneration did not already capture its final form.

- [ ] **Step 2: Run formatting lint**

```bash
rtk swiftformat --lint Alas/Sources AlasTests
```

Expected: exit 0. Apply only mechanical formatting fixes reported for touched files, rerun lint, and commit those fixes with the closest owning task if not yet published.

- [ ] **Step 3: Run the required build serially**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit 0.

- [ ] **Step 4: Run the required full test suite serially**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: exit 0 with all existing and new tests passing. A run that stalls before `xctest` or fails because another process locked `build.db` is incomplete; rerun serially with a fresh explicit DerivedData path before classifying it as a source failure.

- [ ] **Step 5: Review the final diff against the approved spec**

```bash
git diff origin/main...HEAD --stat
git diff origin/main...HEAD -- Alas/Sources/Center/ClosedTabHistory.swift Alas/Sources/Center/TabsManager.swift Alas/Sources/Center/GlobalTabsManager.swift Alas/Sources/App/AppState.swift Alas/Sources/Center/CenterPaneView.swift Alas/Sources/App/AlasApp.swift Alas/Sources/App/RootView.swift Alas/Sources/Shortcuts/ShortcutAction.swift AlasTests
git status --short
```

Confirm all of the following before completion:

- only explicit closure paths record history;
- deletion/archive/missing-worktree cleanup purges without recording;
- repeated reopen is LIFO and cross-worktree;
- stable IDs focus instead of duplicating;
- terminal layouts use fresh sessions and preserve directories without rerunning scripts;
- terminal failure rolls back and stays retryable;
- `Command-Shift-T` works through Ghostty and remains non-configurable;
- the worktree is clean.

- [ ] **Step 6: Commit any final verification-only correction**

If verification required a source correction, rerun the directly affected focused suite and Steps 2-4, then commit only that correction:

```bash
git add Alas/Sources/Center/ClosedTabHistory.swift Alas/Sources/Center/TabsManager.swift Alas/Sources/Center/GlobalTabsManager.swift Alas/Sources/App/AppState.swift Alas/Sources/Center/CenterPaneView.swift Alas/Sources/App/AlasApp.swift Alas/Sources/App/RootView.swift Alas/Sources/Shortcuts/ShortcutAction.swift AlasTests/ClosedTabHistoryTests.swift AlasTests/ClosedTabAppStateTests.swift AlasTests/TabsManagerTests.swift AlasTests/GlobalTabsManagerTests.swift AlasTests/ShortcutReservationsTests.swift AlasTests/SurfaceViewShortcutTests.swift AlasTests/ShortcutRecorderValidationTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "fix(tabs): harden closed tab restoration"
```

If no correction was needed, do not create an empty commit.
