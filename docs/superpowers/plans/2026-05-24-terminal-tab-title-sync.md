# Terminal Tab Title Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire Ghostty terminal title changes into the visible tab bar label for terminal tabs, gated by an optional setting.

**Architecture:** A runtime-only dictionary in `TabsManager` stores leafId→displayTitle overrides. `TabBarView` resolves display titles at render time using a lookup closure. `TerminalTabView` wires `SurfaceView.titleHandler` to populate the dictionary when the setting is enabled. Manual tab renames clear the runtime override.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Testing, Observation framework

---

## File Map

| File | Responsibility |
|---|---|
| `Alas/Sources/Persistence/AppConfig.swift` | Add `syncTabTitleWithTerminalTitle` field to `Terminal` config |
| `Alas/Sources/Center/TabsManager.swift` | Add `terminalRuntimeTitles` dict + `setTerminalRuntimeTitle`, `clearTerminalRuntimeTitles`, `displayTerminalTitle`, cleanup in `close` |
| `Alas/Sources/Center/TabBarView.swift` | Add `titleLookup` prop; use resolved display title in `TabButton` |
| `Alas/Sources/Center/CenterPaneView.swift` | Pass `titleLookup` closure to `TabBarView` |
| `Alas/Sources/Center/TerminalTabView.swift` | Wire `titleHandler` in `PaneLeafView.onAppear` |
| `Alas/Sources/App/AppState.swift` | Update `renameTerminalTab` to clear runtime titles for renamed tab |
| `Alas/Sources/Settings/TerminalPane.swift` | Add "Sync tab title with terminal title" toggle in Appearance group |
| `AlasTests/TabsManagerTests.swift` | Tests for runtime title storage + clear + close cleanup |
| `AlasTests/TerminalTabStateCodableTests.swift` | Test that runtime dict is excluded from persistence |
| `AlasTests/SettingsSectionTests.swift` | Test new config field decode/encode |
| `AlasTests/TabActivityIconTintTests.swift` | May need update if `TabBarView` init signature changes |
| `AlasTests/TouchTargetSmokeTests.swift` | May need update if `TabBarView` init signature changes |

---

### Task 1: Config Model – Add `syncTabTitleWithTerminalTitle`

**Files:**
- Modify: `Alas/Sources/Persistence/AppConfig.swift:63-75`
- Test: `AlasTests/SettingsSectionTests.swift`

The `Terminal` struct gets a new field. Add it after `bell`.

- [ ] **Step 1: Add field to struct and defaults**

In `Alas/Sources/Persistence/AppConfig.swift`, inside `struct Terminal`, add:

```swift
var syncTabTitleWithTerminalTitle: Bool
```

