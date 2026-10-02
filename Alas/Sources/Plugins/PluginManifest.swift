import Foundation

enum PluginCapability: String, Codable, CaseIterable, Sendable, Hashable {
    case workspaceRead = "workspace.read"
    case worktreeSwitch = "worktree.switch"
    case sessionFocus = "session.focus"
    case tasksStart = "tasks.start"
    case sessionRead = "session.read"
    case notify

    /// The plugin API that introduced the capability; a manifest for an older API cannot ask for it.
    var api: Int { self == .notify ? 5 : 4 }

    /// Plain-language description shown when the user approves a plugin.
    var summary: String {
        switch self {
        case .workspaceRead: "Read this project's worktrees and what their agent sessions are doing"
        case .worktreeSwitch: "Switch the selected worktree"
        case .sessionFocus: "Open agent sessions in this project"
        case .tasksStart: "Create worktrees and start agents in this project"
        case .sessionRead: "Read agents' final replies and session changes in this project"
        case .notify: "Show notifications"
        }
    }
}

/// Session changes a plugin can subscribe to with the manifest's `events`.
enum PluginEvent: String, Sendable, Hashable {
    case sessionState = "session.state"
    case sessionFinished = "session.finished"

    var capability: PluginCapability { .sessionRead }
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
    case needsNewerAPI(String)

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
            "event \"\(name)\" needs capability \"\(PluginCapability.sessionRead.rawValue)\""
        case .needsNewerAPI(let feature):
            "\(feature) needs \"api\": 5"
        }
    }
}

/// `plugin.json`. Unknown fields are ignored so newer manifests still load.
struct PluginManifest: Equatable, Sendable {
    static let supportedAPIVersions = 4...5
    static let maxTabs = 4
    static let maxTabTitleLength = 40
    static let maxCommands = 16

    let id: String
    let name: String
    let version: String
    let api: Int
    let entry: String
    let capabilities: [PluginCapability]
    var tabs: [PluginTabContribution] = []
    var commands: [PluginCommandContribution] = []
    var events: [PluginEvent] = []

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
            guard capability.api <= api else { throw .needsNewerAPI("capability \"\(name)\"") }
            capabilities.append(capability)
        }
        var events: [PluginEvent] = []
        for name in raw.events ?? [] {
            guard let event = PluginEvent(rawValue: name) else { throw .unknownEvent(name) }
            guard api >= 5 else { throw .needsNewerAPI("\"events\"") }
            guard capabilities.contains(event.capability) else { throw .eventNeedsCapability(name) }
            events.append(event)
        }
        guard !entry.hasPrefix("/"), !entry.split(separator: "/").contains("..") else {
            throw .invalidEntry(entry)
        }
        if raw.contributesMalformed { throw .malformed }
        let tabs = try parseTabs(raw.contributes?.tabs ?? [])
        if raw.contributes?.commands != nil, api < 5 { throw .needsNewerAPI("\"contributes.commands\"") }
        let commands = try parseCommands(raw.contributes?.commands ?? [])
        return PluginManifest(
            id: id, name: name, version: version, api: api, entry: entry,
            capabilities: capabilities, tabs: tabs, commands: commands, events: events)
    }

    private static func parseCommands(_ raw: [Raw.RawCommand]) throws(PluginManifestError) -> [PluginCommandContribution] {
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
            // Slots will keep growing, so one this Alas does not know is skipped rather than refused.
            commands.append(PluginCommandContribution(
                id: id, title: title, icon: entry.icon, slots: slots.compactMap(PluginCommandSlot.init(rawValue:))))
        }
        return commands
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
    struct RawContributes: Decodable {
        let tabs: [RawTab]?
        let commands: [RawCommand]?
    }

    let id: String?
    let name: String?
    let version: String?
    let api: Int?
    let entry: String?
    let capabilities: [String]?
    let events: [String]?
    let contributes: RawContributes?
    let contributesMalformed: Bool

    private enum CodingKeys: String, CodingKey { case id, name, version, api, entry, capabilities, events, contributes }

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
        // Lenient here so `parse` can tell a malformed `contributes` from a missing one.
        contributes = (try? container.decodeIfPresent(RawContributes.self, forKey: .contributes)) ?? nil
        contributesMalformed = contributes == nil && container.contains(.contributes)
            && !((try? container.decodeNil(forKey: .contributes)) ?? false)
    }
}
