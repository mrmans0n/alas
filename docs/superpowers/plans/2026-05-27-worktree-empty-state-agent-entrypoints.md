# Worktree Empty State Agent Entrypoints Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the worktree empty-state single terminal button with command rows for normal terminal, agent terminal, and agent chat, and add a dedicated shortcut for launching agent chat.

**Architecture:** Reuse the existing `AgentLauncherDialog` and `AgentLauncherModel`; add AppState APIs that open the launcher with an optional requested mode. Keep tab creation paths unchanged: normal terminal still calls `openTerminalTab`, agent terminal still calls `openAgentTerminalTab`, and agent chat still calls `openNewACPSession`.

**Tech Stack:** Swift 5.9, SwiftUI, Observation, Swift Testing, existing Alas shortcut and theme systems.

---

## File Structure

- Modify `Alas/Sources/Shortcuts/ShortcutAction.swift`: add the new global shortcut action `launchAgentChat`.
- Modify `AlasTests/ShortcutActionTests.swift`: update default binding and group expectations.
- Modify `AlasTests/ShortcutResolverTests.swift`: prove the new shortcut participates in conflict detection.
- Modify `Alas/Sources/App/AppState.swift`: add `openAgentLauncherOverlay(mode:)` and update `toggleAgentLauncherOverlay(canOpen:)` to use it.
- Modify `Alas/Sources/Agents/AgentLauncherDialog.swift`: stop reapplying the configured default mode on appear.
- Modify `AlasTests/AppStateOverlayTests.swift`: cover explicit Terminal mode, explicit Chat mode, and default-mode behavior.
- Modify `Alas/Sources/App/AlasApp.swift`: add the new menu command and shortcut.
- Modify `Alas/Sources/App/RootView.swift`: route agent launcher notifications with optional mode payloads.
- Modify `Alas/Sources/Center/EmptyTabView.swift`: replace the single button with themed command rows.
- Modify `Alas/Sources/Center/CenterPaneView.swift`: wire empty-state callbacks and effective shortcut labels.

## Task 1: Add Agent Chat Shortcut Model

**Files:**
- Modify: `Alas/Sources/Shortcuts/ShortcutAction.swift`
- Test: `AlasTests/ShortcutActionTests.swift`
- Test: `AlasTests/ShortcutResolverTests.swift`

- [ ] **Step 1: Write failing shortcut tests**

In `AlasTests/ShortcutActionTests.swift`, update the `expected` array in `defaultsMatchAlasAppValues()` to include `.launchAgentChat` immediately after `.launchAgentTerminal`:

```swift
(.newTerminalTab,       "t",          [.command]),
(.launchAgentTerminal,  "t",          [.command, .option]),
(.launchAgentChat,      "t",          [.command, .option, .shift]),
(.increaseFontSize,     "=",          [.command]),
```

In the same file, update the `global` set in `groupAssignmentsMatchSpec()`:

```swift
let global: Set<ShortcutAction> = [
    .searchFiles, .switchRepository, .findAndReplace, .toggleSidebar, .toggleRightPane,
    .createProject, .newWorktree, .newTerminalTab, .launchAgentTerminal, .launchAgentChat,
    .increaseFontSize, .decreaseFontSize, .resetFontSize,
]
```

In `AlasTests/ShortcutResolverTests.swift`, add this test before `conflictNilWhenNoneFound()`:

```swift
@Test func conflictDetectsAgentChatDefaultBinding() async {
    let state = makeState()
    let binding = ShortcutBinding(key: "t", modifiers: [.command, .option, .shift])
    let conflict = state.conflict(for: binding, excluding: .searchFiles)
    #expect(conflict == .launchAgentChat)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ShortcutActionTests -only-testing:AlasTests/ShortcutResolverTests test
```

Expected: compile failure because `ShortcutAction.launchAgentChat` does not exist.

- [ ] **Step 3: Implement the shortcut action**

In `Alas/Sources/Shortcuts/ShortcutAction.swift`, add `launchAgentChat` to the global action cases:

```swift
case searchFiles, switchRepository, findAndReplace, toggleSidebar, toggleRightPane,
     createProject, newWorktree, newTerminalTab, launchAgentTerminal, launchAgentChat,
     increaseFontSize, decreaseFontSize, resetFontSize
```

Update the `group` switch global cases:

```swift
case .searchFiles, .switchRepository, .findAndReplace, .toggleSidebar, .toggleRightPane,
     .createProject, .newWorktree, .newTerminalTab, .launchAgentTerminal, .launchAgentChat,
     .increaseFontSize, .decreaseFontSize, .resetFontSize:
    return .global
```

