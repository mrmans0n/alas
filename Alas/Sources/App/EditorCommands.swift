import AppKit
import SwiftUI

struct EditorCommands: Commands {
    let availability: EditorCommandAvailability

    var body: some Commands {
        CommandMenu("Code") {
            Button("Go to Definition") { send(.definition) }
                .keyboardShortcut(functionKey(12))
                .disabled(!availability.isAvailable(.definition))
            Button("Go to Type Definition") { send(.typeDefinition) }
                .disabled(!availability.isAvailable(.typeDefinition))
            Button("Go to Implementation") { send(.implementation) }
                .disabled(!availability.isAvailable(.implementation))
            Button("Find References") { send(.references) }
                .keyboardShortcut(functionKey(12), modifiers: .shift)
                .disabled(!availability.isAvailable(.references))
            Divider()
            Button("Rename Symbol") { send(.rename) }
                .keyboardShortcut(functionKey(2))
                .disabled(!availability.isAvailable(.rename))
            Button("Code Actions") { send(.codeActions) }
                .keyboardShortcut(.return, modifiers: .option)
                .disabled(!availability.isAvailable(.codeActions))
            Divider()
            Button("Format Selection") { send(.formatSelection) }
                .disabled(!availability.isAvailable(.formatSelection))
            Button("Format Document") { send(.formatDocument) }
                .disabled(!availability.isAvailable(.formatDocument))
            Divider()
            Button("Show Hover") { send(.hover) }
                .disabled(!availability.isAvailable(.hover))
            Button("Trigger Completion") {
                NSApp.sendAction(#selector(NSResponder.complete(_:)), to: nil, from: nil)
            }
            .keyboardShortcut(" ", modifiers: .control)
            .disabled(!availability.activeEditor)
            Divider()
            Button("Back") { send(.back) }
                .disabled(!availability.isAvailable(.back))
            Button("Forward") { send(.forward) }
                .disabled(!availability.isAvailable(.forward))
            Button("Next Problem") { send(.nextProblem) }
                .disabled(!availability.isAvailable(.nextProblem))
            Button("Previous Problem") { send(.previousProblem) }
                .disabled(!availability.isAvailable(.previousProblem))
            Button("Toggle Inlay Hints") { send(.toggleInlayHints) }
                .disabled(!availability.isAvailable(.toggleInlayHints))
        }
    }

    private func send(_ command: EditorCommandID) {
        NSApp.sendAction(CodeTextView.selector(for: command), to: nil, from: nil)
    }

    private func functionKey(_ number: UInt32) -> KeyEquivalent {
        KeyEquivalent(Character(UnicodeScalar(0xF703 + number)!))
    }
}
