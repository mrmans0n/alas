import SwiftUI

/// Rows a plugin can put short badges on with `decorations/set` (API 6).
enum PluginDecorationSlot: String, Sendable, Hashable {
    case repoRow = "repo.row"
    case worktreeRow = "worktree.row"
    case runRow = "run.row"
    case changesFile = "changes.file"

    /// The command slot whose target a clicked badge sends: the same thing the row's own menu acts on.
    var commandSlot: PluginCommandSlot {
        switch self {
        case .repoRow: .repoMenu
        case .worktreeRow: .worktreeMenu
        case .runRow: .runMenu
        case .changesFile: .changesFileMenu
        }
    }

    /// Run and file rows are named within a worktree; repo and worktree rows by their own id.
    var needsWorktree: Bool { self == .runRow || self == .changesFile }
}

/// One decorated row: `target` is the project id, worktree id, run script key or file path.
struct PluginDecorationKey: Hashable, Sendable {
    let slot: PluginDecorationSlot
    var worktree: String?
    let target: String
}

struct PluginDecoration: Equatable, Sendable {
    let text: String
    var tone: PluginViewNode.Tone?
    var tooltip: String?
    /// A declared command, sent with the row's target when the badge is clicked.
    var command: String?
}

struct PluginDecorationSetParams: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let text: String
        let tone: String?
        let tooltip: String?
        let command: String?
    }

    let slot: String
    let target: String
    let worktree: String?
    let items: [Item]
}

enum PluginDecorations {
    static let maxItems = 2
    static let maxTextScalars = 24
    static let maxTooltipScalars = 200
    static let maxTargetBytes = 1024
    /// Rows one plugin may decorate in one project, so a plugin cannot grow the map without bound.
    static let maxKeys = 256

    enum Outcome: Equatable {
        case set([PluginDecorationKey: [PluginDecoration]])
        /// Ignored with a warning: a slot this Alas does not know, or a row outside the project.
        case dropped(String)
        /// A broken message, which stops the plugin.
        case violation(String)
    }

    /// Applies one `decorations/set`: it replaces that plugin's items for the slot and target, and no items clear them.
    /// Items past the cap are dropped and text is cut, both by Unicode scalars.
    static func apply(
        _ params: PluginDecorationSetParams,
        to current: [PluginDecorationKey: [PluginDecoration]],
        commands: Set<String>,
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
                guard let parsed = PluginViewNode.Tone(rawValue: name) else {
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

/// A badge on a row, with the plugin and project whose host would run its command.
struct PluginDecorationItem: Identifiable, Equatable {
    let pluginID: String
    let projectID: String
    let key: PluginDecorationKey
    let index: Int
    let decoration: PluginDecoration
    var id: String { "\(pluginID)/\(index)" }
}

extension PluginViewNode.Tone {
    /// The theme color a tone draws with.
    var colorKey: String {
        switch self {
        case .normal: "fg"
        case .dim: "fg-dim"
        case .accent: "accent"
        case .warn: "warn"
        case .danger: "del"  // the theme has no "danger" key; "del" is its red
        }
    }
}

/// A row's plugin badges. One with a command is a button.
struct PluginDecorationBadges: View {
    let items: [PluginDecorationItem]
    let run: (PluginDecorationItem) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        ForEach(items) { item in
            let color = theme.color((item.decoration.tone ?? .dim).colorKey)
            let badge = Text(item.decoration.text)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundColor(color)
                .background(Capsule().fill(color.opacity(0.15)))
                .fixedSize()
                .help(item.decoration.tooltip ?? "")
            if item.decoration.command != nil {
                Button { run(item) } label: { badge }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .accessibilityLabel(item.decoration.tooltip ?? item.decoration.text)
            } else {
                badge.accessibilityLabel(item.decoration.tooltip ?? item.decoration.text)
            }
        }
    }
}