Update `label`:

```swift
case .launchAgentChat:          return "Launch Agent Chat"
```

Update `description`:

```swift
case .launchAgentTerminal: return "Open the agent launcher in Terminal mode"
case .launchAgentChat:     return "Open the agent launcher in Chat mode"
```

Update `defaultBinding`:

```swift
case .launchAgentTerminal:      return .init(key: "t",          modifiers: [.command, .option])
case .launchAgentChat:          return .init(key: "t",          modifiers: [.command, .option, .shift])
case .increaseFontSize:         return .init(key: "=",          modifiers: [.command])
```

- [ ] **Step 4: Run shortcut tests to verify they pass**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ShortcutActionTests -only-testing:AlasTests/ShortcutResolverTests test
```

Expected: both test suites pass.

- [ ] **Step 5: Commit**

```bash
rtk git add Alas/Sources/Shortcuts/ShortcutAction.swift AlasTests/ShortcutActionTests.swift AlasTests/ShortcutResolverTests.swift
rtk git commit -m "Add agent chat launcher shortcut"
```

## Task 2: Add Scoped Agent Launcher Opening

**Files:**
- Modify: `Alas/Sources/App/AppState.swift`
- Test: `AlasTests/AppStateOverlayTests.swift`

- [ ] **Step 1: Write failing AppState overlay tests**

Append these tests to `AlasTests/AppStateOverlayTests.swift`:

```swift
@Test func openingAgentLauncherWithExplicitTerminalModeOverridesDefault() {
    let state = AppState(store: MemoryStore())
    state.config.agents.defaultLauncherMode = .acp
    state.isSearchOpen = true
    state.isRepoSelectorOpen = true
    state.agentLauncher.query = "codex"
    state.agentLauncher.selectedIndex = 4

    state.openAgentLauncherOverlay(mode: .terminal)

    #expect(state.isAgentLauncherOpen)
    #expect(!state.isSearchOpen)
    #expect(!state.isRepoSelectorOpen)
    #expect(state.agentLauncher.mode == .terminal)
    #expect(state.agentLauncher.query == "")
    #expect(state.agentLauncher.selectedIndex == 0)
    #expect(state.config.agents.defaultLauncherMode == .acp)
}

@Test func openingAgentLauncherWithExplicitChatModeOverridesDefault() {
    let state = AppState(store: MemoryStore())
    state.config.agents.defaultLauncherMode = .terminal

    state.openAgentLauncherOverlay(mode: .acp)

    #expect(state.isAgentLauncherOpen)
    #expect(state.agentLauncher.mode == .acp)
    #expect(state.config.agents.defaultLauncherMode == .terminal)
}

@Test func openingAgentLauncherWithoutModeUsesConfiguredDefault() {
    let state = AppState(store: MemoryStore())
    state.config.agents.defaultLauncherMode = .acp

    state.openAgentLauncherOverlay(mode: nil)

    #expect(state.isAgentLauncherOpen)
    #expect(state.agentLauncher.mode == .acp)
}

@Test func toggleAgentLauncherClosedOpensUsingConfiguredDefault() {
    let state = AppState(store: MemoryStore())
    state.config.agents.defaultLauncherMode = .acp

    state.toggleAgentLauncherOverlay(canOpen: true)

    #expect(state.isAgentLauncherOpen)
    #expect(state.agentLauncher.mode == .acp)
}

@Test func toggleAgentLauncherOpenClosesAndResets() {
    let state = AppState(store: MemoryStore())
    state.isAgentLauncherOpen = true
    state.agentLauncher.mode = .acp
    state.agentLauncher.query = "claude"
    state.agentLauncher.selectedIndex = 3

    state.toggleAgentLauncherOverlay(canOpen: true)

    #expect(!state.isAgentLauncherOpen)
    #expect(state.agentLauncher.query == "")
    #expect(state.agentLauncher.selectedIndex == 0)
}
```

- [ ] **Step 2: Run overlay tests to verify they fail**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/AppStateOverlayTests test
```

Expected: compile failure because `openAgentLauncherOverlay(mode:)` does not exist.

- [ ] **Step 3: Implement scoped launcher opening**

In `Alas/Sources/App/AppState.swift`, replace `toggleAgentLauncherOverlay(canOpen:)` with this pair of methods:

```swift
func openAgentLauncherOverlay(mode: AppConfig.LauncherMode? = nil) {
    search.close()
    isSearchOpen = false
    repoSelector.close()
    isRepoSelectorOpen = false
    agentLauncher.prepareForOpen(
        defaultMode: mode ?? config.agents.defaultLauncherMode
    )
    isAgentLauncherOpen = true
}

func toggleAgentLauncherOverlay(canOpen: Bool) {
    guard canOpen else { return }
    if isAgentLauncherOpen {
        agentLauncher.reset()
        isAgentLauncherOpen = false
    } else {
        openAgentLauncherOverlay(mode: nil)
    }
}
```

- [ ] **Step 4: Stop AgentLauncherDialog from re-preparing on appear**

In `Alas/Sources/Agents/AgentLauncherDialog.swift`, remove this block from `.onAppear`:

```swift
appState.agentLauncher.prepareForOpen(
    defaultMode: appState.config.agents.defaultLauncherMode
)
```

Keep the `requestInputFocus()` call, so the resulting `.onAppear` body is:

```swift
.onAppear {
    requestInputFocus()
}
```

This prevents an explicit `.terminal` or `.acp` request from being overwritten by the configured default when the dialog appears.

- [ ] **Step 5: Run overlay tests to verify they pass**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/AppStateOverlayTests test
```

Expected: AppState overlay tests pass.

- [ ] **Step 6: Commit**

```bash
rtk git add Alas/Sources/App/AppState.swift Alas/Sources/Agents/AgentLauncherDialog.swift AlasTests/AppStateOverlayTests.swift
rtk git commit -m "Scope agent launcher opening by mode"
```

## Task 3: Route Agent Terminal and Agent Chat Commands

**Files:**
- Modify: `Alas/Sources/App/AlasApp.swift`
- Modify: `Alas/Sources/App/RootView.swift`

- [ ] **Step 1: Add command-menu route for Agent Chat**

In `Alas/Sources/App/AlasApp.swift`, update the existing agent terminal command to pass Terminal mode:

```swift
Button("Launch Agent Terminal…") {
    NotificationCenter.default.post(name: .alasOpenAgentLauncher, object: AppConfig.LauncherMode.terminal)
}
.keyboardShortcut(state.shortcut(for: .launchAgentTerminal))
.disabled(state.projects.isEmpty)
```

Immediately after it, add:

```swift
Button("Launch Agent Chat…") {
    NotificationCenter.default.post(name: .alasOpenAgentLauncher, object: AppConfig.LauncherMode.acp)
}
.keyboardShortcut(state.shortcut(for: .launchAgentChat))
.disabled(state.projects.isEmpty)
```

- [ ] **Step 2: Route optional mode payloads in RootView**

In `Alas/Sources/App/RootView.swift`, replace the `.alasOpenAgentLauncher` handler with:

```swift
let p = o
    .onReceive(NotificationCenter.default.publisher(for: .alasOpenAgentLauncher)) { notification in
        guard selectedWorktree() != nil else { return }
        let mode = notification.object as? AppConfig.LauncherMode
        state.openAgentLauncherOverlay(mode: mode)
    }
```

Keep `static let alasOpenAgentLauncher = Notification.Name("AlasOpenAgentLauncher")` unchanged.

- [ ] **Step 3: Run shortcut and overlay tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ShortcutActionTests -only-testing:AlasTests/ShortcutResolverTests -only-testing:AlasTests/AppStateOverlayTests test
```

Expected: all selected tests pass.

- [ ] **Step 4: Commit**

```bash
rtk git add Alas/Sources/App/AlasApp.swift Alas/Sources/App/RootView.swift
rtk git commit -m "Route agent chat launcher command"
```

## Task 4: Replace Empty Worktree State With Command Rows

**Files:**
- Modify: `Alas/Sources/Center/EmptyTabView.swift`
- Modify: `Alas/Sources/Center/CenterPaneView.swift`
- Modify: `Alas/Sources/App/RootView.swift`

- [ ] **Step 1: Update EmptyTabView API and UI**

Replace the contents of `Alas/Sources/Center/EmptyTabView.swift` with:

```swift
import SwiftUI

struct EmptyTabView: View {
    let onNewTerminal: () -> Void
    let onNewAgentTerminal: () -> Void
    let onNewAgentChat: () -> Void
    let newTerminalShortcut: String?
    let newAgentTerminalShortcut: String?
    let newAgentChatShortcut: String?
    @Environment(\.theme) var theme

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                LinearGradient(colors: [theme.color("bg-3"), theme.color("bg-2")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                Image(systemName: "airplane")
                    .font(.system(size: 30))
                    .foregroundColor(theme.color("accent"))
            }
            VStack(spacing: 5) {
                Text("No tabs open")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                Text("Choose how to start working in this worktree.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
            }
            VStack(spacing: 8) {
                EmptyTabActionRow(
                    icon: "terminal",
                    title: "New Terminal",
                    subtitle: "Open a shell in this worktree",
                    shortcut: newTerminalShortcut,
                    action: onNewTerminal
                )
                EmptyTabActionRow(
                    icon: "sparkle",
                    title: "New Agent Terminal",
                    subtitle: "Pick an enabled agent to run in a terminal",
                    shortcut: newAgentTerminalShortcut,
                    action: onNewAgentTerminal
                )
                EmptyTabActionRow(
                    icon: "sparkle",
                    title: "New Agent Chat",
                    subtitle: "Pick an ACP-capable agent for chat",
                    shortcut: newAgentChatShortcut,
                    action: onNewAgentChat
                )
            }
            .frame(width: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("bg-1"))
    }
}

private struct EmptyTabActionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let shortcut: String?
    let action: () -> Void
    @Environment(\.theme) var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Icon(name: icon, size: 14,
                     color: hovering ? theme.color("fg") : theme.color("fg-muted"))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.color("fg"))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-faint"))
                }
                Spacer(minLength: 12)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.color("fg-muted"))
                        .padding(.horizontal, 6)
                        .frame(height: 21)
                        .background(theme.color("bg-2"))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(theme.color("line"), lineWidth: 0.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(hovering ? theme.color("bg-3") : theme.color("bg-2").opacity(0.55))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
```

- [ ] **Step 2: Wire CenterPaneView callbacks and shortcuts**

In `Alas/Sources/Center/CenterPaneView.swift`, replace:

```swift
EmptyTabView(onNewTerminal: openTerminal)
```

with:

```swift
EmptyTabView(
    onNewTerminal: openTerminal,
    onNewAgentTerminal: { state.openAgentLauncherOverlay(mode: .terminal) },
    onNewAgentChat: { state.openAgentLauncherOverlay(mode: .acp) },
    newTerminalShortcut: state.binding(for: .newTerminalTab)?.displayString,
    newAgentTerminalShortcut: state.binding(for: .launchAgentTerminal)?.displayString,
    newAgentChatShortcut: state.binding(for: .launchAgentChat)?.displayString
)
```

In the `.empty` branch of `RootView.centerContent()`, replace:

```swift
EmptyTabView(onNewTerminal: {})
```

with:

```swift
EmptyTabView(
    onNewTerminal: {},
    onNewAgentTerminal: {},
    onNewAgentChat: {},
    newTerminalShortcut: nil,
    newAgentTerminalShortcut: nil,
    newAgentChatShortcut: nil
)
```

- [ ] **Step 3: Compile to catch SwiftUI and icon issues**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
rtk git add Alas/Sources/Center/EmptyTabView.swift Alas/Sources/Center/CenterPaneView.swift Alas/Sources/App/RootView.swift
rtk git commit -m "Update worktree empty state entrypoints"
```

## Task 5: Full Verification

**Files:**
- No source edits unless verification finds a defect.

- [ ] **Step 1: Regenerate project**

Run:

```bash
rtk xcodegen
```

Expected: command succeeds. If `Alas.xcodeproj/project.pbxproj` changes, inspect the diff and include it in the final commit only if source membership changed.

- [ ] **Step 2: Build**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: build succeeds.

- [ ] **Step 3: Run tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: test suite passes.

- [ ] **Step 4: Manual UI check**

Launch the app from Xcode or the built product and select a worktree with no open center tabs. Verify:

- the empty state shows `New Terminal`, `New Agent Terminal`, and `New Agent Chat`;
- shortcut chips are right-aligned;
- `New Terminal` opens a shell immediately;
- `New Agent Terminal` opens the launcher in Terminal mode;
- `New Agent Chat` opens the launcher in Chat mode;
- switching modes inside the launcher still works.

- [ ] **Step 5: Inspect and commit verification fixes**

Run:

```bash
rtk git status --short
```

Expected: no uncommitted changes. If verification produced changes, inspect them with `rtk git diff`, stage the exact source files shown by `git status`, and commit with:

```bash
rtk git commit -m "Fix worktree empty state verification issues"
```