In the `defaults` static, inside `terminal: Terminal(...)` add after `bell: "visual":

```swift
syncTabTitleWithTerminalTitle: false
```

- [ ] **Step 2: Update CodingKeys and decode**

Update `AppConfig.CodingKeys` if `Terminal` uses a custom `CodingKeys`; otherwise Swift generates. Check: `Terminal` currently has no custom CodingKeys, so Swift synthesizes them. The new field is auto-included.

Add graceful decode in `init(from decoder:)` under the `terminal` decode block. Since `Terminal` has no custom decode yet, add one after the existing:

```swift
if let termContainer = try? c.nestedContainer(keyedBy: AppConfig.Terminal.CodingKeys.self, forKey: .terminal) {
    let shell = (try? termContainer.decode(String.self, forKey: .shell)) ?? "/bin/zsh"
    let workingDirectory = (try? termContainer.decode(String.self, forKey: .workingDirectory)) ?? "worktreeRoot"
    let startupScript = (try? termContainer.decode(String.self, forKey: .startupScript)) ?? ""
    let worktreeCreateScript = (try? termContainer.decode(String.self, forKey: .worktreeCreateScript)) ?? ""
    let inheritParentEnv = (try? termContainer.decode(Bool.self, forKey: .inheritParentEnv)) ?? true
    let fontFamily = (try? termContainer.decode(String.self, forKey: .fontFamily)) ?? "JetBrains Mono"
    let fontSize = (try? termContainer.decode(Int.self, forKey: .fontSize)) ?? 13
    let cursorStyle = (try? termContainer.decode(String.self, forKey: .cursorStyle)) ?? "beam"
    let cursorBlink = (try? termContainer.decode(Bool.self, forKey: .cursorBlink)) ?? true
    let scrollbackLines = (try? termContainer.decode(Int.self, forKey: .scrollbackLines)) ?? 10000
    let bell = (try? termContainer.decode(String.self, forKey: .bell)) ?? "visual"
    let syncTabTitleWithTerminalTitle = (try? termContainer.decode(Bool.self, forKey: .syncTabTitleWithTerminalTitle)) ?? false
    terminal = Terminal(
        shell: shell,
        workingDirectory: workingDirectory,
        startupScript: startupScript,
        worktreeCreateScript: worktreeCreateScript,
        inheritParentEnv: inheritParentEnv,
        fontFamily: fontFamily,
        fontSize: fontSize,
        cursorStyle: cursorStyle,
        cursorBlink: cursorBlink,
        scrollbackLines: scrollbackLines,
        bell: bell,
        syncTabTitleWithTerminalTitle: syncTabTitleWithTerminalTitle
    )
} else {
    terminal = Terminal(
        shell: "/bin/zsh",
        workingDirectory: "worktreeRoot",
        startupScript: "",
        worktreeCreateScript: "",
        inheritParentEnv: true,
        fontFamily: "JetBrains Mono",
        fontSize: 13,
        cursorStyle: "beam",
        cursorBlink: true,
        scrollbackLines: 10000,
        bell: "visual",
        syncTabTitleWithTerminalTitle: false
    )
}
```

Remove the existing `terminal = try c.decode(Terminal.self, forKey: .terminal)` line and replace with the above block.

- [ ] **Step 3: Write test for decode backward compatibility**

In `AlasTests/SettingsSectionTests.swift` (or a new test file `AlasTests/SettingsSaveNormalizationTests.swift`), add:

```swift
@Test func decodeMissingSyncTabTitleField() throws {
    let json = #"{"themeId":"cool-slate","accent":"teal","density":"comfortable","matchSystemTheme":false,"sidebarMaterial":"appKitSidebar","sidebarWidth":244,"rightPaneWidth":320,"rightPaneVisible":true,"sidebarVisible":true,"commitDetailSplitRatio":0.32,"general":{"launchAtLogin":false,"closeToTray":true,"confirmQuit":true,"autoUpdate":true,"updateChannel":"Stable","crashReports":false,"usageAnalytics":false},"worktrees":{"rootPath":"~/.alas/worktrees","pathTemplate":"{worktreeRoot}/{repo}/{branch}","branchPrefix":"feature/","baseBranch":"main","trackUpstream":true,"deleteBranchOnRemove":true,"autoFetch":true,"fetchIntervalMinutes":5,"pruneStale":false},"terminal":{"shell":"/bin/zsh","workingDirectory":"worktreeRoot","startupScript":"","worktreeCreateScript":"","inheritParentEnv":true,"fontFamily":"JetBrains Mono","fontSize":13,"cursorStyle":"beam","cursorBlink":true,"scrollbackLines":10000,"bell":"visual"},"harness":{"notifyOnFinish":true,"notifyOnAwaiting":true},"code":{"fontFamily":"SF Mono","fontSize":13,"formatOnSave":true,"languageServers":[],"dismissedInstallNudges":[],"userDefinedRecipes":{}},"markdown":{"defaultViewMode":"editor"},"changes":{"aiToolId":"none","prompt":"Hello"},"agents":{"builtinState":{},"custom":[],"worktreeAutoLaunch":{"agentId":null,"useBypassPermissions":false}},"files":{"showIgnored":true}}"#
    let data = Data(json.utf8)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.terminal.syncTabTitleWithTerminalTitle == false)
}
```

- [ ] **Step 4: Run tests**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test` (specifically the settings tests)
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Persistence/AppConfig.swift AlasTests/SettingsSaveNormalizationTests.swift
git commit -m "feat(config): add syncTabTitleWithTerminalTitle to terminal config"
```

---

### Task 2: TabsManager – Runtime Title Storage

**Files:**
- Modify: `Alas/Sources/Center/TabsManager.swift`
- Test: `AlasTests/TabsManagerTests.swift`

- [ ] **Step 1: Add `terminalRuntimeTitles` property and API**

In `Alas/Sources/Center/TabsManager.swift`, after `private var pendingExternalOpenGen: [TabID: Int] = [:]`, add:

```swift
/// Runtime-only display titles for terminal pane leaves. Key = leafId.
var terminalRuntimeTitles: [String: String] = [:]
```

Add methods before the existing `// MARK: - Pane tree mutations`:

