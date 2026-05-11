import Foundation

typealias TabID = String

enum Tab: Codable, Equatable, Identifiable {
    case terminal(TerminalTabState)
    case editor(EditorTabState)
    case diff(DiffTabState)
    case commit(CommitTabState)
    case imagePreview(ImagePreviewTabState)

    var id: TabID {
        switch self {
        case .terminal(let s):     return s.id
        case .editor(let s):       return s.id
        case .diff(let s):         return s.id
        case .commit(let s):       return s.id
        case .imagePreview(let s): return s.id
        }
    }

    var title: String {
        switch self {
        case .terminal(let s):     return s.title
        case .editor(let s):       return s.title
        case .diff(let s):         return s.title
        case .commit(let s):       return s.title
        case .imagePreview(let s): return s.title
        }
    }

    var iconName: String {
        switch self {
        case .terminal:     return "terminal"
        case .editor:       return "code"
        case .diff:         return "diff"
        case .commit:       return "commit"
        case .imagePreview: return "image"
        }
    }

    var relativeFilePath: String? {
        switch self {
        case .editor(let s):       return s.isExternal ? nil : s.relativePath
        case .imagePreview(let s): return s.relativePath
        default:                   return nil
        }
    }
}

struct CommitTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let worktreeId: String
    let sha: String
    let title: String

    init(worktreeId: String, sha: String, title: String) {
        self.id = "commit:\(worktreeId):\(sha)"
        self.worktreeId = worktreeId
        self.sha = sha
        self.title = title
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
    var relativePath: String   // relative to worktree root; empty when external
    var revealLine: Int? = nil       // 0-based, optional reveal hint set by go-to-definition
    var revealCharacter: Int? = nil  // 0-based UTF-16
    var externalAbsolutePath: String? = nil  // set when navigating to a file outside the worktree
    /// The worktree-relative path of the in-worktree file the user was
    /// viewing when they ⌘-clicked to open this external tab. Persisted so
    /// that app-restart reopens can still route LSP traffic to the correct
    /// holder in nested-package layouts. Nil for tabs persisted before this
    /// field was added (backward-compatible via the default value).
    var originatingRelativePath: String? = nil
    /// Last view mode the user selected for this markdown tab. `nil` means
    /// "use `AppConfig.markdown.defaultViewMode`". Nil for non-markdown tabs.
    var markdownViewMode: MarkdownViewMode? = nil
    /// Editor-pane width as a fraction of the split container, persisted
    /// per-tab. Nil → 0.5. Nil for non-markdown or non-split tabs.
    var markdownSplitFraction: Double? = nil

    var isExternal: Bool { externalAbsolutePath != nil }
}

struct DiffTabState: Codable, Equatable, Identifiable {
    let id: TabID
    var title: String
    var relativePath: String
    var staged: Bool = false

    init(id: TabID, title: String, relativePath: String, staged: Bool = false) {
        self.id = id
        self.title = title
        self.relativePath = relativePath
        self.staged = staged
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, relativePath, staged
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(TabID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        staged = try container.decodeIfPresent(Bool.self, forKey: .staged) ?? false
    }
}

struct ImagePreviewTabState: Codable, Equatable, Identifiable {
    let id: TabID
    var title: String
    var relativePath: String
}
