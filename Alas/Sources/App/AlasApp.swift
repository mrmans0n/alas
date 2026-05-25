import SwiftUI

@main
struct AlasApp: App {
    @State private var state = AppState()

    init() {
        BundledFontRegistrar.registerFonts()
    }

    var body: some Scene {
        Window("Alas", id: "main") {
            RootView(state: state)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 1320, height: 820)
        .commands {
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
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .alasOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
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
                Button("Find and Replace") {
                    NotificationCenter.default.post(name: .alasShowFindReplace, object: nil)
                }
                .keyboardShortcut(state.shortcut(for: .findAndReplace))
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
                Button("Launch Agent Terminal…") {
                    NotificationCenter.default.post(name: .alasOpenAgentLauncher, object: nil)
                }
                .keyboardShortcut(state.shortcut(for: .launchAgentTerminal))
                .disabled(state.projects.isEmpty)
                Button("Close Tab") {
                    NotificationCenter.default.post(name: .alasCloseTab, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)
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
                Button("Switch Repository…") {
                    NotificationCenter.default.post(name: .alasOpenRepoSelector, object: nil)
                }
                .keyboardShortcut(state.shortcut(for: .switchRepository))
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
}