```swift
// MARK: - Terminal runtime titles

func setTerminalRuntimeTitle(leafId: String, title: String) {
    guard !title.isEmpty else { return }
    terminalRuntimeTitles[leafId] = title
}

func clearTerminalRuntimeTitles(forLeavesInTabId tabId: TabID) {
    guard let file = byWorktree.values.first(where: { $0.tabs.contains(where: { $0.id == tabId }) }) else { return }
    guard let tab = file.tabs.first(where: { $0.id == tabId }),
          case .terminal(let state) = tab else { return }
    for leaf in state.root.leaves() {
        terminalRuntimeTitles.removeValue(forKey: leaf.id)
    }
}

/// Returns the runtime display title for a terminal tab's focused leaf, if any.
func displayTerminalTitle(for tab: Tab) -> String? {
    guard case .terminal(let state) = tab else { return nil }
    guard let leafId = state.root.find(leafId: state.focusedLeafId)?.leaf.id else { return nil }
    return terminalRuntimeTitles[leafId]
}
```

- [ ] **Step 2: Add cleanup in `close`**

In `Alas/Sources/Center/TabsManager.swift`, inside `close(worktreeId:tabId:)`, after:

```swift
let wasActive = file.activeTabId == tabId
file.tabs.remove(at: idx)
```

Add before `if wasActive {`:

```swift
if case .terminal(let state) = tab {
    for leaf in state.root.leaves() {
        terminalRuntimeTitles.removeValue(forKey: leaf.id)
    }
}
```

- [ ] **Step 3: Write tests for runtime title storage**

In `AlasTests/TabsManagerTests.swift`, add:

```swift
@Test func setTerminalRuntimeTitleStoresTitle() {
    let mgr = TabsManager()
    mgr.setTerminalRuntimeTitle(leafId: "leaf1", title: "vim foo")
    #expect(mgr.terminalRuntimeTitles["leaf1"] == "vim foo")
}

@Test func setTerminalRuntimeTitleIgnoresEmptyTitle() {
    let mgr = TabsManager()
    mgr.setTerminalRuntimeTitle(leafId: "leaf1", title: "vim foo")
    mgr.setTerminalRuntimeTitle(leafId: "leaf1", title: "")
    #expect(mgr.terminalRuntimeTitles["leaf1"] == "vim foo")
}

@Test func clearTerminalRuntimeTitlesRemovesLeavesForTab() {
    let mgr = TabsManager()
    let tab = mgr.appendTerminal(worktreeId: "wt", title: "bash", sessionId: "s1")
    guard let state = tab.terminalState else { return }
    let leafId = state.focusedLeafId
    mgr.setTerminalRuntimeTitle(leafId: leafId, title: "vim foo")
    mgr.clearTerminalRuntimeTitles(forLeavesInTabId: tab.id)
    #expect(mgr.terminalRuntimeTitles[leafId] == nil)
}

@Test func displayTerminalTitleReturnsFocusedLeafTitle() {
    let mgr = TabsManager()
    let tab = mgr.appendTerminal(worktreeId: "wt", title: "bash", sessionId: "s1")
    let leafId = tab.terminalState?.focusedLeafId ?? ""
    mgr.setTerminalRuntimeTitle(leafId: leafId, title: "vim foo")
    #expect(mgr.displayTerminalTitle(for: tab) == "vim foo")
}

@Test func displayTerminalTitleReturnsNilForNonTerminalTab() {
    let mgr = TabsManager()
    let tab = mgr.appendEditor(worktreeId: "wt", title: "README.md", relativePath: "README.md")
    #expect(mgr.displayTerminalTitle(for: tab) == nil)
}

@Test func closingTerminalTabCleansUpRuntimeTitles() {
    let mgr = TabsManager()
    let tab = mgr.appendTerminal(worktreeId: "wt", title: "bash", sessionId: "s1")
    let leafId = tab.terminalState?.focusedLeafId ?? ""
    mgr.setTerminalRuntimeTitle(leafId: leafId, title: "vim foo")
    mgr.close(worktreeId: "wt", tabId: tab.id)
    #expect(mgr.terminalRuntimeTitles[leafId] == nil)
}
```

