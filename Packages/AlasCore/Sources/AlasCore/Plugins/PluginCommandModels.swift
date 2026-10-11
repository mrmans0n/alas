import Foundation

/// Where Alas shows a plugin command. A manifest may name slots this Alas does not know; those are skipped.
public enum PluginCommandSlot: String, Sendable, Hashable {
    case palette
    case menubar
    case toolbar
    case worktreeMenu = "worktree.menu"
    case repoMenu = "repo.menu"
    // API 6.
    case changesToolbar = "changes.toolbar"
    case changesFileMenu = "changes.file.menu"
    case changesCommitMenu = "changes.commit.menu"
    case runMenu = "run.menu"
    case runReport = "run.report"
    case sessionMenu = "session.menu"
    // API 7.
    case messageMenu = "message.menu"

    /// The plugin API that introduced the slot; an older manifest that names it has it skipped, as an older Alas would.
    public var api: Int {
        switch self {
        case .palette, .menubar, .toolbar, .worktreeMenu, .repoMenu: 5
        case .messageMenu: 7
        default: 6
        }
    }
}

/// A manifest command. Alas draws it without asking the plugin, and sends `command/run` when it is chosen.
public struct PluginCommandContribution: Equatable, Sendable {
    public let id: String
    public let title: String
    /// An SF Symbol name.
    public var icon: String?
    public let slots: [PluginCommandSlot]
    /// API 8: a tab of the same manifest Alas opens before it runs the command.
    public var opens: String? = nil

    public init(id: String, title: String, icon: String? = nil, slots: [PluginCommandSlot], opens: String? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
        self.slots = slots
        self.opens = opens
    }
}

/// `command/run`'s `target`: what the user acted on. `kind` says which of the other fields are set.
public struct PluginCommandTarget: Codable, Equatable, Sendable {
    public let kind: String
    public var worktree: String?
    public var path: String?
    public var sha: String?
    public var script: String?
    public var run: String?
    public var session: String?
    /// The message's Markdown, for `message.menu`.
    public var text: String?

    public static let project = PluginCommandTarget(kind: "project")
    public static func worktree(_ id: String) -> PluginCommandTarget { PluginCommandTarget(kind: "worktree", worktree: id) }

    public init(kind: String, worktree: String? = nil, path: String? = nil, sha: String? = nil, script: String? = nil, run: String? = nil, session: String? = nil, text: String? = nil) {
        self.kind = kind
        self.worktree = worktree
        self.path = path
        self.sha = sha
        self.script = script
        self.run = run
        self.session = session
        self.text = text
    }
}

public struct PluginCommandRunParams: Codable, Sendable {
    public let command: String
    public let target: PluginCommandTarget

    public init(command: String, target: PluginCommandTarget) {
        self.command = command
        self.target = target
    }
}
