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
            CommandGroup(after: .toolbar) {
                Button("Toggle Right Pane") {
                    NotificationCenter.default.post(name: .alasToggleRightPane, object: nil)
                }
                .keyboardShortcut(.return, modifiers: [.command, .option])
            }
        }
    }
}
