import Foundation

enum PluginCapability: String, Codable, CaseIterable, Sendable, Hashable {
    case workspaceRead = "workspace.read"
    case worktreeSwitch = "worktree.switch"
    case sessionFocus = "session.focus"
    case tasksStart = "tasks.start"
    case sessionRead = "session.read"
    case notify
    case network
    case timers
    case sessionWrite = "session.write"
    case runsRead = "runs.read"
    case runsStart = "runs.start"
    case reviewRead = "review.read"
    case reviewWrite = "review.write"
    case processExec = "process.exec"
    case filesRead = "files.read"
    case filesWrite = "files.write"

    /// The plugin API that introduced the capability; a manifest for an older API cannot ask for it.
    var api: Int {
        switch self {
        case .notify, .network, .timers: 5
        case .sessionWrite, .runsRead, .runsStart, .reviewRead, .reviewWrite, .processExec, .filesRead, .filesWrite: 6
        default: 4
        }
    }

    /// Plain-language description shown when the user approves a plugin.
    var summary: String {
        switch self {
        case .workspaceRead: "Read this project's worktrees and what their agent sessions are doing"
        case .worktreeSwitch: "Switch the selected worktree"
        case .sessionFocus: "Open agent sessions in this project"
        case .tasksStart: "Create worktrees and start agents in this project"
        case .sessionRead: "Read agents' final replies and session changes in this project"
        case .notify: "Show notifications"
        case .network: "Make web requests to the hosts it lists"
        case .timers: "Run on a schedule"
        case .sessionWrite: "Send messages to agent sessions in this project"
        case .runsRead: "Read when run scripts start and finish in this project, and their output"
        case .runsStart: "Start run scripts in this project"
        case .reviewRead: "Read the pull request state and checks of this project's worktrees"
        case .reviewWrite: "Add review comments to changes in this project"
        case .processExec: "Run the commands listed below in this project's worktrees"
        case .filesRead: "Read files in this project's worktrees"
        case .filesWrite: "Create and change files in this project's worktrees"
        }
    }

    /// Acts with the user's permissions outside the sandbox, so approving it takes a separate confirmation.
    var isFullAccess: Bool { self == .processExec || self == .filesWrite }
}

/// A command the plugin may run with `process.exec`: an exact argv prefix (API 6).
struct PluginProcessContribution: Equatable, Sendable {
    let id: String
    let command: [String]
    var appendArgs = false
    var longRunning = false
}

/// Changes a plugin can subscribe to with the manifest's `events`.
enum PluginEvent: String, Sendable, Hashable {
    case sessionState = "session.state"
    case sessionFinished = "session.finished"
    // API 6.
    case gitChanged = "git.changed"
    case worktreeCreated = "worktree.created"
    case worktreeRemoved = "worktree.removed"
    case focusChanged = "focus.changed"
    case runStarted = "run.started"
    case runFinished = "run.finished"
    case reviewChanged = "review.changed"

    var capability: PluginCapability {
        switch self {
        case .sessionState, .sessionFinished: .sessionRead
        case .gitChanged, .worktreeCreated, .worktreeRemoved, .focusChanged: .workspaceRead
        case .runStarted, .runFinished: .runsRead
        case .reviewChanged: .reviewRead
        }
    }

    var api: Int { capability == .sessionRead ? 5 : 6 }
    /// `session.state` is sent as `session/state`.
    var method: String { rawValue.replacingOccurrences(of: ".", with: "/") }
}

/// A tab the plugin draws with `alas.present` (canvas) or describes with `view/render` (view).
struct PluginTabContribution: Equatable, Sendable {
    enum Kind: String, Sendable { case canvas, view }

    let id: String
    let title: String
    var kind: Kind = .canvas
}

/// Where a panel is shown.
enum PluginPanelLocation: String, Sendable {
    /// A button in the right pane's rail.
    case right
    /// A row in the Changes tab, rendered for its worktree (API 6).
    case changesSection = "changes.section"
    /// Under a run report's header, rendered for its run (API 6).
    case runReportSection = "run.report.section"

    var api: Int { self == .right ? 5 : 6 }
}

/// A view tree the plugin describes with `view/render {panel}`, shown outside the center tabs.
struct PluginPanelContribution: Equatable, Sendable {
    static let defaultIcon = "puzzlepiece.extension"

    let id: String
    let title: String
    var icon: String = defaultIcon
    var location: PluginPanelLocation = .right
}

