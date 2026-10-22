import AlasACP
import AlasModel
import Foundation

/// A key `alas-host setup` reacts to, decoded from the terminal.
public enum HostSetupKey: Equatable, Sendable {
    case up, down, enter, escape, character(Character), backspace, tab
}

/// What the terminal layer does for the model: the model itself does no I/O.
public enum HostSetupEffect: Equatable, Sendable {
    case save, quit
    /// Adds the project at the typed path.
    case addProject(String)
    /// Removes the project with this id.
    case removeProject(String)
    case showPairingCode
}

/// The main menu's entries, in order.
public enum HostSetupMenuItem: CaseIterable, Sendable {
    case reachability, agents, projects, behavior, worktrees, pair, save

    public var title: String {
        switch self {
        case .reachability: HostSettingSection.reachability.title
        case .agents: HostSettingSection.agents.title
        case .projects: "Projects"
        case .behavior: HostSettingSection.behavior.title
        case .worktrees: HostSettingSection.worktrees.title
        case .pair: "Pair a device"
        case .save: "Save and quit"
        }
    }

    var section: HostSettingSection? {
        switch self {
        case .reachability: .reachability
        case .agents: .agents
        case .behavior: .behavior
        case .worktrees: .worktrees
        case .projects, .pair, .save: nil
        }
    }
}

public enum HostSetupScreen: Equatable, Sendable {
    case menu(selected: Int)
    /// A section's settings; `editing` holds the text of the selected row while it is edited.
    case settings(HostSettingSection, selected: Int, editing: String?)
    /// The projects, then an "Add a project" row whose path is typed into `editing`.
    case projects(selected: Int, editing: String?)
}

/// What the terminal draws for the current screen.
public struct HostSetupView: Equatable, Sendable {
    public var title: String
    public var rows: [String]
    public var selected: Int
    public var hint: String

    public init(title: String, rows: [String], selected: Int, hint: String) {
        self.title = title
        self.rows = rows
        self.selected = selected
        self.hint = hint
    }
}

/// `alas-host setup`'s state: which screen is up, and the settings as edited
/// so far. Driven by keys; the effects it returns are the terminal's to run.
public struct HostSetupModel: Equatable {
    public private(set) var original: AppConfig
    public private(set) var changedConfig: AppConfig
    public var projects: [ProjectSnapshot]
    public private(set) var screen: HostSetupScreen = .menu(selected: 0)
    /// A line shown under the screen until the next key: an error, a pairing code.
    public var notice: String?
    /// The adapter command each agent launches, by agent id, for agents whose
    /// command is not found; an enabled one is marked on the Agents screen.
    public let missingCommands: [String: String]
    private var escapeDiscards = false
    /// The project the last Enter asked to remove; a second Enter removes it.
    private var pendingRemoval: String?

    public init(config: AppConfig, projects: [ProjectSnapshot], missingCommands: [String: String] = [:]) {
        original = config
        changedConfig = config
        self.projects = projects
        self.missingCommands = missingCommands
    }

    /// The adapter command of each agent `isFound` rejects, keyed by the id in
    /// its `agents.<id>.enabled` setting: a registry agent's registry id.
    public static func missingAdapterCommands(_ config: AppConfig, isFound: (String) -> Bool) -> [String: String] {
        var missing: [String: String] = [:]
        for spec in ACPLaunchCatalog.builtinSpecs where !isFound(spec.command) {
            missing[spec.agentID] = spec.command
        }
        for installed in config.agents.registry where !isFound(installed.command) {
            missing[installed.registryID] = installed.command
        }
        return missing
    }

    /// Whether any setting differs from what the profile had: a setting set
    /// back to its old value, or a derived one made explicit, is no change.
    public var isDirty: Bool {
        HostSettingCatalog.all(for: original).contains { $0.value(in: original) != $0.value(in: changedConfig) }
    }

    /// Sets on `config` every setting changed here, leaving the rest of it alone.
    public func applyChanges(to config: inout AppConfig) throws(HostSettingError) {
        for setting in HostSettingCatalog.all(for: original) where setting.value(in: original) != setting.value(in: changedConfig) {
            try HostSettingCatalog.named(setting.key, in: config).set(setting.value(in: changedConfig), in: &config)
        }
    }

    /// Takes the profile as saved, so later changes compare against it.
    public mutating func markSaved() {
        original = changedConfig
    }

    private func settings(in section: HostSettingSection) -> [HostSetting] {
        HostSettingCatalog.all(for: changedConfig).filter { $0.section == section }
    }

    public mutating func handle(_ key: HostSetupKey) -> HostSetupEffect? {
        notice = nil
        let wasDiscarding = escapeDiscards
        escapeDiscards = false
        let removal = pendingRemoval
        pendingRemoval = nil
        switch screen {
        case .menu(let selected):
            return handleMenu(key, selected: selected, discarding: wasDiscarding)
        case .settings(let section, let selected, let editing):
            handleSettings(key, section: section, selected: selected, editing: editing)
            return nil
        case .projects(let selected, let editing):
            return handleProjects(key, selected: selected, editing: editing, pendingRemoval: removal)
        }
    }

    private static func moved(_ selected: Int, _ key: HostSetupKey, count: Int) -> Int? {
        switch key {
        case .up: max(selected - 1, 0)
        case .down, .tab: min(selected + 1, max(count - 1, 0))
        default: nil
        }
    }

