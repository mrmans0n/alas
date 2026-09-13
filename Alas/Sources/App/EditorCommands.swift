import AppKit
import SwiftUI

struct EditorCommands: Commands {
    var body: some Commands {
        CommandMenu("Code") {
            Button("Go to Definition") { send(.definition) }
                .keyboardShortcut(functionKey(12))
            Button("Go to Type Definition") { send(.typeDefinition) }
            Button("Go to Implementation") { send(.implementation) }
            Button("Find References") { send(.references) }
                .keyboardShortcut(functionKey(12), modifiers: .shift)
            Divider()
            Button("Rename Symbol") { send(.rename) }
                .keyboardShortcut(functionKey(2))
            Button("Code Actions") { send(.codeActions) }
                .keyboardShortcut(.return, modifiers: .option)
            Divider()
            Button("Format Selection") { send(.formatSelection) }
            Button("Format Document") { send(.formatDocument) }
            Divider()
            Button("Show Hover") { send(.hover) }
            Button("Trigger Completion") {
                NSApp.sendAction(#selector(NSResponder.complete(_:)), to: nil, from: nil)
            }
            .keyboardShortcut(" ", modifiers: .control)
            Divider()
            Button("Back") { send(.back) }
            Button("Forward") { send(.forward) }
            Button("Next Problem") { send(.nextProblem) }
            Button("Previous Problem") { send(.previousProblem) }
            Button("Toggle Inlay Hints") { send(.toggleInlayHints) }
        }
    }

    private func send(_ command: EditorCommandID) {
        NSApp.sendAction(CodeTextView.selector(for: command), to: nil, from: nil)
    }

    private func functionKey(_ number: UInt32) -> KeyEquivalent {
        KeyEquivalent(Character(UnicodeScalar(0xF703 + number)!))
    }
}