/// A value the user sets for the plugin in Settings → Plugins.
struct PluginSetting: Equatable, Sendable {
    enum Kind: String, Sendable { case string, bool, secret }

    let key: String
    let title: String
    let kind: Kind
    var defaultValue: PluginSettingValue?
    /// Secret only: the hosts its `{{secret:key}}` may be sent to.
    var hosts: [String] = []
}

/// A setting's value or default; encodes as a bare JSON string or boolean.
enum PluginSettingValue: Codable, Equatable, Sendable {
    case string(String)
    case bool(Bool)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }
}

enum PluginManifestError: Error, Equatable, CustomStringConvertible {
    case malformed
    case missingField(String)
    case invalidID(String)
    case unsupportedAPI(Int)
    case unknownCapability(String)
    case invalidEntry(String)
    case invalidTab(String)
    case invalidCommand(String)
    case unknownEvent(String)
    case eventNeedsCapability(String)
    case needsNewerAPI(String, api: Int = 5)
    case invalidSetting(String)
    case invalidNetwork(String)
    case invalidPanel(String)
    case invalidProcess(String)

    var description: String {
        switch self {
        case .malformed:
            "plugin.json is not a valid JSON object"
        case .missingField(let field):
            "plugin.json is missing \"\(field)\""
        case .invalidID(let id):
            "invalid plugin id \"\(id)\"; use reverse-DNS such as io.example.plugin"
        case .unsupportedAPI(let api) where (1...3).contains(api):
            "built for plugin API \(api), the WebAssembly runtime, which Alas no longer supports; rebuild it for API \(PluginManifest.supportedAPIVersions.upperBound)"
        case .unsupportedAPI(let api):
            "requires plugin API \(api); this Alas supports up to \(PluginManifest.supportedAPIVersions.upperBound)"
        case .unknownCapability(let name):
            "unknown capability \"\(name)\""
        case .invalidEntry(let entry):
            "entry \"\(entry)\" must be a relative path inside the plugin folder"
        case .invalidTab(let reason):
            "invalid tab contribution: \(reason)"
        case .invalidCommand(let reason):
            "invalid command contribution: \(reason)"
        case .unknownEvent(let name):
            "unknown event \"\(name)\""
        case .eventNeedsCapability(let name):
            "event \"\(name)\" needs capability \"\(PluginEvent(rawValue: name)?.capability.rawValue ?? "")\""
        case .needsNewerAPI(let feature, let api):
            "\(feature) needs \"api\": \(api)"
        case .invalidSetting(let reason):
            "invalid setting: \(reason)"
        case .invalidNetwork(let reason):
            "invalid network list: \(reason)"
        case .invalidPanel(let reason):
            "invalid panel contribution: \(reason)"
        case .invalidProcess(let reason):
            "invalid process: \(reason)"
        }
    }
}

/// `plugin.json`. Unknown fields are ignored so newer manifests still load.
struct PluginManifest: Equatable, Sendable {
    static let supportedAPIVersions = 4...6
    static let maxTabs = 4
    static let maxTabTitleLength = 40
    static let maxCommands = 16
    static let maxSettings = 16
    static let maxPanels = 2
    static let maxPanelsAPI6 = 4
    static let maxProcesses = 16
    static let maxArgBytes = 1024

    let id: String
    let name: String
    let version: String
    let api: Int
    let entry: String
    let capabilities: [PluginCapability]
    var tabs: [PluginTabContribution] = []
    var panels: [PluginPanelContribution] = []
    var commands: [PluginCommandContribution] = []
    var events: [PluginEvent] = []
    var settings: [PluginSetting] = []
    /// Hosts `http/fetch` may reach: exact, lowercase names.
    var network: [String] = []
    /// Commands `process.exec` may run.
    var processes: [PluginProcessContribution] = []

