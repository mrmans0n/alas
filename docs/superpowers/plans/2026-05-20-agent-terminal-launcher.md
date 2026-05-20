# Agent Terminal Launcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a sparkle-menu and `Command-Option-T` chooser that launch enabled agents in new terminal tabs for the selected worktree.

**Architecture:** Keep `+` as the plain terminal action and add a separate agent launch path. Centralize agent startup command construction in `AppState` so new-worktree auto-launch and manual launch share bypass-permissions behavior. Use a small testable `AgentLauncherModel` for filtering/selection and a SwiftUI overlay for the keyboard chooser.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Testing, existing `AppState`, `TabsManager`, `ShortcutAction`, `NotificationCenter`, and Ghostty-backed `TerminalService`.

---

## File Structure

- Modify `Alas/Sources/Shortcuts/ShortcutAction.swift`: add the configurable `launchAgentTerminal` action with default `Command-Option-T`.
- Modify `Alas/Sources/App/AlasApp.swift`: add a menu command that posts the agent-launcher notification.
- Modify `Alas/Sources/App/RootView.swift`: add launcher overlay mounting, command handling, and notification name.
- Modify `Alas/Sources/App/AppState.swift`: add `isAgentLauncherOpen`, shared command construction, and manual agent terminal launch API.
- Modify `Alas/Sources/Center/CenterPaneView.swift`: pass enabled agents and launch callback to the tab bar.
- Modify `Alas/Sources/Center/TabBarView.swift`: render the sparkle native menu beside `+`.
- Create `Alas/Sources/Agents/AgentLauncherModel.swift`: pure filtering and keyboard selection model for enabled agents.
- Create `Alas/Sources/Agents/AgentLauncherDialog.swift`: Cmd-K-style overlay for `Command-Option-T`.
- Modify `AlasTests/ShortcutActionTests.swift`: cover the new shortcut action.
- Create `AlasTests/AgentLauncherModelTests.swift`: cover filtering, selection, and empty state.
- Create `AlasTests/AgentTerminalLaunchTests.swift`: cover command construction and disabled/missing agent behavior.

No `project.yml` edit is needed because the target already includes `Alas/Sources` and `AlasTests` directories recursively.

---

### Task 1: Shortcut Action and Notification Plumbing

**Files:**
- Modify: `Alas/Sources/Shortcuts/ShortcutAction.swift`
- Modify: `Alas/Sources/App/AlasApp.swift`
- Modify: `Alas/Sources/App/RootView.swift`
- Test: `AlasTests/ShortcutActionTests.swift`

- [ ] **Step 1: Write the failing shortcut tests**

Update `AlasTests/ShortcutActionTests.swift` expected arrays:

```swift
@Test func defaultsMatchAlasAppValues() {
    let expected: [(ShortcutAction, String, [ShortcutBinding.Modifier])] = [
        (.searchFiles,          "p",          [.command]),
        (.switchRepository,     "k",          [.command]),
        (.findAndReplace,       "f",          [.command, .option]),
        (.toggleRightPane,      "return",     [.command, .option]),
        (.createProject,        "n",          [.command, .shift]),
        (.newWorktree,          "n",          [.command, .option]),
        (.newTerminalTab,       "t",          [.command]),
        (.launchAgentTerminal,  "t",          [.command, .option]),
        (.increaseFontSize,     "=",          [.command]),
        (.decreaseFontSize,     "-",          [.command]),
        (.resetFontSize,        "0",          [.command]),
        (.splitSelectionIntoLines, "l",       [.command, .shift]),
        (.toggleMarkdownPreview, "m",         [.command, .shift]),
        (.commitInComposer,     "return",     [.command]),
        (.splitTerminalRight,   "d",          [.command]),
        (.splitTerminalDown,    "d",          [.command, .shift]),
        (.focusPaneLeft,        "leftArrow",  [.command, .option]),
        (.focusPaneRight,       "rightArrow", [.command, .option]),
        (.focusPaneUp,          "upArrow",    [.command, .option]),
        (.focusPaneDown,        "downArrow",  [.command, .option]),
        (.resizePaneLeft,       "leftArrow",  [.command, .control]),
        (.resizePaneRight,      "rightArrow", [.command, .control]),
        (.resizePaneUp,         "upArrow",    [.command, .control]),
        (.resizePaneDown,       "downArrow",  [.command, .control]),
    ]
    #expect(expected.count == ShortcutAction.allCases.count)
    for (action, key, mods) in expected {
        #expect(action.defaultBinding == ShortcutBinding(key: key, modifiers: mods),
                "default mismatch for \(action)")
    }
}
```

