import Foundation

enum ShortcutGroup: String, CaseIterable, Sendable {
    case global, codeEditor, terminal, commit
    var label: String {
        switch self {
        case .global:     return "Global"
        case .codeEditor: return "Code editor"
        case .terminal:   return "Terminal"
        case .commit:     return "Commit"
        }
    }
}

enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    // Global
    case searchFiles, switchRepository, findAndReplace, replaceInEditor, toggleSidebar, toggleRightPane,
         createProject, newWorktree, focusMainWorktree, newTerminalTab, launchAgentTerminal, launchAgentChat,
         openReviewPalette, runScript, selectPreviousTab, selectNextTab,
         increaseFontSize, decreaseFontSize, resetFontSize
    // Code editor
    case splitSelectionIntoLines, toggleMarkdownPreview, commitInComposer
    // Terminal
    case splitTerminalRight, splitTerminalDown,
         focusPaneLeft, focusPaneRight, focusPaneUp, focusPaneDown,
         resizePaneLeft, resizePaneRight, resizePaneUp, resizePaneDown

    var group: ShortcutGroup {
        switch self {
        case .searchFiles, .switchRepository, .findAndReplace, .replaceInEditor, .toggleSidebar, .toggleRightPane,
             .createProject, .newWorktree, .focusMainWorktree, .newTerminalTab, .launchAgentTerminal, .launchAgentChat,
             .openReviewPalette, .runScript, .selectPreviousTab, .selectNextTab,
             .increaseFontSize, .decreaseFontSize, .resetFontSize:
            return .global
        case .splitSelectionIntoLines, .toggleMarkdownPreview:
            return .codeEditor
        case .commitInComposer:
            return .commit
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
        case .findAndReplace:           return "Find"
        case .replaceInEditor:          return "Find and Replace"
        case .toggleSidebar:            return "Toggle Sidebar"
        case .toggleRightPane:          return "Toggle Right Sidebar"
        case .createProject:            return "Create Project"
        case .newWorktree:              return "New Worktree"
        case .focusMainWorktree:        return "Focus Main Worktree"
        case .newTerminalTab:           return "New Terminal Tab"
        case .launchAgentTerminal:      return "Launch Agent Terminal"
        case .launchAgentChat:          return "Launch Agent Chat"
        case .openReviewPalette:        return "Review Worktree"
        case .runScript:                return "Run Script"
        case .selectPreviousTab:        return "Select Previous Tab"
        case .selectNextTab:            return "Select Next Tab"
        case .increaseFontSize:         return "Increase Font Size"
        case .decreaseFontSize:         return "Decrease Font Size"
        case .resetFontSize:            return "Reset Font Size"
        case .splitSelectionIntoLines:  return "Split Selection into Lines"
        case .toggleMarkdownPreview:    return "Toggle Markdown Preview"
        case .commitInComposer:         return "Commit draft"
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
        case .launchAgentTerminal: return "Open the agent launcher in Terminal mode"
        case .launchAgentChat:     return "Open the agent launcher in Chat mode"
        case .openReviewPalette:   return "Open the review target palette"
        case .runScript:           return "Open the run script palette"
        case .commitInComposer:   return "In the draft commit tab"
        default:                  return nil
        }
    }

    /// Whether the action should be reserved away from a focused terminal
    /// surface. `false` for code-editor- or composer-scoped actions: those
    /// have no responder when the terminal is focused, so reserving them
    /// would swallow the keystroke instead of letting the shell receive it.
    var appliesInTerminal: Bool {
        switch self {
        case .splitSelectionIntoLines, .toggleMarkdownPreview,
             .commitInComposer, .findAndReplace, .replaceInEditor:
            return false
        default:
            return true
        }
    }

    var defaultBinding: ShortcutBinding {
        switch self {
        case .searchFiles:              return .init(key: "p",          modifiers: [.command])
        case .switchRepository:         return .init(key: "k",          modifiers: [.command])
        case .findAndReplace:           return .init(key: "f",          modifiers: [.command])
        case .replaceInEditor:          return .init(key: "f",          modifiers: [.command, .option])
        case .toggleSidebar:            return .init(key: "b",          modifiers: [.command])
        case .toggleRightPane:          return .init(key: "b",          modifiers: [.command, .option])
        case .createProject:            return .init(key: "n",          modifiers: [.command, .shift])
        case .newWorktree:              return .init(key: "n",          modifiers: [.command, .option])
        // Cmd+Shift+M is Toggle Markdown Preview; Cmd+Option+M is macOS Minimize All.
        case .focusMainWorktree:        return .init(key: "m",          modifiers: [.command, .control])
        case .newTerminalTab:           return .init(key: "t",          modifiers: [.command])
        case .launchAgentTerminal:      return .init(key: "t",          modifiers: [.command, .option])
        case .launchAgentChat:          return .init(key: "t",          modifiers: [.command, .option, .shift])
        case .openReviewPalette:        return .init(key: "r",          modifiers: [.command, .shift])
        case .runScript:                return .init(key: "r",          modifiers: [.command])
        case .selectPreviousTab:        return .init(key: "tab",        modifiers: [.control, .shift])
        case .selectNextTab:            return .init(key: "tab",        modifiers: [.control])
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
        .init(key: "t", modifiers: [.command, .shift]),
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