    static func parse(_ data: Data) throws(PluginManifestError) -> PluginManifest {
        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: data)
        } catch {
            throw .malformed
        }

        func required(_ value: String?, _ field: String) throws(PluginManifestError) -> String {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw .missingField(field)
            }
            return value
        }
        let id = try required(raw.id, "id")
        let name = try required(raw.name, "name")
        let version = try required(raw.version, "version")
        guard let api = raw.api else { throw .missingField("api") }
        let entry = try required(raw.entry, "entry")

        guard id.wholeMatch(of: /[a-z0-9-]+(\.[a-z0-9-]+)+/) != nil else { throw .invalidID(id) }
        guard supportedAPIVersions.contains(api) else { throw .unsupportedAPI(api) }
        // Features newer than the manifest's API are refused, so a plugin never half-works on an older Alas.
        var capabilities: [PluginCapability] = []
        for name in raw.capabilities ?? [] {
            guard let capability = PluginCapability(rawValue: name) else { throw .unknownCapability(name) }
            guard capability.api <= api else { throw .needsNewerAPI("capability \"\(name)\"", api: capability.api) }
            capabilities.append(capability)
        }
        var events: [PluginEvent] = []
        for name in raw.events ?? [] {
            guard let event = PluginEvent(rawValue: name) else { throw .unknownEvent(name) }
            guard api >= 5 else { throw .needsNewerAPI("\"events\"") }
            guard event.api <= api else { throw .needsNewerAPI("event \"\(name)\"", api: event.api) }
            guard capabilities.contains(event.capability) else { throw .eventNeedsCapability(name) }
            events.append(event)
        }
        guard !entry.hasPrefix("/"), !entry.split(separator: "/").contains("..") else {
            throw .invalidEntry(entry)
        }
        if raw.contributesMalformed { throw .malformed }
        let tabs = try parseTabs(raw.contributes?.tabs ?? [])
        if raw.contributes?.commands != nil, api < 5 { throw .needsNewerAPI("\"contributes.commands\"") }
        let commands = try parseCommands(raw.contributes?.commands ?? [], api: api)
        if raw.contributes?.panels != nil, api < 5 { throw .needsNewerAPI("\"contributes.panels\"") }
        let panels = try parsePanels(raw.contributes?.panels ?? [], tabs: tabs, api: api)
        if raw.network != nil || raw.settings != nil, api < 5 {
            throw .needsNewerAPI(raw.network != nil ? "\"network\"" : "\"settings\"")
        }
        let network = raw.network ?? []
        if capabilities.contains(.network) {
            guard !network.isEmpty else { throw .invalidNetwork("capability \"network\" needs at least one host") }
        } else if !network.isEmpty {
            throw .invalidNetwork("\"network\" needs capability \"network\"")
        }
        for host in network where !isValidHost(host) {
            throw .invalidNetwork("\"\(host)\" is not a lowercase hostname; no schemes, ports or wildcards")
        }
        let settings = try parseSettings(raw.settings ?? [], network: network)
        if raw.processes != nil, api < 6 { throw .needsNewerAPI("\"processes\"", api: 6) }
        let processes = try parseProcesses(raw.processes ?? [])
        if capabilities.contains(.processExec) {
            guard !processes.isEmpty else { throw .invalidProcess("capability \"process.exec\" needs at least one process") }
        } else if !processes.isEmpty {
            throw .invalidProcess("\"processes\" needs capability \"process.exec\"")
        }
        return PluginManifest(
            id: id, name: name, version: version, api: api, entry: entry,
            capabilities: capabilities, tabs: tabs, panels: panels, commands: commands, events: events,
            settings: settings, network: network, processes: processes)
    }

    static func isValidHost(_ host: String) -> Bool {
        host.wholeMatch(of: /[a-z0-9-]+(\.[a-z0-9-]+)+/) != nil
    }

    private static func parseSettings(_ raw: [Raw.RawSetting], network: [String]) throws(PluginManifestError) -> [PluginSetting] {
        guard raw.count <= maxSettings else { throw .invalidSetting("at most \(maxSettings) settings") }
        var settings: [PluginSetting] = []
        for entry in raw {
            let key = entry.key ?? ""
            // Also the `{{secret:key}}` placeholder, so no braces or spaces.
            guard key.wholeMatch(of: /[A-Za-z0-9_-]{1,64}/) != nil else {
                throw .invalidSetting("invalid setting key \"\(key)\"")
            }
            // Case-insensitive: secrets may fall back to files, and the default macOS volume folds case.
            guard !settings.contains(where: { $0.key.lowercased() == key.lowercased() }) else {
                throw .invalidSetting("duplicate setting key \"\(key)\"")
            }
            let title = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...maxTabTitleLength).contains(title.count) else {
                throw .invalidSetting("setting \"\(key)\" needs a title of 1 to \(maxTabTitleLength) characters")
            }
            guard let kind = PluginSetting.Kind(rawValue: entry.type ?? "") else {
                throw .invalidSetting("setting \"\(key)\" has unknown type \"\(entry.type ?? "")\"")
            }
            switch (kind, entry.defaultValue) {
            case (_, nil), (.string, .string?), (.bool, .bool?): break
            default: throw .invalidSetting("setting \"\(key)\" has a default of the wrong type")
            }
            // The same limit the form enforces, so every settings message fits.
            if case .string(let text)? = entry.defaultValue, text.utf8.count > PluginSettings.maxStringBytes {
                throw .invalidSetting("setting \"\(key)\" has a default longer than \(PluginSettings.maxStringBytes) bytes")
            }
            let hosts = entry.hosts ?? []
            if kind == .secret {
                guard !hosts.isEmpty else { throw .invalidSetting("secret \"\(key)\" needs at least one host") }
                // A secret only travels in `http/fetch`, so its hosts must be ones the plugin may reach.
                if let host = hosts.first(where: { !network.contains($0) }) {
                    throw .invalidSetting("secret \"\(key)\" names \"\(host)\", which is not in \"network\"")
                }
            } else if !hosts.isEmpty {
                throw .invalidSetting("only secret settings take hosts")
            }
            settings.append(PluginSetting(key: key, title: title, kind: kind, defaultValue: entry.defaultValue, hosts: hosts))
        }
        return settings
    }

    private static func parseProcesses(_ raw: [Raw.RawProcess]) throws(PluginManifestError) -> [PluginProcessContribution] {
        guard raw.count <= maxProcesses else { throw .invalidProcess("at most \(maxProcesses) processes") }
        var processes: [PluginProcessContribution] = []
        for entry in raw {
            let id = entry.id ?? ""
            guard id.wholeMatch(of: /[a-z0-9-]+(\.[a-z0-9-]+)*/) != nil else { throw .invalidProcess("invalid process id \"\(id)\"") }
            guard !processes.contains(where: { $0.id == id }) else { throw .invalidProcess("duplicate process id \"\(id)\"") }
            let command = entry.command ?? []
            guard let executable = command.first, !executable.isEmpty else {
                throw .invalidProcess("process \"\(id)\" needs a command")
            }
            guard command.allSatisfy({ $0.utf8.count <= maxArgBytes }) else {
                throw .invalidProcess("process \"\(id)\" has an argument longer than \(maxArgBytes) bytes")
            }
            processes.append(PluginProcessContribution(
                id: id, command: command, appendArgs: entry.appendArgs ?? false, longRunning: entry.longRunning ?? false))
        }
        return processes
    }

    private static func parseCommands(_ raw: [Raw.RawCommand], api: Int) throws(PluginManifestError) -> [PluginCommandContribution] {
        guard raw.count <= maxCommands else { throw .invalidCommand("at most \(maxCommands) commands") }
        var commands: [PluginCommandContribution] = []
        for entry in raw {
            let id = entry.id ?? ""
            guard id.wholeMatch(of: /[a-z0-9-]+(\.[a-z0-9-]+)*/) != nil else { throw .invalidCommand("invalid command id \"\(id)\"") }
            guard !commands.contains(where: { $0.id == id }) else { throw .invalidCommand("duplicate command id \"\(id)\"") }
            let title = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...maxTabTitleLength).contains(title.count) else {
                throw .invalidCommand("command \"\(id)\" needs a title of 1 to \(maxTabTitleLength) characters")
            }
            guard let slots = entry.slots, !slots.isEmpty else { throw .invalidCommand("command \"\(id)\" needs at least one slot") }
            // Slots will keep growing, so one this Alas does not know is skipped rather than refused, and so is one
            // newer than the manifest's API, as an Alas of that API would.
            commands.append(PluginCommandContribution(
                id: id, title: title, icon: entry.icon,
                slots: slots.compactMap(PluginCommandSlot.init(rawValue:)).filter { $0.api <= api }))
        }
        return commands
    }

    private static func parsePanels(
        _ raw: [Raw.RawPanel], tabs: [PluginTabContribution], api: Int
    ) throws(PluginManifestError) -> [PluginPanelContribution] {
        let limit = api >= 6 ? maxPanelsAPI6 : maxPanels
        guard raw.count <= limit else { throw .invalidPanel("at most \(limit) panels") }
        var panels: [PluginPanelContribution] = []
        // Every declared id, skipped locations included, so uniqueness does not depend on order or on what this
        // Alas supports.
        var declared: Set<String> = []
        for entry in raw {
            let id = entry.id ?? ""
            guard id.wholeMatch(of: /[a-z0-9-]+(\.[a-z0-9-]+)*/) != nil else { throw .invalidPanel("invalid panel id \"\(id)\"") }
            guard declared.insert(id).inserted else { throw .invalidPanel("duplicate panel id \"\(id)\"") }
            guard !tabs.contains(where: { $0.id == id }) else { throw .invalidPanel("panel id \"\(id)\" is also a tab id") }
            let title = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...maxTabTitleLength).contains(title.count) else {
                throw .invalidPanel("panel \"\(id)\" needs a title of 1 to \(maxTabTitleLength) characters")
            }
            // Locations will keep growing, so one this Alas does not know is skipped rather than refused, and so is
            // one newer than the manifest's API, as an Alas of that API would.
            guard let location = PluginPanelLocation(rawValue: entry.location ?? "right"), location.api <= api else { continue }
            let icon = (entry.icon ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            panels.append(PluginPanelContribution(
                id: id, title: title, icon: icon.isEmpty ? PluginPanelContribution.defaultIcon : icon, location: location))
        }
        return panels
    }

    private static func parseTabs(_ raw: [Raw.RawTab]) throws(PluginManifestError) -> [PluginTabContribution] {
        guard raw.count <= maxTabs else { throw .invalidTab("at most \(maxTabs) tabs") }
        var tabs: [PluginTabContribution] = []
        for entry in raw {
            let id = entry.id ?? ""
            guard id.wholeMatch(of: /[a-z0-9-]+(\.[a-z0-9-]+)*/) != nil else { throw .invalidTab("invalid tab id \"\(id)\"") }
            guard !tabs.contains(where: { $0.id == id }) else { throw .invalidTab("duplicate tab id \"\(id)\"") }
            let title = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...maxTabTitleLength).contains(title.count) else {
                throw .invalidTab("tab \"\(id)\" needs a title of 1 to \(maxTabTitleLength) characters")
            }
            var kind = PluginTabContribution.Kind.canvas
            if let rawKind = entry.kind {
                guard let parsed = PluginTabContribution.Kind(rawValue: rawKind) else {
                    throw .invalidTab("tab \"\(id)\" has unknown kind \"\(rawKind)\"")
                }
                kind = parsed
            }
            tabs.append(PluginTabContribution(id: id, title: title, kind: kind))
        }
        return tabs
    }
}