    private mutating func handleMenu(_ key: HostSetupKey, selected: Int, discarding: Bool) -> HostSetupEffect? {
        let items = HostSetupMenuItem.allCases
        if let moved = Self.moved(selected, key, count: items.count) {
            screen = .menu(selected: moved)
            return nil
        }
        switch key {
        case .enter:
            let item = items[selected]
            switch item {
            case .save: return isDirty ? .save : .quit
            case .pair: return .showPairingCode
            case .projects: screen = .projects(selected: projects.count, editing: nil)
            default: screen = .settings(item.section!, selected: 0, editing: nil)
            }
            return nil
        case .escape:
            guard isDirty, !discarding else { return .quit }
            escapeDiscards = true
            notice = "You have unsaved changes. Choose Save and quit, or press Escape again to discard them."
            return nil
        default:
            return nil
        }
    }

    private mutating func handleSettings(_ key: HostSetupKey, section: HostSettingSection, selected: Int, editing: String?) {
        let rows = settings(in: section)
        guard rows.indices.contains(selected) else {
            if key == .escape { screen = menu(at: section) }
            return
        }
        let setting = rows[selected]
        if var text = editing {
            switch key {
            case .character(let character): text.append(character)
            case .backspace: _ = text.popLast()
            case .escape: screen = .settings(section, selected: selected, editing: nil)
            return
            case .enter:
                do {
                    try setting.set(text.trimmingCharacters(in: .whitespaces), in: &changedConfig)
                    screen = .settings(section, selected: selected, editing: nil)
                } catch {
                    notice = error.localizedDescription
                }
                return
            default: return
            }
            screen = .settings(section, selected: selected, editing: text)
            return
        }
        if let moved = Self.moved(selected, key, count: rows.count) {
            screen = .settings(section, selected: moved, editing: nil)
            return
        }
        switch key {
        case .enter:
            let value = setting.value(in: changedConfig)
            switch setting.kind {
            case .bool:
                try? setting.set(value == "true" ? "false" : "true", in: &changedConfig)
            case .choice(let choices):
                let next = choices[((choices.firstIndex(of: value) ?? -1) + 1) % choices.count]
                try? setting.set(next, in: &changedConfig)
            case .text, .path, .port:
                screen = .settings(section, selected: selected, editing: value)
            }
        case .escape:
            screen = menu(at: section)
        default:
            break
        }
    }

    private mutating func handleProjects(
        _ key: HostSetupKey, selected: Int, editing: String?, pendingRemoval removal: String?
    ) -> HostSetupEffect? {
        if var path = editing {
            switch key {
            case .character(let character): path.append(character)
            case .backspace: _ = path.popLast()
            case .escape: screen = .projects(selected: selected, editing: nil)
            return nil
            case .enter:
                screen = .projects(selected: selected, editing: nil)
                let trimmed = path.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : .addProject((trimmed as NSString).expandingTildeInPath)
            default: return nil
            }
            screen = .projects(selected: selected, editing: path)
            return nil
        }
        // The projects, then the add row.
        if let moved = Self.moved(min(selected, projects.count), key, count: projects.count + 1) {
            screen = .projects(selected: moved, editing: nil)
            return nil
        }
        switch key {
        case .enter:
            guard projects.indices.contains(selected) else {
                screen = .projects(selected: projects.count, editing: "")
                return nil
            }
            let project = projects[selected]
            if removal == project.id { return .removeProject(project.id) }
            pendingRemoval = project.id
            notice = "Remove \(project.name)? Its settings, scripts and schedules are deleted. Press Enter again to remove, Esc to keep."
        case .escape:
            // Esc after a removal was asked keeps the project and the screen.
            guard removal == nil else { return nil }
            screen = .menu(selected: HostSetupMenuItem.allCases.firstIndex(of: .projects)!)
        default:
            break
        }
        return nil
    }

    /// `claude` for `agents.claude.enabled`.
    private static func agentID(of key: String) -> String? {
        guard key.hasPrefix("agents."), key.hasSuffix(".enabled") else { return nil }
        return String(key.dropFirst("agents.".count).dropLast(".enabled".count))
    }

    private func menu(at section: HostSettingSection) -> HostSetupScreen {
        .menu(selected: HostSetupMenuItem.allCases.firstIndex { $0.section == section } ?? 0)
    }

    // MARK: - Drawing

    public var view: HostSetupView {
        switch screen {
        case .menu(let selected):
            return HostSetupView(
                title: "Alas host setup" + (isDirty ? " (unsaved changes)" : ""),
                rows: HostSetupMenuItem.allCases.map(\.title),
                selected: selected,
                hint: "Up/Down to move, Enter to open, Esc to quit"
            )
        case .settings(let section, let selected, let editing):
            let rows = settings(in: section)
            let width = rows.map(\.title.count).max() ?? 0
            return HostSetupView(
                title: HostSetupMenuItem.allCases.first { $0.section == section }!.title,
                rows: rows.enumerated().map { index, setting in
                    let value = index == selected ? editing.map { "\($0)_" } ?? setting.value(in: changedConfig) : setting.value(in: changedConfig)
                    var shown = value.isEmpty ? "(default)" : value
                    if section == .agents, value == "true", let id = Self.agentID(of: setting.key), let command = missingCommands[id] {
                        shown += " - `\(command)` not found on PATH"
                    }
                    return setting.title.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + shown
                },
                selected: selected,
                hint: editing != nil
                    ? "Type the value; Enter to confirm, Esc to cancel"
                    : "Enter to change, Esc to go back"
            )
        case .projects(let selected, let editing):
            return HostSetupView(
                title: "Projects",
                rows: projects.map { "\($0.name)  \($0.path)" } + ["Add a project: " + (editing.map { "\($0)_" } ?? "")],
                selected: min(selected, projects.count),
                hint: editing != nil
                    ? "Type the project's path; Enter to add, Esc to cancel"
                    : "Enter on a project to remove it; Enter on Add a project to add one; Esc to go back"
            )
        }
    }
}
