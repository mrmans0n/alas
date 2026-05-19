import Foundation

enum ShortcutGroup: String, CaseIterable, Sendable {
    case global, codeEditor, terminal
    var label: String {
        switch self {
        case .global:     return "Global"
        case .codeEditor: return "Code editor"
        case .terminal:   return "Terminal"
        }
    }
}

enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    // Global
    case searchFiles, switchRepository, findAndReplace, toggleRightPane,
         createProject, newWorktree, newTerminalTab,
         increaseFontSize, decreaseFontSize, resetFontSize
    // Code editor
    case splitSelectionIntoLines, toggleMarkdownPreview, commitInComposer
    // Terminal
    case splitTerminalRight, splitTerminalDown,
         focusPaneLeft, focusPaneRight, focusPaneUp, focusPaneDown,
         resizePaneLeft, resizePaneRight, resizePaneUp, resizePaneDown

    var group: ShortcutGroup {
        switch self {
        case .searchFiles, .switchRepository, .findAndReplace, .toggleRightPane,
             .createProject, .newWorktree, .newTerminalTab,
             .increaseFontSize, .decreaseFontSize, .resetFontSize:
            return .global
        case .splitSelectionIntoLines, .toggleMarkdownPreview, .commitInComposer:
            return .codeEditor
        case .splitTerminalRight, .splitTerminalDown,
             .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
             .resizePaneLeft, .resizePaneRight, .resizePaneUp, .resizePaneDown:
            return .terminal
        }
    }

    var label: String {
        switch self {
        case .searchFiles:              return "Search Files"
        case .switchRepository:         return "Switch Repository"
        case .findAndReplace:           return "Find and Replace"
        case .toggleRightPane:          return "Toggle Right Pane"
        case .createProject:            return "Create Project"
        case .newWorktree:              return "New Worktree"
        case .newTerminalTab:           return "New Terminal Tab"
        case .increaseFontSize:         return "Increase Font Size"
        case .decreaseFontSize:         return "Decrease Font Size"
        case .resetFontSize:            return "Reset Font Size"
        case .splitSelectionIntoLines:  return "Split Selection into Lines"
        case .toggleMarkdownPreview:    return "Toggle Markdown Preview"
        case .commitInComposer:         return "Commit (in composer)"
        case .splitTerminalRight:       return "Split Right"
        case .splitTerminalDown:        return "Split Down"
        case .focusPaneLeft:            return "Focus Pane Left"
        case .focusPaneRight:           return "Focus Pane Right"
        case .focusPaneUp:              return "Focus Pane Up"
        case .focusPaneDown:            return "Focus Pane Down"
        case .resizePaneLeft:           return "Resize Pane Left"
        case .resizePaneRight:          return "Resize Pane Right"
        case .resizePaneUp:             return "Resize Pane Up"
        case .resizePaneDown:           return "Resize Pane Down"
        }
    }

    var description: String? {
        switch self {
        case .searchFiles:        return "Open the file search"
        case .switchRepository:   return "Open the repository picker"
        case .commitInComposer:   return "In the commit composer"
        default:                  return nil
        }
    }

    var defaultBinding: ShortcutBinding {
        switch self {
        case .searchFiles:              return .init(key: "p",          modifiers: [.command])
        case .switchRepository:         return .init(key: "k",          modifiers: [.command])
        case .findAndReplace:           return .init(key: "f",          modifiers: [.command, .option])
        case .toggleRightPane:          return .init(key: "return",     modifiers: [.command, .option])
        case .createProject:            return .init(key: "n",          modifiers: [.command, .shift])
        case .newWorktree:              return .init(key: "n",          modifiers: [.command, .option])
        case .newTerminalTab:           return .init(key: "t",          modifiers: [.command])
        case .increaseFontSize:         return .init(key: "=",          modifiers: [.command])
        case .decreaseFontSize:         return .init(key: "-",          modifiers: [.command])
        case .resetFontSize:            return .init(key: "0",          modifiers: [.command])
        case .splitSelectionIntoLines:  return .init(key: "l",          modifiers: [.command, .shift])
        case .toggleMarkdownPreview:    return .init(key: "m",          modifiers: [.command, .shift])
        case .commitInComposer:         return .init(key: "return",     modifiers: [.command])
        case .splitTerminalRight:       return .init(key: "d",          modifiers: [.command])
        case .splitTerminalDown:        return .init(key: "d",          modifiers: [.command, .shift])
        case .focusPaneLeft:            return .init(key: "leftArrow",  modifiers: [.command, .option])
        case .focusPaneRight:           return .init(key: "rightArrow", modifiers: [.command, .option])
        case .focusPaneUp:              return .init(key: "upArrow",    modifiers: [.command, .option])
        case .focusPaneDown:            return .init(key: "downArrow",  modifiers: [.command, .option])
        case .resizePaneLeft:           return .init(key: "leftArrow",  modifiers: [.command, .control])
        case .resizePaneRight:          return .init(key: "rightArrow", modifiers: [.command, .control])
        case .resizePaneUp:             return .init(key: "upArrow",    modifiers: [.command, .control])
        case .resizePaneDown:           return .init(key: "downArrow",  modifiers: [.command, .control])
        }
    }

    /// Bindings owned by non-rebindable actions (macOS standards + tab switchers
    /// + New File). Rejected by the recorder when the user tries to assign one
    /// of these to a rebindable action.
    static let reservedBindings: [ShortcutBinding] = [
        .init(key: "q", modifiers: [.command]),
        .init(key: "w", modifiers: [.command]),
        .init(key: "s", modifiers: [.command]),
        .init(key: "s", modifiers: [.command, .shift]),
        .init(key: "s", modifiers: [.command, .option]),
        .init(key: ",", modifiers: [.command]),
        .init(key: "n", modifiers: [.command]),
        .init(key: "1", modifiers: [.command]),
        .init(key: "2", modifiers: [.command]),
        .init(key: "3", modifiers: [.command]),
        .init(key: "4", modifiers: [.command]),
        .init(key: "5", modifiers: [.command]),
        .init(key: "6", modifiers: [.command]),
        .init(key: "7", modifiers: [.command]),
        .init(key: "8", modifiers: [.command]),
        .init(key: "9", modifiers: [.command]),
    ]
}
