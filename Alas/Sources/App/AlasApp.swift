import SwiftUI

@main
struct AlasApp: App {
    @State private var state = AppState()

    var body: some Scene {
        Window("Alas", id: "main") {
            RootView(state: state)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 1320, height: 820)
        .commands {
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