private struct Raw: Decodable {
    struct RawTab: Decodable {
        let id: String?
        let title: String?
        let kind: String?
    }
    struct RawCommand: Decodable {
        let id: String?
        let title: String?
        let icon: String?
        let slots: [String]?
    }
    struct RawSetting: Decodable {
        let key: String?
        let title: String?
        let type: String?
        let defaultValue: PluginSettingValue?
        let hosts: [String]?

        private enum CodingKeys: String, CodingKey {
            case key, title, type, hosts
            case defaultValue = "default"
        }
    }
    struct RawPanel: Decodable {
        let id: String?
        let title: String?
        let icon: String?
        let location: String?
    }
    struct RawProcess: Decodable {
        let id: String?
        let command: [String]?
        let appendArgs: Bool?
        let longRunning: Bool?
    }
    struct RawContributes: Decodable {
        let tabs: [RawTab]?
        let commands: [RawCommand]?
        let panels: [RawPanel]?
    }

    let id: String?
    let name: String?
    let version: String?
    let api: Int?
    let entry: String?
    let capabilities: [String]?
    let events: [String]?
    let settings: [RawSetting]?
    let network: [String]?
    let processes: [RawProcess]?
    let contributes: RawContributes?
    let contributesMalformed: Bool

    private enum CodingKeys: String, CodingKey { case id, name, version, api, entry, capabilities, events, settings, network, processes, contributes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        api = try container.decodeIfPresent(Int.self, forKey: .api)
        entry = try container.decodeIfPresent(String.self, forKey: .entry)
        // Optional means omitted, not null: `"capabilities": null` is malformed, not "none requested".
        capabilities = container.contains(.capabilities)
            ? try container.decode([String].self, forKey: .capabilities) : nil
        events = container.contains(.events) ? try container.decode([String].self, forKey: .events) : nil
        settings = container.contains(.settings) ? try container.decode([RawSetting].self, forKey: .settings) : nil
        network = container.contains(.network) ? try container.decode([String].self, forKey: .network) : nil
        processes = container.contains(.processes) ? try container.decode([RawProcess].self, forKey: .processes) : nil
        // Lenient here so `parse` can tell a malformed `contributes` from a missing one.
        contributes = (try? container.decodeIfPresent(RawContributes.self, forKey: .contributes)) ?? nil
        contributesMalformed = contributes == nil && container.contains(.contributes)
            && !((try? container.decodeNil(forKey: .contributes)) ?? false)
    }
}