Note: `tab.terminalState` is not a real property — we need to unwrap via `case .terminal`. The tests above are pseudocode; real tests must switch.

Real test code:

```swift
@Test func setTerminalRuntimeTitleStoresTitle() {
    let mgr = TabsManager()
    mgr.setTerminalRuntimeTitle(leafId: "leaf1", title: "vim foo")
    #expect(mgr.terminalRuntimeTitles["leaf1"] == "vim foo")
}

@Test func setTerminalRuntimeTitleIgnoresEmptyTitle() {
    let mgr = TabsManager()
    mgr.setTerminalRuntimeTitle(leafId: "leaf1", title: "vim foo")
    mgr.setTerminalRuntimeTitle(leafId: "leaf1", title: "")
    #expect(mgr.terminalRuntimeTitles["leaf1"] == "vim foo")
}

@Test func closingTerminalTabCleansUpRuntimeTitles() {
    let worktreeId = "wt"
    let mgr = TabsManager()
    let tab = mgr.appendTerminal(worktreeId: worktreeId, title: "bash", sessionId: "s1")
    guard case .terminal(let state) = tab else {
        Issue.record("Expected terminal tab")
        return
    }
    let leafId = state.focusedLeafId
    mgr.setTerminalRuntimeTitle(leafId: leafId, title: "vim foo")
    mgr.close(worktreeId: worktreeId, tabId: tab.id)
    #expect(mgr.terminalRuntimeTitles[leafId] == nil)
}

@Test func displayTerminalTitleReturnsFocusedLeafTitle() {
    let mgr = TabsManager()
    let tab = mgr.appendTerminal(worktreeId: "wt", title: "bash", sessionId: "s1")
    guard case .terminal(let state) = tab else {
        Issue.record("Expected terminal tab")
        return
    }
    mgr.setTerminalRuntimeTitle(leafId: state.focusedLeafId, title: "vim foo")
    #expect(mgr.displayTerminalTitle(for: tab) == "vim foo")
}

@Test func displayTerminalTitleReturnsNilForNonTerminalTab() {
    let mgr = TabsManager()
    let tab = mgr.appendEditor(worktreeId: "wt", title: "README.md", relativePath: "README.md")
    #expect(mgr.displayTerminalTitle(for: tab) == nil)
}
```

- [ ] **Step 4: Run tests**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Center/TabsManager.swift AlasTests/TabsManagerTests.swift
git commit -m "feat(tabs): add runtime terminal title storage"
```

---

### Task 3: TabBarView – Display-Time Title Resolution

**Files:**
- Modify: `Alas/Sources/Center/TabBarView.swift`
- Modify: `Alas/Sources/Center/CenterPaneView.swift`
- Test: `AlasTests/TouchTargetSmokeTests.swift`, `AlasTests/TabActivityIconTintTests.swift`

- [ ] **Step 1: Add `titleLookup` prop to TabBarView and TabButton**

In `Alas/Sources/Center/TabBarView.swift`, add after the existing `let onMove: (TabID, TabID) -> Void`:

```swift
let titleLookup: (TabID) -> String?
```

Inside `TabButton`, add before `let tab: Tab`:

```swift
let titleLookup: (TabID) -> String?
```

Replace `Text(tab.title)` with:

```swift
let displayTitle = titleLookup(tab.id) ?? tab.title
Text(displayTitle)
```

In the `ForEach` inside `TabBarView.body`, update the `TabButton(...)` call to pass `titleLookup: titleLookup`.

- [ ] **Step 2: Update CenterPaneView to pass titleLookup**

In `Alas/Sources/Center/CenterPaneView.swift`, inside the `TabBarView(...)` call, add after `onMove: { ... }`:

```swift
titleLookup: { id in
    guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
    return state.tabs.displayTerminalTitle(for: tab)
}
```

- [ ] **Step 3: Fix test compile errors**

Update `AlasTests/TouchTargetSmokeTests.swift` and `AlasTests/TabActivityIconTintTests.swift` to include `titleLookup: { _ in nil }` in their `TabBarView` instantiation. In `TabActivityIconTintTests.swift` it currently shows three instantiations of `TabBarView(...)` — add `titleLookup: { _ in nil }` to each.

In `TouchTargetSmokeTests.swift` there are four instantiations — add `titleLookup: { _ in nil }` to each.

- [ ] **Step 4: Build to verify compile**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Center/TabBarView.swift Alas/Sources/Center/CenterPaneView.swift AlasTests/TabActivityIconTintTests.swift AlasTests/TouchTargetSmokeTests.swift
git commit -m "feat(tab-bar): display runtime terminal titles"
```

