import AppKit
import SwiftUI

@main
struct AlasApp: App {
    @NSApplicationDelegateAdaptor(AlasApplicationDelegate.self) private var appDelegate
    @State private var state = AppState()

    private static var isRunningUnitTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || CommandLine.arguments.contains { $0.localizedCaseInsensitiveContains("xctest") }
            || NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
            || Bundle.allBundles.contains { bundle in
                bundle.bundlePath.hasSuffix(".xctest")
                    || bundle.bundleIdentifier?.hasPrefix("com.apple.dt.XCTest") == true
            }
    }

    init() {
        BundledFontRegistrar.registerFonts()
        // Refresh Gatekeeper cache when the user returns from System Settings
        // after granting permission to a blocked LSP binary.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                GatekeeperAssessor.shared.invalidateAll()
            }
        }
        if Self.isRunningUnitTests {
            NSApplication.shared.setActivationPolicy(.accessory)
            NSWindow.allowsAutomaticWindowTabbing = false
            NSAnimationContext.current.duration = 0
            NSAnimationContext.current.allowsImplicitAnimation = false
        }
    }

    var body: some Scene {
        Window("Alas", id: "main") {
            if Self.isRunningUnitTests {
                Color.clear
                    .frame(width: 1, height: 1)
                    .onAppear { Self.hideTestHostWindows() }
            } else {
                RootView(state: state)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 1320, height: 820)
        .commands {
            appCommands
        }

        Window("Settings", id: "settings") {
            SettingsWindow(state: state)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 880, height: 580)

        Window("Commit Prompt", id: "commit-prompt-editor") {
            CommitPromptEditorWindow(state: state)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 720, height: 560)

        Window("Review Request Prompt", id: "review-request-prompt-editor") {
            ReviewRequestPromptEditorWindow(state: state)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 720, height: 560)

        Window("Merge: Resolve All Prompt", id: "merge-bulk-prompt-editor") {
            MergeBulkResolvePromptEditorWindow(state: state)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 720, height: 560)

        Window("Merge: Single-File Prompt", id: "merge-single-prompt-editor") {
            MergeSingleResolvePromptEditorWindow(state: state)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 720, height: 560)
    }

    @MainActor
    private static func hideTestHostWindows() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            NSApplication.shared.windows.forEach { window in
                window.disableSnapshotRestoration()
                window.orderOut(nil)
            }
        }
    }

    @CommandsBuilder
    private var appCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New File…") {
                NotificationCenter.default.post(name: .alasNewFile, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                NotificationCenter.default.post(name: .alasSaveActiveTab, object: nil)
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!state.hasActiveEditorTab)
            Button("Save As…") {
                NotificationCenter.default.post(name: .alasSaveActiveTabAs, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!state.hasActiveEditorTab)
            Button("Save All") {
                NotificationCenter.default.post(name: .alasSaveAllTabs, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(!state.hasAnyDirtyEditorTab)
            Divider()
            Button("Revert") {
                NotificationCenter.default.post(name: .alasRevertActiveTab, object: nil)
            }
            .disabled(!state.hasActiveEditorTab)
            Divider()
            Button("Rename File…") {
                NotificationCenter.default.post(name: .alasRenameActiveFile, object: nil)
            }
            .disabled(!state.hasActiveEditorTab)
        }
        Group {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .alasOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    state.updates.checkManually()
                }
                Divider()
                Button(AppQuitAction.terminateSessionsTitle) {
                    AppQuitAction.quitAfterTerminatingSessions(
                        terminateSessions: { state.terminateAllTerminalSessions() }
                    )
                }
                .keyboardShortcut(
                    AppQuitAction.terminateSessionsShortcutKey,
                    modifiers: AppQuitAction.terminateSessionsShortcutModifiers
                )
            }
        }
        CommandMenu("Spaces") {
            Button("Select Space 1") {
                _ = state.switchToSpace(atOneBasedIndex: 1)
            }
            .keyboardShortcut("1", modifiers: [.command, .option])
            .disabled(state.spacesManager.spaces.count < 1)
            Button("Select Space 2") {
                _ = state.switchToSpace(atOneBasedIndex: 2)
            }
            .keyboardShortcut("2", modifiers: [.command, .option])
            .disabled(state.spacesManager.spaces.count < 2)
            Button("Select Space 3") {
                _ = state.switchToSpace(atOneBasedIndex: 3)
            }
            .keyboardShortcut("3", modifiers: [.command, .option])
            .disabled(state.spacesManager.spaces.count < 3)
            Button("Select Space 4") {
                _ = state.switchToSpace(atOneBasedIndex: 4)
            }
            .keyboardShortcut("4", modifiers: [.command, .option])
            .disabled(state.spacesManager.spaces.count < 4)
            Button("Select Space 5") {
                _ = state.switchToSpace(atOneBasedIndex: 5)
            }
            .keyboardShortcut("5", modifiers: [.command, .option])
            .disabled(state.spacesManager.spaces.count < 5)
            Button("Select Space 6") {
                _ = state.switchToSpace(atOneBasedIndex: 6)
            }
            .keyboardShortcut("6", modifiers: [.command, .option])
            .disabled(state.spacesManager.spaces.count < 6)
            Button("Select Space 7") {
                _ = state.switchToSpace(atOneBasedIndex: 7)
            }
            .keyboardShortcut("7", modifiers: [.command, .option])
            .disabled(state.spacesManager.spaces.count < 7)
            Button("Select Space 8") {
                _ = state.switchToSpace(atOneBasedIndex: 8)
            }
            .keyboardShortcut("8", modifiers: [.command, .option])
            .disabled(state.spacesManager.spaces.count < 8)
            Button("Select Space 9") {
                _ = state.switchToSpace(atOneBasedIndex: 9)
            }
            .keyboardShortcut("9", modifiers: [.command, .option])
            .disabled(state.spacesManager.spaces.count < 9)
            Divider()
            Button("Edit Spaces…") {
                state.pendingSettingsSection = .spaces
                NotificationCenter.default.post(name: .alasOpenSettings, object: SettingsSection.spaces)
            }
        }
        CommandGroup(after: .pasteboard) {
            Button("Search Files…") {
                NotificationCenter.default.post(name: .alasOpenSearch, object: nil)
            }
            .keyboardShortcut(state.shortcut(for: .searchFiles))
            Divider()
            Button("Split Selection into Lines") {
                NSApp.sendAction(#selector(CodeTextView.splitSelectionIntoLines(_:)), to: nil, from: nil)
            }
            .keyboardShortcut(state.shortcut(for: .splitSelectionIntoLines))
            .disabled(!state.hasActiveCodeEditorTab)
            Divider()
            Button("Find") {
                NotificationCenter.default.post(name: .alasShowFindReplace, object: EditorFindRequest.showFind)
            }
            .keyboardShortcut(state.shortcut(for: .findAndReplace))
            .disabled(!state.hasActiveCodeEditorTab)
            Button("Find and Replace") {
                NotificationCenter.default.post(name: .alasShowFindReplace, object: EditorFindRequest.showReplace)
            }
            .keyboardShortcut(state.shortcut(for: .replaceInEditor))
            .disabled(!state.hasActiveCodeEditorTab)
            Button("Find Next") {
                NotificationCenter.default.post(name: .alasShowFindReplace, object: EditorFindRequest.findNext)
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(!state.hasActiveCodeEditorTab)
            Button("Find Previous") {
                NotificationCenter.default.post(name: .alasShowFindReplace, object: EditorFindRequest.findPrevious)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(!state.hasActiveCodeEditorTab)
        }
        CommandGroup(after: .toolbar) {
            Button("Toggle Sidebar") {
                NotificationCenter.default.post(name: .alasToggleSidebar, object: nil)
            }
            .keyboardShortcut(state.shortcut(for: .toggleSidebar))
            Button("Toggle Right Sidebar") {
                NotificationCenter.default.post(name: .alasToggleRightPane, object: nil)
            }
            .keyboardShortcut(state.shortcut(for: .toggleRightPane))
            Button("New Terminal Tab") {
                NotificationCenter.default.post(name: .alasNewTerminalTab, object: nil)
            }
            .keyboardShortcut(state.shortcut(for: .newTerminalTab))
            Button("Launch Agent…") {
                NotificationCenter.default.post(name: .alasOpenAgentLauncher,
                                                object: AgentLauncherRequest.picker)
            }
            .keyboardShortcut(state.shortcut(for: .launchAgent))
            .disabled(state.projects.isEmpty)
            Button("Launch Agent in Chat…") {
                NotificationCenter.default.post(name: .alasOpenAgentLauncher,
                                                object: AgentLauncherRequest.locked(.acp))
            }
            .keyboardShortcut(state.shortcut(for: .launchAgentInChat))
            .disabled(state.projects.isEmpty)
            Button("Launch Agent in Terminal…") {
                NotificationCenter.default.post(name: .alasOpenAgentLauncher,
                                                object: AgentLauncherRequest.locked(.terminal))
            }
            .keyboardShortcut(state.shortcut(for: .launchAgentInTerminal))
            .disabled(state.projects.isEmpty)
            Button("Close Tab") {
                NotificationCenter.default.post(name: .alasCloseTab, object: nil)
            }
            .keyboardShortcut("w", modifiers: .command)
            Button("Reopen Closed Tab") {
                NotificationCenter.default.post(name: .alasReopenClosedTab, object: nil)
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(!state.canReopenClosedTab)
            Divider()
            Button("Select Previous Tab") {
                NotificationCenter.default.post(
                    name: .alasActivateAdjacentTab,
                    object: CenterTabNavigationDirection.previous
                )
            }
            .keyboardShortcut(state.shortcut(for: .selectPreviousTab))
            Button("Select Next Tab") {
                NotificationCenter.default.post(
                    name: .alasActivateAdjacentTab,
                    object: CenterTabNavigationDirection.next
                )
            }
            .keyboardShortcut(state.shortcut(for: .selectNextTab))
            Divider()
            Button("Select Tab 1") {
                NotificationCenter.default.post(name: .alasActivateTabByNumber, object: 1)
            }
            .keyboardShortcut("1", modifiers: .command)
            Button("Select Tab 2") {
                NotificationCenter.default.post(name: .alasActivateTabByNumber, object: 2)
            }
            .keyboardShortcut("2", modifiers: .command)
            Button("Select Tab 3") {
                NotificationCenter.default.post(name: .alasActivateTabByNumber, object: 3)
            }
            .keyboardShortcut("3", modifiers: .command)
            Button("Select Tab 4") {
                NotificationCenter.default.post(name: .alasActivateTabByNumber, object: 4)
            }
            .keyboardShortcut("4", modifiers: .command)
            Button("Select Tab 5") {
                NotificationCenter.default.post(name: .alasActivateTabByNumber, object: 5)
            }
            .keyboardShortcut("5", modifiers: .command)
            Button("Select Tab 6") {
                NotificationCenter.default.post(name: .alasActivateTabByNumber, object: 6)
            }
            .keyboardShortcut("6", modifiers: .command)
            Button("Select Tab 7") {
                NotificationCenter.default.post(name: .alasActivateTabByNumber, object: 7)
            }
            .keyboardShortcut("7", modifiers: .command)
            Button("Select Tab 8") {
                NotificationCenter.default.post(name: .alasActivateTabByNumber, object: 8)
            }
            .keyboardShortcut("8", modifiers: .command)
            Button("Select Tab 9") {
                NotificationCenter.default.post(name: .alasActivateTabByNumber, object: 9)
            }
            .keyboardShortcut("9", modifiers: .command)
        }
        CommandMenu("Projects") {
            Button("Create Project…") {
                NotificationCenter.default.post(name: .alasCreateProject, object: nil)
            }
            .keyboardShortcut(state.shortcut(for: .createProject))
            Button("New Worktree…") {
                NotificationCenter.default.post(name: .alasNewWorktree, object: nil)
            }
            .keyboardShortcut(state.shortcut(for: .newWorktree))
            .disabled(state.projects.isEmpty)
            Button("Focus Main Worktree") {
                NotificationCenter.default.post(name: .alasFocusMainWorktree, object: nil)
            }
            .keyboardShortcut(state.shortcut(for: .focusMainWorktree))
            .disabled(!state.canFocusMainWorktreeForCurrentProject)
            Button("Switch Repository…") {
                NotificationCenter.default.post(name: .alasOpenRepoSelector, object: nil)
            }
            .keyboardShortcut(state.shortcut(for: .switchRepository))
            Button("Review Worktree…") {
                NotificationCenter.default.post(name: .alasOpenReviewPalette, object: nil)
            }
            .keyboardShortcut(state.shortcut(for: .openReviewPalette))
            .disabled(state.projects.isEmpty)
            Button("Run Script…") {
                NotificationCenter.default.post(name: .alasOpenRunScriptPalette, object: nil)
            }
            .keyboardShortcut(state.shortcut(for: .runScript))
            .disabled(state.projects.isEmpty)
            Divider()
            Button("Refresh Worktrees") {
                NotificationCenter.default.post(name: .alasRefreshWorktrees, object: nil)
            }
            .disabled(state.projects.isEmpty)
        }
        CommandMenu("Terminal") {
            Button("Split Right") {
                NotificationCenter.default.post(name: .alasSplitRight, object: nil)
            }
            .keyboardShortcut(state.shortcut(for: .splitTerminalRight))
            Button("Split Down") {
                NotificationCenter.default.post(name: .alasSplitDown, object: nil)
            }
            .keyboardShortcut(state.shortcut(for: .splitTerminalDown))
            Button("Close Pane") {
                NotificationCenter.default.post(name: .alasCloseTab, object: nil)
            }
            Divider()
            Button("Focus Pane Left") {
                NotificationCenter.default.post(name: .alasFocusPaneLeft, object: nil)
            }
            .keyboardShortcut(state.shortcut(for: .focusPaneLeft))
            Button("Focus Pane Right") {
                NotificationCenter.default.post(name: .alasFocusPaneRight, object: nil)
            }
            .keyboardShortcut(state.shortcut(for: .focusPaneRight))
            Button("Focus Pane Up") {
                NotificationCenter.default.post(name: .alasFocusPaneUp, object: nil)
            }
            .keyboardShortcut(state.shortcut(for: .focusPaneUp))
            Button("Focus Pane Down") {
                NotificationCenter.default.post(name: .alasFocusPaneDown, object: nil)
            }
            .keyboardShortcut(state.shortcut(for: .focusPaneDown))
            Divider()
            Button("Resize Pane Left") {
                NotificationCenter.default.post(name: .alasResizePaneLeft, object: nil)
            }
            .keyboardShortcut(state.shortcut(for: .resizePaneLeft))
            Button("Resize Pane Right") {
                NotificationCenter.default.post(name: .alasResizePaneRight, object: nil)
            }
            .keyboardShortcut(state.shortcut(for: .resizePaneRight))
            Button("Resize Pane Up") {
                NotificationCenter.default.post(name: .alasResizePaneUp, object: nil)
            }
            .keyboardShortcut(state.shortcut(for: .resizePaneUp))
            Button("Resize Pane Down") {
                NotificationCenter.default.post(name: .alasResizePaneDown, object: nil)
            }
            .keyboardShortcut(state.shortcut(for: .resizePaneDown))
            Divider()
            Button("Terminate All Terminal Sessions") {
                NotificationCenter.default.post(name: .alasTerminateAllTerminals, object: nil)
            }
        }
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Increase Font Size") {
                NSApp.sendAction(#selector(FontSizeResponder.increaseFontSize(_:)), to: nil, from: nil)
            }
            .keyboardShortcut(state.shortcut(for: .increaseFontSize))
            Button("Decrease Font Size") {
                NSApp.sendAction(#selector(FontSizeResponder.decreaseFontSize(_:)), to: nil, from: nil)
            }
            .keyboardShortcut(state.shortcut(for: .decreaseFontSize))
            Button("Reset Font Size") {
                NSApp.sendAction(#selector(FontSizeResponder.resetFontSize(_:)), to: nil, from: nil)
            }
            .keyboardShortcut(state.shortcut(for: .resetFontSize))
        }
        #if DEBUG
        CommandMenu("Debug") {
            Button("Memory Report…") {
                openMemoryReport(state: state)
            }
            .keyboardShortcut("M", modifiers: [.command, .shift, .control])
        }
        #endif
    }
}