Update the global set in `groupAssignmentsMatchSpec()`:

```swift
let global: Set<ShortcutAction> = [
    .searchFiles, .switchRepository, .findAndReplace, .toggleRightPane,
    .createProject, .newWorktree, .newTerminalTab, .launchAgentTerminal,
    .increaseFontSize, .decreaseFontSize, .resetFontSize,
]
```

- [ ] **Step 2: Run the shortcut tests to verify failure**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ShortcutActionTests
```

Expected: FAIL because `ShortcutAction.launchAgentTerminal` does not exist.

- [ ] **Step 3: Add the shortcut action**

In `Alas/Sources/Shortcuts/ShortcutAction.swift`, update the global cases:

```swift
case searchFiles, switchRepository, findAndReplace, toggleRightPane,
     createProject, newWorktree, newTerminalTab, launchAgentTerminal,
     increaseFontSize, decreaseFontSize, resetFontSize
```

Add it to the global group switch:

```swift
case .searchFiles, .switchRepository, .findAndReplace, .toggleRightPane,
     .createProject, .newWorktree, .newTerminalTab, .launchAgentTerminal,
     .increaseFontSize, .decreaseFontSize, .resetFontSize:
    return .global
```

Add label and description:

```swift
case .launchAgentTerminal:      return "Launch Agent Terminal"
```

```swift
case .launchAgentTerminal: return "Open the agent launcher"
```

Add default binding:

```swift
case .launchAgentTerminal:      return .init(key: "t", modifiers: [.command, .option])
```

- [ ] **Step 4: Add app command and notification**

In `Alas/Sources/App/AlasApp.swift`, add this after `New Terminal Tab` in the toolbar command group:

```swift
Button("Launch Agent Terminal…") {
    NotificationCenter.default.post(name: .alasOpenAgentLauncher, object: nil)
}
.keyboardShortcut(state.shortcut(for: .launchAgentTerminal))
.disabled(state.projects.isEmpty)
```

In `Alas/Sources/App/RootView.swift`, add the notification:

```swift
static let alasOpenAgentLauncher = Notification.Name("AlasOpenAgentLauncher")
```

- [ ] **Step 5: Run shortcut tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ShortcutActionTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Shortcuts/ShortcutAction.swift Alas/Sources/App/AlasApp.swift Alas/Sources/App/RootView.swift AlasTests/ShortcutActionTests.swift
git commit -m "Add agent launcher shortcut"
```

---

### Task 2: Shared Agent Startup Command Construction

**Files:**
- Modify: `Alas/Sources/App/AppState.swift`
- Test: `AlasTests/AgentTerminalLaunchTests.swift`

- [ ] **Step 1: Write failing command construction tests**

