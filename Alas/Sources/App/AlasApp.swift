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
                Button("Save As…") {
                    NotificationCenter.default.post(name: .alasSaveActiveTabAs, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Save All") {
                    NotificationCenter.default.post(name: .alasSaveAllTabs, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                Divider()
                Button("Revert") {
                    NotificationCenter.default.post(name: .alasRevertActiveTab, object: nil)
                }
                Divider()
                Button("Rename File…") {
                    NotificationCenter.default.post(name: .alasRenameActiveFile, object: nil)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .alasOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Toggle Right Pane") {
                    NotificationCenter.default.post(name: .alasToggleRightPane, object: nil)
                }
                .keyboardShortcut(.return, modifiers: [.command, .option])
                Button("Search Files…") {
                    NotificationCenter.default.post(name: .alasOpenSearch, object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)
                Button("New Worktree…") {
                    NotificationCenter.default.post(name: .alasNewWorktree, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                Button("New Terminal Tab") {
                    NotificationCenter.default.post(name: .alasNewTerminalTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
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
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Worktree…") {
                    NotificationCenter.default.post(name: .alasNewWorktree, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
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
                .keyboardShortcut("d", modifiers: .command)
                Button("Split Down") {
                    NotificationCenter.default.post(name: .alasSplitDown, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Close Pane") {
                    NotificationCenter.default.post(name: .alasCloseTab, object: nil)
                }
                Divider()
                Button("Focus Pane Left") {
                    NotificationCenter.default.post(name: .alasFocusPaneLeft, object: nil)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Focus Pane Right") {
                    NotificationCenter.default.post(name: .alasFocusPaneRight, object: nil)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Focus Pane Up") {
                    NotificationCenter.default.post(name: .alasFocusPaneUp, object: nil)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Focus Pane Down") {
                    NotificationCenter.default.post(name: .alasFocusPaneDown, object: nil)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Divider()
                Button("Resize Pane Left") {
                    NotificationCenter.default.post(name: .alasResizePaneLeft, object: nil)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                Button("Resize Pane Right") {
                    NotificationCenter.default.post(name: .alasResizePaneRight, object: nil)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                Button("Resize Pane Up") {
                    NotificationCenter.default.post(name: .alasResizePaneUp, object: nil)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                Button("Resize Pane Down") {
                    NotificationCenter.default.post(name: .alasResizePaneDown, object: nil)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
            }
            CommandGroup(after: .toolbar) {
                Divider()
                Button("Increase Font Size") {
                    NSApp.sendAction(#selector(FontSizeResponder.increaseFontSize(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("=", modifiers: .command)
                Button("Decrease Font Size") {
                    NSApp.sendAction(#selector(FontSizeResponder.decreaseFontSize(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("-", modifiers: .command)
                Button("Reset Font Size") {
                    NSApp.sendAction(#selector(FontSizeResponder.resetFontSize(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        Window("Settings", id: "settings") {
            SettingsWindow(state: state)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 880, height: 580)
    }
}
