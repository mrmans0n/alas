import Foundation

enum PluginCapability: String, Codable, CaseIterable, Sendable, Hashable {
    case workspaceRead = "workspace.read"
    case worktreeSwitch = "worktree.switch"
    case sessionFocus = "session.focus"
    case tasksStart = "tasks.start"

    /// The first plugin API version that offers this capability.
    var minimumAPI: Int {
        switch self {
        case .workspaceRead, .worktreeSwitch: 1
        case .sessionFocus: 2
        case .tasksStart: 3
        }
    }

    /// Plain-language description shown when the user approves a plugin.
    var summary: String {
        switch self {
        case .workspaceRead: "Read this project's worktrees, what their agent sessions are doing, and agents' final replies"
        case .worktreeSwitch: "Switch the selected worktree"
        case .sessionFocus: "Open agent sessions in this project"
        case .tasksStart: "Create worktrees and start agents in this project"
        }
    }
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
    case capabilityNeedsNewerAPI(String, Int)

    var description: String {
        switch self {
        case .malformed:
            "plugin.json is not a valid JSON object"
        case .missingField(let field):
            "plugin.json is missing \"\(field)\""
        case .invalidID(let id):
            "invalid plugin id \"\(id)\"; use reverse-DNS such as io.example.plugin"
        case .unsupportedAPI(let api):
            "requires plugin API \(api); this Alas supports \(PluginManifest.supportedAPIVersions.map(String.init).joined(separator: ", "))"
        case .unknownCapability(let name):
            "unknown capability \"\(name)\""
        case .invalidEntry(let entry):
            "entry \"\(entry)\" must be a relative path inside the plugin folder"
        case .invalidTab(let reason):
            "invalid tab contribution: \(reason)"
        case let .capabilityNeedsNewerAPI(name, api):
            "capability \"\(name)\" requires plugin API \(api); set \"api\": \(api) in plugin.json"
        }
    }
}

/// `plugin.json`. Unknown fields are ignored so newer manifests still load.
struct PluginManifest: Equatable, Sendable {
    static let supportedAPIVersions = [1, 2, 3]
    static let maxTabs = 4
    static let maxTabTitleLength = 40

    let id: String
    let name: String
    let version: String
    let api: Int
    let entry: String
    let capabilities: [PluginCapability]
    var tabs: [PluginTabContribution] = []

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
        var capabilities: [PluginCapability] = []
        for name in raw.capabilities ?? [] {
            guard let capability = PluginCapability(rawValue: name) else { throw .unknownCapability(name) }
            // An API 1 manifest must stay loadable by an API 1-only Alas, which rejects newer capabilities.
            guard api >= capability.minimumAPI else { throw .capabilityNeedsNewerAPI(name, capability.minimumAPI) }
            capabilities.append(capability)
        }
        guard !entry.hasPrefix("/"), !entry.split(separator: "/").contains("..") else {
            throw .invalidEntry(entry)
        }
        // `contributes` is inert before API 2, so older manifests are not validated against it.
        if api >= 2, raw.contributesMalformed { throw .malformed }
        let tabs = api >= 2 ? try parseTabs(raw.contributes?.tabs ?? [], api: api) : []
        return PluginManifest(
            id: id, name: name, version: version, api: api, entry: entry,
            capabilities: capabilities, tabs: tabs)
    }

    private static func parseTabs(_ raw: [Raw.RawTab], api: Int) throws(PluginManifestError) -> [PluginTabContribution] {
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
                guard api >= 3 else { throw .invalidTab("tab \"\(id)\" sets kind, which requires plugin API 3") }
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
    struct RawContributes: Decodable {
        let tabs: [RawTab]?
    }

    let id: String?
    let name: String?
    let version: String?
    let api: Int?
    let entry: String?
    let capabilities: [String]?
    let contributes: RawContributes?
    let contributesMalformed: Bool

    private enum CodingKeys: String, CodingKey { case id, name, version, api, entry, capabilities, contributes }

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
        // Lenient here so API 1 keeps ignoring `contributes`; `parse` rejects a malformed one for API 2.
        contributes = (try? container.decodeIfPresent(RawContributes.self, forKey: .contributes)) ?? nil
        contributesMalformed = contributes == nil && container.contains(.contributes)
            && !((try? container.decodeNil(forKey: .contributes)) ?? false)
    }
}