Create `AlasTests/AgentTerminalLaunchTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

@MainActor
struct AgentTerminalLaunchTests {
    private func agent(flag: String? = "--skip") -> AgentDefinition {
        AgentDefinition(
            id: "test-agent",
            displayName: "Test Agent",
            binary: "test-agent",
            binaryOverride: nil,
            promptModeArgs: ["-p"],
            bypassPermissionsFlag: flag,
            isBuiltin: false,
            isEnabled: true,
            builtinLogoAssetName: nil
        )
    }

    private func project(mode: ProjectStartupScriptMode, useBypass: Bool) -> ProjectConfig {
        var project = ProjectConfig(
            id: "project",
            name: "Project",
            path: "/tmp/project",
            color: "blue",
            addedAt: Date()
        )
        project.startupScripts.worktreeAgentMode = mode
        project.startupScripts.worktreeAgentUseBypassPermissions = useBypass
        return project
    }

    @Test func globalBypassAddsAgentFlag() {
        let state = AppState()
        state.config.agents.worktreeAutoLaunch.useBypassPermissions = true
        let command = state.agentStartupCommand(
            for: agent(),
            project: project(mode: .useGlobal, useBypass: false)
        )
        #expect(command == "test-agent --skip")
    }

    @Test func disabledProjectModeOmitsBypassFlag() {
        let state = AppState()
        state.config.agents.worktreeAutoLaunch.useBypassPermissions = true
        let command = state.agentStartupCommand(
            for: agent(),
            project: project(mode: .disabled, useBypass: true)
        )
        #expect(command == "test-agent")
    }

    @Test func projectOverrideBypassWinsOverGlobal() {
        let state = AppState()
        state.config.agents.worktreeAutoLaunch.useBypassPermissions = false
        let command = state.agentStartupCommand(
            for: agent(),
            project: project(mode: .overrideGlobal, useBypass: true)
        )
        #expect(command == "test-agent --skip")
    }

    @Test func missingBypassFlagCannotBeAppended() {
        let state = AppState()
        state.config.agents.worktreeAutoLaunch.useBypassPermissions = true
        let command = state.agentStartupCommand(
            for: agent(flag: nil),
            project: project(mode: .useGlobal, useBypass: true)
        )
        #expect(command == "test-agent")
    }

    @Test func binaryPathIsShellQuoted() {
        var custom = agent()
        custom.binaryOverride = "/Applications/Test Agent/bin/agent"
        let state = AppState()
        let command = state.agentStartupCommand(
            for: custom,
            project: project(mode: .disabled, useBypass: false)
        )
        #expect(command == "'/Applications/Test Agent/bin/agent'")
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AgentTerminalLaunchTests
```

Expected: FAIL because `agentStartupCommand(for:project:)` does not exist.

- [ ] **Step 3: Add command helpers in `AppState`**

In `Alas/Sources/App/AppState.swift`, near `createWorktree`, add:

```swift
func agentStartupCommand(for agent: AgentDefinition, project: ProjectConfig) -> String {
    var argv = [agent.resolvedBinary]
    if agentBypassPermissionsEnabled(for: project),
       let flag = agent.bypassPermissionsFlag {
        argv.append(flag)
    }
    return argv.map { Self.shellQuote($0) }.joined(separator: " ")
}

private func agentBypassPermissionsEnabled(for project: ProjectConfig) -> Bool {
    switch project.startupScripts.worktreeAgentMode {
    case .disabled:
        return false
    case .useGlobal:
        return config.agents.worktreeAutoLaunch.useBypassPermissions
    case .overrideGlobal, .appendToGlobal:
        return project.startupScripts.worktreeAgentUseBypassPermissions
    }
}
```

- [ ] **Step 4: Refactor new-worktree auto-launch to use the helper**

Replace the `launchAgentCommand` closure inside `createWorktree` with:

```swift
let launchAgentCommand: String? = {
    guard let id = launchAgentId,
          let agent = self.agentRegistry.enabled().first(where: { $0.id == id })
    else { return nil }
    return self.agentStartupCommand(for: agent, project: project)
}()
```

- [ ] **Step 5: Run command construction tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AgentTerminalLaunchTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/App/AppState.swift AlasTests/AgentTerminalLaunchTests.swift
git commit -m "Share agent launch command construction"
```

---

### Task 3: Manual Agent Terminal Launch API

**Files:**
- Modify: `Alas/Sources/App/AppState.swift`
- Test: `AlasTests/AgentTerminalLaunchTests.swift`

- [ ] **Step 1: Write failing launch API tests**

Append this helper and these tests to `AgentTerminalLaunchTests`:

```swift
private struct MemoryStore: PersistenceStoreProtocol {
    func write<T: Encodable>(_: T, to _: URL) throws {}
    func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
}

@Test func disabledAgentIdDoesNotLaunch() {
    let state = AppState()
    let worktree = Worktree(
        id: "wt",
        projectId: "project",
        name: "main",
        branch: "main",
        path: URL(fileURLWithPath: "/tmp/project"),
        status: .clean,
        lastActivity: Date()
    )

    #expect(throws: AppState.AgentTerminalLaunchError.self) {
        _ = try state.openAgentTerminalTab(for: worktree, agentId: "missing")
    }
}

