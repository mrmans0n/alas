import Foundation

enum PluginCapability: String, Codable, CaseIterable, Sendable, Hashable {
    case workspaceRead = "workspace.read"
    case worktreeSwitch = "worktree.switch"

    /// Plain-language description shown when the user approves a plugin.
    var summary: String {
        switch self {
        case .workspaceRead: "Read this project's worktrees and what their agent sessions are doing"
        case .worktreeSwitch: "Switch the selected worktree"
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
        }
    }
}

/// `plugin.json`. Unknown fields are ignored so newer manifests still load.
struct PluginManifest: Equatable, Sendable {
    static let supportedAPIVersions = [1]

    let id: String
    let name: String
    let version: String
    let api: Int
    let entry: String
    let capabilities: [PluginCapability]

    static func parse(_ data: Data) throws(PluginManifestError) -> PluginManifest {
        struct Raw: Decodable {
            let id: String?
            let name: String?
            let version: String?
            let api: Int?
            let entry: String?
            let capabilities: [String]?
        }
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
            capabilities.append(capability)
        }
        guard !entry.hasPrefix("/"), !entry.split(separator: "/").contains("..") else {
            throw .invalidEntry(entry)
        }
        return PluginManifest(
            id: id, name: name, version: version, api: api, entry: entry, capabilities: capabilities)
    }
}