---

### Task 4: TerminalTabView – Wire titleHandler

**Files:**
- Modify: `Alas/Sources/Center/TerminalTabView.swift`

- [ ] **Step 1: Add wireTitleHandler**

In `Alas/Sources/Center/TerminalTabView.swift`, add inside `PaneLeafView` after `wireOpenURLHandler`:

```swift
private func wireTitleHandler(session: TerminalSession, leafId: String) {
    session.surface.titleHandler = { [weak state] title in
        guard let state, !title.isEmpty else { return }
        guard state.config.terminal.syncTabTitleWithTerminalTitle else { return }
        state.tabs.setTerminalRuntimeTitle(leafId: leafId, title: title)
    }
}
```

In `PaneLeafView.onAppear` (where `wireCwdHandler` and `wireOpenURLHandler` are called), add:

```swift
wireTitleHandler(session: session, leafId: leaf.id)
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Alas/Sources/Center/TerminalTabView.swift
git commit -m "feat(terminal-tab): wire titleHandler to runtime title sync"
```

---

### Task 5: AppState – Clear Runtime Titles on Manual Rename

**Files:**
- Modify: `Alas/Sources/App/AppState.swift`

- [ ] **Step 1: Update renameTerminalTab**

In `Alas/Sources/App/AppState.swift`, inside `renameTerminalTab(worktreeId:tabId:)`, after:

```swift
guard alert.runModal() == .alertFirstButtonReturn else { return }
_ = tabs.renameTerminal(worktreeId: worktreeId, tabId: tabId, title: field.stringValue)
```

Add:

```swift
tabs.clearTerminalRuntimeTitles(forLeavesInTabId: tabId)
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Alas/Sources/App/AppState.swift
git commit -m "feat: clear runtime terminal titles on manual tab rename"
```

---

### Task 6: Settings UI – Add Toggle

**Files:**
- Modify: `Alas/Sources/Settings/TerminalPane.swift`

- [ ] **Step 1: Add toggle row in Appearance group**

In `Alas/Sources/Settings/TerminalPane.swift`, inside `SettingsGroup(title: "Appearance")`, after the "Bell" row, add:

```swift
SettingsRow(name: "Sync tab title with terminal title",
            desc: "When the terminal reports a title, update the tab label.") {
    AlasToggle(on: state.bind(\.terminal.syncTabTitleWithTerminalTitle))
}
```

- [ ] **Step 2: Build and test**

Build first to check compile: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' build`

Then run the full test suite: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test`

Expected: BUILD SUCCEEDED, TEST PASS

- [ ] **Step 3: Commit**

```bash
git add Alas/Sources/Settings/TerminalPane.swift
git commit -m "feat(settings): add terminal tab title sync toggle"
```

---

## Spec Coverage Check

| Spec Section | Task |
|---|---|
| Section 1: Config & Settings | Task 1, Task 6 |
| Section 2: TabsManager | Task 2 |
| Section 2: TabBarView | Task 3 |
| Section 2: TerminalTabView | Task 4 |
| Section 2: Manual rename | Task 5 |
| Section: Testing Plan | Each task's test steps |

**No gaps.**

---

## Type Consistency Check

- `setTerminalRuntimeTitle(leafId:title:)` — `leafId: String`, `title: String`
- `clearTerminalRuntimeTitles(forLeavesInTabId:)` — `TabID` (alias for `String`)
- `displayTerminalTitle(for:)` — takes `Tab`, returns `String?`
- `titleLookup` closure — `(TabID) -> String?`
- `syncTabTitleWithTerminalTitle` — `Bool`

All consistent.