@Test func missingProjectDoesNotLaunch() {
    let state = AppState()
    state.agentRegistry = AgentRegistry(
        builtinState: [:],
        customs: [agent()],
        installedIds: ["test-agent"]
    )
    let worktree = Worktree(
        id: "wt",
        projectId: "missing-project",
        name: "main",
        branch: "main",
        path: URL(fileURLWithPath: "/tmp/project"),
        status: .clean,
        lastActivity: Date()
    )

    #expect(throws: AppState.AgentTerminalLaunchError.self) {
        _ = try state.openAgentTerminalTab(for: worktree, agentId: "test-agent")
    }
}

@Test func manualLaunchAppendsTerminalTabWithStartupSuffix() throws {
    var capturedSuffix: String?
    let project = project(mode: .useGlobal, useBypass: false)
    let worktree = Worktree(
        id: "wt",
        projectId: project.id,
        name: "main",
        branch: "main",
        path: URL(fileURLWithPath: "/tmp/project"),
        status: .clean,
        lastActivity: Date()
    )
    let state = AppState(
        store: MemoryStore(),
        terminalSessionOpener: { _, _, _, _, _, startupScriptSuffix in
            capturedSuffix = startupScriptSuffix
            return AppState.OpenedTerminalSession(id: "session-1", foregroundPid: { nil })
        }
    )
    state.config.agents.worktreeAutoLaunch.useBypassPermissions = true
    state.projectsManager = ProjectsManager(persistedProjects: [project])
    state.agentRegistry = AgentRegistry(
        builtinState: [:],
        customs: [agent()],
        installedIds: ["test-agent"]
    )

    let tab = try state.openAgentTerminalTab(for: worktree, agentId: "test-agent")

    #expect(capturedSuffix == "test-agent --skip")
    #expect(state.tabs.tabs(forWorktree: worktree.id) == [tab])
    if case .terminal(let terminal) = tab {
        #expect(terminal.root.firstLeaf().sessionId == "session-1")
    } else {
        Issue.record("Expected a terminal tab")
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AgentTerminalLaunchTests
```

Expected: FAIL because `openAgentTerminalTab(for:agentId:)`, `AgentTerminalLaunchError`, `OpenedTerminalSession`, and the `terminalSessionOpener` initializer parameter do not exist.

- [ ] **Step 3: Add terminal opening injection for tests**

In `Alas/Sources/App/AppState.swift`, inside `AppState`, add these stored-test seam types near the terminal property:

```swift
struct OpenedTerminalSession {
    let id: String
    let foregroundPid: () -> pid_t?
}

typealias TerminalSessionOpener = (
    Worktree,
    ProjectConfig,
    AppConfig.Terminal,
    Theme,
    URL?,
    String?
) throws -> OpenedTerminalSession

@ObservationIgnored
private let terminalSessionOpener: TerminalSessionOpener?
```

Update `AppState.init` to accept and store the opener:

```swift
init(
    store: any PersistenceStoreProtocol = PersistenceStore(),
    persistenceErrorHandler: ((String, String) -> Void)? = nil,
    terminalSessionOpener: TerminalSessionOpener? = nil
) {
    self.store = store
    self.persistenceErrorHandler = persistenceErrorHandler ?? { title, message in
        AppState.showWarningAlert(title: title, message: message)
    }
    self.terminalSessionOpener = terminalSessionOpener
    let config = (try? store.readIfExists(AppConfig.self, from: Paths.appConfigFile)) ?? AppConfig.defaults
    let projectsFile = (try? store.readIfExists(ProjectsFile.self, from: Paths.projectsFile)) ?? ProjectsFile(projects: [])
    self.config = config
    ShortcutReservations.update(from: config)
    self.projectsManager = ProjectsManager(persistedProjects: projectsFile.projects)
    let themeStore = (try? ThemeStore(initialId: config.themeId)) ?? (try! ThemeStore())
    themeStore.setAccent(config.accent)
    if config.matchSystemTheme {
        themeStore.setMatchSystem(true)
    }
    self.themeStore = themeStore
    WindowAppearance.apply(darkMode: themeStore.current.darkMode)
}
```

Keep the rest of the initializer body exactly as it is after the `WindowAppearance.apply(...)` call.

Update `openTerminalTab(for:startupScriptSuffix:)` to use the injected opener:

```swift
let opened: OpenedTerminalSession
if let terminalSessionOpener {
    opened = try terminalSessionOpener(
        worktree,
        project,
        config.terminal,
        themeStore.current,
        nil,
        startupScriptSuffix
    )
} else {
    let session = try terminal.openSession(
        worktree: worktree, project: project,
        cfg: config.terminal, theme: themeStore.current,
        startupScriptSuffix: startupScriptSuffix
    )
    opened = OpenedTerminalSession(id: session.id, foregroundPid: { [weak session] in
        session?.surface.foregroundPid
    })
}
harness.detector.register(sessionId: opened.id, pidProvider: opened.foregroundPid)
let title = tabs.nextTerminalTitle(
    worktreeId: worktree.id,
    baseTitle: defaultTerminalTitle(for: worktree)
)
return tabs.appendTerminal(worktreeId: worktree.id, title: title, sessionId: opened.id)
```

- [ ] **Step 4: Add the launch error and API**

In `Alas/Sources/App/AppState.swift`, inside `AppState`, add:

```swift
enum AgentTerminalLaunchError: LocalizedError, Equatable {
    case projectUnavailable
    case agentUnavailable

    var errorDescription: String? {
        switch self {
        case .projectUnavailable:
            return "The selected worktree's project is no longer available."
        case .agentUnavailable:
            return "The selected agent is no longer enabled."
        }
    }
}

@discardableResult
func openAgentTerminalTab(for worktree: Worktree, agentId: String) throws -> Tab {
    guard let project = projects.first(where: { $0.id == worktree.projectId }) else {
        throw AgentTerminalLaunchError.projectUnavailable
    }
    guard let agent = agentRegistry.enabled().first(where: { $0.id == agentId }) else {
        throw AgentTerminalLaunchError.agentUnavailable
    }
    do {
        return try openTerminalTab(
            for: worktree,
            startupScriptSuffix: agentStartupCommand(for: agent, project: project)
        )
    } catch {
        showFileActionError(title: "Launch Agent Failed", message: error.localizedDescription)
        throw error
    }
}
```

- [ ] **Step 5: Run tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AgentTerminalLaunchTests
```

Expected: PASS for command construction and missing-state tests.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/App/AppState.swift AlasTests/AgentTerminalLaunchTests.swift
git commit -m "Add manual agent terminal launch API"
```

---

### Task 4: Tab-Bar Sparkle Menu

**Files:**
- Modify: `Alas/Sources/Center/TabBarView.swift`
- Modify: `Alas/Sources/Center/CenterPaneView.swift`

- [ ] **Step 1: Extend `TabBarView` inputs**

In `TabBarView`, add properties:

```swift
let enabledAgents: [AgentDefinition]
let onLaunchAgent: (String) -> Void
```

Update the `TabBarView(...)` call in `CenterPaneView` to pass:

```swift
enabledAgents: state.agentRegistry.enabled(),
onLaunchAgent: { agentId in
    try? state.openAgentTerminalTab(for: worktree, agentId: agentId)
},
```

- [ ] **Step 2: Add the sparkle menu view**

In `TabBarView.body`, after the plus button, add:

```swift
AgentSparkleMenu(
    agents: enabledAgents,
    onLaunchAgent: onLaunchAgent
)
.padding(.trailing, 8)
```

Then remove the trailing horizontal padding from the plus button or change it to:

```swift
.padding(.leading, 8)
.padding(.trailing, 2)
```

- [ ] **Step 3: Add the menu component in `TabBarView.swift`**

Add below `ToolbarIconButton`:

```swift
private struct AgentSparkleMenu: View {
    let agents: [AgentDefinition]
    let onLaunchAgent: (String) -> Void
    @Environment(\.theme) var theme

    var body: some View {
        Menu {
            if agents.isEmpty {
                Text("No enabled agents")
            } else {
                ForEach(agents) { agent in
                    Button {
                        onLaunchAgent(agent.id)
                    } label: {
                        Text(agent.displayName)
                    }
                }
            }
        } label: {
            Icon(name: "sparkle", size: 13, color: theme.color("fg-faint"))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(agents.isEmpty ? "No enabled agents" : "Launch agent")
    }
}
```

If `Icon(name: "sparkle")` is not mapped, add `"sparkle"` to `Alas/Sources/Icons/Icon.swift` with the SF Symbol `sparkles`.

- [ ] **Step 4: Build to verify SwiftUI call sites**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Center/TabBarView.swift Alas/Sources/Center/CenterPaneView.swift Alas/Sources/Icons/Icon.swift
git commit -m "Add tab bar agent launch menu"
```

---

### Task 5: Agent Launcher Model

**Files:**
- Create: `Alas/Sources/Agents/AgentLauncherModel.swift`
- Test: `AlasTests/AgentLauncherModelTests.swift`

- [ ] **Step 1: Write model tests**

Create `AlasTests/AgentLauncherModelTests.swift`:

```swift
import Testing
@testable import Alas

@MainActor
struct AgentLauncherModelTests {
    private func agent(_ id: String, _ name: String) -> AgentDefinition {
        AgentDefinition(
            id: id,
            displayName: name,
            binary: id,
            binaryOverride: nil,
            promptModeArgs: [],
            bypassPermissionsFlag: nil,
            isBuiltin: false,
            isEnabled: true,
            builtinLogoAssetName: nil
        )
    }

    @Test func rowsFilterByDisplayName() {
        let model = AgentLauncherModel()
        model.query = "cla"
        let rows = model.rows(agents: [
            agent("claude", "Claude Code"),
            agent("codex", "Codex"),
        ])
        #expect(rows.map(\.id) == ["claude"])
    }

    @Test func selectionClampsWhenRowsShrink() {
        let model = AgentLauncherModel()
        model.selectedIndex = 3
        let rows = model.rows(agents: [agent("codex", "Codex")])
        #expect(rows.map(\.id) == ["codex"])
        #expect(model.selectedIndex == 0)
    }

    @Test func moveSelectionStaysInsideBounds() {
        let model = AgentLauncherModel()
        let rows = [
            agent("claude", "Claude Code"),
            agent("codex", "Codex"),
        ]
        model.moveSelectionDown(in: rows)
        model.moveSelectionDown(in: rows)
        #expect(model.selectedIndex == 1)
        model.moveSelectionUp(in: rows)
        model.moveSelectionUp(in: rows)
        #expect(model.selectedIndex == 0)
    }

    @Test func selectedAgentReturnsNilForEmptyRows() {
        let model = AgentLauncherModel()
        #expect(model.selectedAgent(in: []) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AgentLauncherModelTests
```

Expected: FAIL because `AgentLauncherModel` does not exist.

- [ ] **Step 3: Add `AgentLauncherModel`**

Create `Alas/Sources/Agents/AgentLauncherModel.swift`:

```swift
import Foundation
import Observation

@Observable
@MainActor
final class AgentLauncherModel {
    var query: String = "" {
        didSet { selectedIndex = 0 }
    }
    var selectedIndex: Int = 0
    var scrollToSelectionTick: Int = 0

    func rows(agents: [AgentDefinition]) -> [AgentDefinition] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [AgentDefinition]
        if trimmed.isEmpty {
            filtered = agents
        } else {
            filtered = agents.filter {
                $0.displayName.localizedCaseInsensitiveContains(trimmed)
                    || $0.id.localizedCaseInsensitiveContains(trimmed)
            }
        }
        if filtered.isEmpty {
            selectedIndex = 0
        } else {
            selectedIndex = min(max(0, selectedIndex), filtered.count - 1)
        }
        return filtered
    }

    func moveSelectionUp(in rows: [AgentDefinition]) {
        guard !rows.isEmpty else {
            selectedIndex = 0
            return
        }
        selectedIndex = max(0, selectedIndex - 1)
        scrollToSelectionTick += 1
    }

    func moveSelectionDown(in rows: [AgentDefinition]) {
        guard !rows.isEmpty else {
            selectedIndex = 0
            return
        }
        selectedIndex = min(rows.count - 1, selectedIndex + 1)
        scrollToSelectionTick += 1
    }

    func selectedAgent(in rows: [AgentDefinition]) -> AgentDefinition? {
        rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil
    }

    func reset() {
        query = ""
        selectedIndex = 0
        scrollToSelectionTick = 0
    }
}
```

- [ ] **Step 4: Run model tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AgentLauncherModelTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Agents/AgentLauncherModel.swift AlasTests/AgentLauncherModelTests.swift
git commit -m "Add agent launcher model"
```

---

### Task 6: Keyboard Agent Launcher Dialog

**Files:**
- Create: `Alas/Sources/Agents/AgentLauncherDialog.swift`
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `Alas/Sources/App/RootView.swift`

- [ ] **Step 1: Add launcher state to `AppState`**

In `AppState`, near search and repo selector state, add:

```swift
var isAgentLauncherOpen: Bool = false
let agentLauncher = AgentLauncherModel()
```

- [ ] **Step 2: Mount the dialog in `RootView`**

In the `ZStack` that already contains `FileSearchDialog` and `RepoSelectorDialog`, add:

```swift
AgentLauncherDialog(appState: state, selectedWorktree: selectedWorktree)
```

Place it after the repo selector so it wins focus when open.

- [ ] **Step 3: Handle the open notification**

In `RootBaseHandlers.body`, after the repo selector notification handler, add a handler:

```swift
let p = o
    .onReceive(NotificationCenter.default.publisher(for: .alasOpenAgentLauncher)) { _ in
        guard selectedWorktree() != nil else { return }
        if state.isAgentLauncherOpen {
            state.agentLauncher.reset()
            state.isAgentLauncherOpen = false
        } else {
            state.search.close()
            state.isSearchOpen = false
            state.repoSelector.close()
            state.isRepoSelectorOpen = false
            state.agentLauncher.reset()
            state.isAgentLauncherOpen = true
        }
    }
let q = p
    .onReceive(NotificationCenter.default.publisher(for: .alasRefreshWorktrees)) { _ in
        let beforeIds = state.allWorktreeIds()
        Task {
            let changed = await state.projectsManager.refreshAll()
            if changed {
                state.saveProjects()
            }
            state.cleanupMissingWorktrees(beforeIds: beforeIds)
        }
    }
return q
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
        state.stopAllProjectGitWatchers()
        state.tabs.snapshotDirtyBuffersForQuit()
    }
```

Remove the old `let p = o ... alasRefreshWorktrees` block while making this edit so the variable chain stays linear.

- [ ] **Step 4: Create `AgentLauncherDialog`**

Create `Alas/Sources/Agents/AgentLauncherDialog.swift`:

```swift
import SwiftUI

struct AgentLauncherDialog: View {
    @Bindable var appState: AppState
    let selectedWorktree: () -> Worktree?
    @Environment(\.theme) private var theme
    @FocusState private var inputFocused: Bool

    var body: some View {
        if appState.isAgentLauncherOpen {
            ZStack {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .onTapGesture { close() }

                VStack(spacing: 0) {
                    inputRow
                    Divider().background(theme.color("line"))
                    rowList
                    footer
                }
                .frame(width: 460)
                .frame(maxHeight: 420)
                .background(theme.color("bg-1").opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.color("line"), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 20)
                .padding(.top, 70)
                .frame(maxHeight: .infinity, alignment: .top)
                .onTapGesture { }
                .onKeyPress { press in handleKey(press) }
            }
            .transition(.opacity.combined(with: .offset(y: -6)))
            .onAppear {
                appState.agentLauncher.reset()
                inputFocused = true
            }
        }
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            Icon(name: "sparkle", size: 12, color: theme.color("fg-faint"))
            TextField("Launch agent…", text: Bindable(appState.agentLauncher).query)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .font(.system(size: 14))
                .foregroundColor(theme.color("fg"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var rowList: some View {
        let rows = appState.agentLauncher.rows(agents: appState.agentRegistry.enabled())
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { idx, agent in
                            AgentLauncherRow(
                                agent: agent,
                                isSelected: idx == appState.agentLauncher.selectedIndex,
                                onTap: {
                                    appState.agentLauncher.selectedIndex = idx
                                    launch(agent)
                                },
                                onHover: { appState.agentLauncher.selectedIndex = idx }
                            )
                            .id(idx)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 180, maxHeight: 340)
            .onChange(of: appState.agentLauncher.scrollToSelectionTick) { _, _ in
                proxy.scrollTo(appState.agentLauncher.selectedIndex, anchor: .center)
            }
        }
    }

    private var emptyState: some View {
        Text("No enabled agents")
            .font(.system(size: 12))
            .foregroundColor(theme.color("fg-dim"))
            .frame(maxWidth: .infinity, minHeight: 160)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            label("↑↓ navigate")
            label("↵ launch")
            label("esc close")
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.color("bg-2").opacity(0.5))
        .overlay(
            Rectangle().fill(theme.color("line-soft")).frame(height: 0.5),
            alignment: .top
        )
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(theme.color("fg-faint"))
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let rows = appState.agentLauncher.rows(agents: appState.agentRegistry.enabled())
        switch press.key {
        case .escape:
            close()
            return .handled
        case .upArrow:
            appState.agentLauncher.moveSelectionUp(in: rows)
            return .handled
        case .downArrow:
            appState.agentLauncher.moveSelectionDown(in: rows)
            return .handled
        case .return:
            if let agent = appState.agentLauncher.selectedAgent(in: rows) {
                launch(agent)
            }
            return .handled
        default:
            return .ignored
        }
    }

    private func launch(_ agent: AgentDefinition) {
        guard let worktree = selectedWorktree() else {
            close()
            return
        }
        _ = try? appState.openAgentTerminalTab(for: worktree, agentId: agent.id)
        close()
    }

    private func close() {
        appState.agentLauncher.reset()
        appState.isAgentLauncherOpen = false
    }
}

private struct AgentLauncherRow: View {
    let agent: AgentDefinition
    let isSelected: Bool
    let onTap: () -> Void
    let onHover: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            logo
            Text(agent.displayName)
                .font(.system(size: 13))
                .foregroundColor(theme.color("fg"))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(isSelected ? theme.color("bg-3") : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering in
            if hovering { onHover() }
        }
    }

    @ViewBuilder
    private var logo: some View {
        if let asset = agent.builtinLogoAssetName, NSImage(named: asset) != nil {
            Image(asset)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
        } else {
            Icon(name: "sparkle", size: 14, color: theme.color("fg-muted"))
                .frame(width: 16, height: 16)
        }
    }
}
```

- [ ] **Step 5: Build**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Agents/AgentLauncherDialog.swift Alas/Sources/App/AppState.swift Alas/Sources/App/RootView.swift
git commit -m "Add keyboard agent launcher"
```

---

### Task 7: Final Verification

**Files:**
- Verify all modified files.

- [ ] **Step 1: Regenerate Xcode project**

Run:

```bash
xcodegen
```

Expected: exits 0. If it changes `Alas.xcodeproj/project.pbxproj`, include it in the final commit.

- [ ] **Step 2: Build**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: PASS.

- [ ] **Step 3: Run full test suite**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: PASS.

- [ ] **Step 4: Manual smoke test**

Run the app from Xcode or the built app and verify:

- Clicking `+` opens a plain terminal tab.
- Clicking sparkle opens a menu with enabled agents.
- Selecting an enabled agent opens a new terminal tab and runs that agent command.
- `Command-Option-T` opens the launcher dialog.
- Typing filters agents by display name.
- Return launches the highlighted agent in a new terminal tab.
- Escape closes the launcher without opening a tab.
- With all agents disabled, sparkle shows "No enabled agents" and the launcher shows the empty state.

- [ ] **Step 5: Final commit**

If verification changed generated files or small fixes were needed, commit them:

```bash
git add Alas.xcodeproj/project.pbxproj Alas/Sources AlasTests
git commit -m "Verify agent terminal launcher"
```

Skip this commit if there are no changes after Task 6.
