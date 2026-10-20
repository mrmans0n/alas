import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// One decorated row: `target` is the project id, worktree id, run script key or file path.
public struct PluginDecorationKey: Hashable, Sendable {
    public let slot: PluginDecorationSlot
    public var worktree: String?
    public let target: String

    public init(slot: PluginDecorationSlot, worktree: String? = nil, target: String) {
        self.slot = slot
        self.worktree = worktree
        self.target = target
    }
}

public struct PluginDecoration: Equatable, Sendable {
    public let text: String
    public var tone: PluginViewNode.Tone?
    public var tooltip: String?
    /// A declared command, sent with the row's target when the badge is clicked.
    public var command: String?

    public init(text: String, tone: PluginViewNode.Tone? = nil, tooltip: String? = nil, command: String? = nil) {
        self.text = text
        self.tone = tone
        self.tooltip = tooltip
        self.command = command
    }
}

public struct PluginDecorationSetParams: Decodable, Sendable {
    public struct Item: Decodable, Sendable {
        public let text: String
        public let tone: String?
        public let tooltip: String?
        public let command: String?

        public init(text: String, tone: String?, tooltip: String?, command: String?) {
            self.text = text
            self.tone = tone
            self.tooltip = tooltip
            self.command = command
        }
    }

    public let slot: String
    public let target: String
    public let worktree: String?
    public let items: [Item]

    public init(slot: String, target: String, worktree: String?, items: [Item]) {
        self.slot = slot
        self.target = target
        self.worktree = worktree
        self.items = items
    }
}

public enum PluginDecorations: Sendable {
    public static let maxItems = 2
    public static let maxTextScalars = 24
    public static let maxTooltipScalars = 200
    public static let maxTargetBytes = 1024
    /// Rows one plugin may decorate in one project, so a plugin cannot grow the map without bound.
    public static let maxKeys = 256

    public enum Outcome: Equatable, Sendable {
        case set([PluginDecorationKey: [PluginDecoration]])
        /// Ignored with a warning: a slot this Alas does not know, or a row outside the project.
        case dropped(String)
        /// A broken message, which stops the plugin.
        case violation(String)
    }

    /// Applies one `decorations/set`: it replaces that plugin's items for the slot and target, and no items clear them.
    /// Items past the cap are dropped and text is cut, both by Unicode scalars.
    public static func apply(
        _ params: PluginDecorationSetParams,
        to current: [PluginDecorationKey: [PluginDecoration]],
        commands: Set<String>,
        api: Int,
        inProject: (PluginDecorationKey) -> Bool
    ) -> Outcome {
        guard let slot = PluginDecorationSlot(rawValue: params.slot) else {
            return .dropped("decorations/set for unknown slot \(params.slot)")
        }
        guard !params.target.isEmpty, params.target.utf8.count <= maxTargetBytes,
              (params.worktree != nil) == slot.needsWorktree
        else {
            return .violation("plugin sent a malformed decorations/set")
        }
        let key = PluginDecorationKey(slot: slot, worktree: params.worktree, target: params.target)
        guard inProject(key) else { return .dropped("decorations/set for \(params.target), which is not in this project") }
        var items: [PluginDecoration] = []
        for item in params.items.prefix(maxItems) {
            var tone: PluginViewNode.Tone?
            if let name = item.tone {
                guard let parsed = PluginViewNode.Tone(rawValue: name), parsed.api <= api else {
                    return .violation("plugin sent decorations/set with unknown tone \(name)")
                }
                tone = parsed
            }
            if let command = item.command, !commands.contains(command) {
                return .violation("plugin sent decorations/set with undeclared command \(command)")
            }
            let text = prefix(item.text, maxTextScalars)
            guard !text.isEmpty else { continue }
            items.append(PluginDecoration(
                text: text, tone: tone, tooltip: item.tooltip.map { prefix($0, maxTooltipScalars) }, command: item.command))
        }
        var updated = current
        if items.isEmpty {
            updated[key] = nil
        } else {
            guard current[key] != nil || current.count < maxKeys else {
                return .dropped("decorations/set ignored: at most \(maxKeys) decorated rows")
            }
            updated[key] = items
        }
        return .set(updated)
    }

    private static func prefix(_ text: String, _ scalars: Int) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(scalars)))
    }
}

/// Rows a plugin can put short badges on with `decorations/set` (API 6).
public enum PluginDecorationSlot: String, Sendable, Hashable {
    case repoRow = "repo.row"
    case worktreeRow = "worktree.row"
    case runRow = "run.row"
    case changesFile = "changes.file"

    /// The command slot whose target a clicked badge sends: the same thing the row's own menu acts on.
    public var commandSlot: PluginCommandSlot {
        switch self {
        case .repoRow: .repoMenu
        case .worktreeRow: .worktreeMenu
        case .runRow: .runMenu
        case .changesFile: .changesFileMenu
        }
    }

    /// Run and file rows are named within a worktree; repo and worktree rows by their own id.
    public var needsWorktree: Bool { self == .runRow || self == .changesFile }
}
