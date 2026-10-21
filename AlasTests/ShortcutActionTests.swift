import Testing
@testable import Alas

struct ShortcutActionTests {
    @Test func allCasesHaveDefaultBinding() {
        for action in ShortcutAction.allCases {
            _ = action.defaultBinding
            #expect(!action.label.isEmpty)
        }
    }

    @Test func noDuplicateDefaultBindings() {
        var seen: [ShortcutBinding: ShortcutAction] = [:]
        for action in ShortcutAction.allCases {
            let b = action.defaultBinding
            #expect(seen[b] == nil, "Duplicate default \(b.displayString): \(action) and \(seen[b]!)")
            seen[b] = action
        }
    }

    @Test func editorFindActionsAreGlobalAndNotReservedInTerminal() {
        #expect(ShortcutAction.findAndReplace.rawValue == "findAndReplace")
        #expect(ShortcutAction.findAndReplace.label == "Find")
        #expect(ShortcutAction.findAndReplace.group == .global)
        #expect(!ShortcutAction.findAndReplace.appliesInTerminal)

        #expect(ShortcutAction.replaceInEditor.label == "Find and Replace")
        #expect(ShortcutAction.replaceInEditor.group == .global)
        #expect(!ShortcutAction.replaceInEditor.appliesInTerminal)
    }

    @Test func reservedBindingsContainsStandards() {
        let reserved = ShortcutAction.reservedBindings
        #expect(reserved.contains(ShortcutBinding(key: "q", modifiers: [.command])))
        #expect(reserved.contains(ShortcutBinding(key: "w", modifiers: [.command])))
        #expect(reserved.contains(ShortcutBinding(key: "s", modifiers: [.command])))
        #expect(reserved.contains(ShortcutBinding(key: ",", modifiers: [.command])))
        #expect(reserved.contains(ShortcutBinding(key: "n", modifiers: [.command])))
        for n in 1...9 {
            #expect(reserved.contains(ShortcutBinding(key: String(n), modifiers: [.command])))
        }
    }

    @Test func runScriptDefaultsToCmdR() {
        #expect(ShortcutAction.runScript.defaultBinding == .init(key: "r", modifiers: [.command]))
        #expect(ShortcutAction.runScript.group == .global)
        #expect(ShortcutAction.runScript.appliesInTerminal)
    }

    @Test func replaceInEditorDefaultsToCmdOptF() {
        #expect(ShortcutAction.replaceInEditor.defaultBinding == .init(key: "f", modifiers: [.command, .option]))
        #expect(!ShortcutAction.replaceInEditor.appliesInTerminal)
    }
}
