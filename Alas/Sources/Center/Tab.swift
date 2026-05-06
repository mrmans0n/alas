import Foundation

typealias TabID = String

enum Tab: Codable, Equatable, Identifiable {
    case terminal(TerminalTabState)
    case editor(EditorTabState)
    case diff(DiffTabState)

    var id: TabID {
        switch self {
        case .terminal(let s): return s.id
        case .editor(let s):   return s.id
        case .diff(let s):     return s.id
        }
    }

    var title: String {
        switch self {
        case .terminal(let s): return s.title
        case .editor(let s):   return s.title
        case .diff(let s):     return s.title
        }
    }

    var iconName: String {
        switch self {
        case .terminal: return "terminal"
        case .editor:   return "code"
        case .diff:     return "diff"
        }
    }

    var relativeFilePath: String? {
        switch self {
        case .editor(let s): return s.relativePath
        default:             return nil
        }
    }
}

struct TerminalTabState: Codable, Equatable, Identifiable {
    let id: TabID
    var title: String       // e.g. branch name, "main", or "+ N"
    var sessionId: String   // matches TerminalSession.id (re-attached on launch)
}

struct EditorTabState: Codable, Equatable, Identifiable {
    let id: TabID
    var title: String
    var relativePath: String   // relative to worktree root
    var revealLine: Int? = nil       // 0-based, optional reveal hint set by go-to-definition
    var revealCharacter: Int? = nil  // 0-based UTF-16
}

struct DiffTabState: Codable, Equatable, Identifiable {
    let id: TabID
    var title: String
    var relativePath: String
}
