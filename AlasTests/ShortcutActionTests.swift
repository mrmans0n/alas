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

    @Test func defaultsMatchAlasAppValues() {
        let expected: [(ShortcutAction, String, [ShortcutBinding.Modifier])] = [
            (.searchFiles,          "p",          [.command]),
            (.switchRepository,     "k",          [.command]),
            (.findAndReplace,       "f",          [.command, .option]),
            (.toggleRightPane,      "return",     [.command, .option]),
            (.createProject,        "n",          [.command, .shift]),
            (.newWorktree,          "n",          [.command, .option]),
            (.newTerminalTab,       "t",          [.command]),
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

    @Test func groupAssignmentsMatchSpec() {
        let global: Set<ShortcutAction> = [
            .searchFiles, .switchRepository, .findAndReplace, .toggleRightPane,
            .createProject, .newWorktree, .newTerminalTab,
            .increaseFontSize, .decreaseFontSize, .resetFontSize,
        ]
        let codeEditor: Set<ShortcutAction> = [
            .splitSelectionIntoLines, .toggleMarkdownPreview, .commitInComposer,
        ]
        let terminal: Set<ShortcutAction> = [
            .splitTerminalRight, .splitTerminalDown,
            .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
            .resizePaneLeft, .resizePaneRight, .resizePaneUp, .resizePaneDown,
        ]
        for a in ShortcutAction.allCases {
            switch a.group {
            case .global:     #expect(global.contains(a), "\(a) miscategorized")
            case .codeEditor: #expect(codeEditor.contains(a), "\(a) miscategorized")
            case .terminal:   #expect(terminal.contains(a), "\(a) miscategorized")
            }
        }
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
}
