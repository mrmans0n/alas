import Foundation

/// Repo-local, team-shared Alas configuration decoded (read-only) from
/// `.alas/config.json`. See docs/plans/2026-09-17-repo-local-config-design.md.
struct RepoConfig: Equatable {
    static let currentVersion = 1
    static let relativePath = ".alas/config.json"

    struct Icon: Equatable, Decodable {
        /// Image path relative to `.alas/`.
        var image: String
    }

    var icon: Icon?
    var defaultAgent: String?
    /// Servers get deterministic `repo:<name>` ids, so a server keeps its
    /// status identity across reloads. The trust-hash flow depends on the
    /// config, not this id; the presentation layer keys off the prefix.
    var mcpServers: [ProjectMCPServer]

    static let repoServerIDPrefix = "repo:"

    var isEmpty: Bool { icon == nil && defaultAgent == nil && mcpServers.isEmpty }

    init(icon: Icon? = nil, defaultAgent: String? = nil, mcpServers: [ProjectMCPServer] = []) {
        self.icon = icon
        self.defaultAgent = defaultAgent
        self.mcpServers = mcpServers
    }

    private enum CodingKeys: String, CodingKey {
        case icon, defaultAgent, mcpServers
    }

    private struct VersionProbe: Decodable {
        var version: Int
    }

    /// Holds the raw keyed container so each key can be decoded on its own.
    private struct RawContainer: Decodable {
        let container: KeyedDecodingContainer<CodingKeys>

        init(from decoder: Decoder) throws {
            container = try decoder.container(keyedBy: CodingKeys.self)
        }
    }

    private struct Server: Decodable {
        var name: String
        var transport: ProjectMCPTransport
    }

    /// A malformed entry must not sink the whole file.
    private struct TolerantServer: Decodable {
        let server: Server?

        init(from decoder: Decoder) throws {
            server = try? Server(from: decoder)
        }
    }

    /// Tolerant decode: unparseable JSON, a missing/non-integer `version`, or a
    /// version mismatch yields nil (file treated as absent). Every other key is
    /// decoded on its own, so a type error in one key only drops that key and
    /// repo config can never break project display. Unknown keys are ignored.
    init?(jsonData: Data) {
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(VersionProbe.self, from: jsonData),
              probe.version == Self.currentVersion,
              let raw = try? decoder.decode(RawContainer.self, from: jsonData)
        else { return nil }

        let rawIcon = (try? raw.container.decodeIfPresent(Icon.self, forKey: .icon)) ?? nil
        if let image = rawIcon.flatMap({ Self.sanitizedIconPath($0.image) }) {
            icon = Icon(image: image)
        }

        let rawAgent = (try? raw.container.decodeIfPresent(String.self, forKey: .defaultAgent)) ?? nil
        let agent = rawAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
        defaultAgent = agent.flatMap { $0.isEmpty ? nil : $0 }

        let entries = (try? raw.container.decodeIfPresent([TolerantServer].self, forKey: .mcpServers)) ?? nil
        var seen = Set<String>()
        mcpServers = (entries ?? []).compactMap { entry in
            guard let server = entry.server else { return nil }
            let name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return ProjectMCPServer(
                id: Self.repoServerIDPrefix + name,
                name: name,
                transport: server.transport
            )
        }
    }

    /// Icon paths are resolved against `<checkout>/.alas/`, so absolute paths
    /// and `..` components are rejected rather than allowed to escape the
    /// repo. A rejected path just drops the icon. `RepoIconResolver` applies
    /// the same rule to hand-built configs that skipped decoding.
    static func sanitizedIconPath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains("..") else { return nil }
        return trimmed
    }
}
