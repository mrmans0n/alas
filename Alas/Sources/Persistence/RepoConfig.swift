import Foundation

/// Repo-local, team-shared Alas configuration decoded (read-only) from
/// `.alas/config.json`. See docs/plans/2026-09-17-repo-local-config-design.md.
struct RepoConfig: Equatable {
    static let currentVersion = 1
    static let relativePath = ".alas/config.json"

    struct Icon: Equatable {
        /// Image path relative to `.alas/`.
        var image: String
    }

    var icon: Icon?
    var defaultAgent: String?
    /// Servers get deterministic `repo:<name>` ids so a repo edit keeps
    /// identity across loads — the trust-hash flow depends on it.
    var mcpServers: [ProjectMCPServer]

    var isEmpty: Bool { icon == nil && defaultAgent == nil && mcpServers.isEmpty }

    init(icon: Icon? = nil, defaultAgent: String? = nil, mcpServers: [ProjectMCPServer] = []) {
        self.icon = icon
        self.defaultAgent = defaultAgent
        self.mcpServers = mcpServers
    }

    private struct Wire: Decodable {
        var version: Int
        var icon: Icon?
        var defaultAgent: String?
        var mcpServers: [TolerantServer]?

        struct Icon: Decodable { var image: String? }

        struct Server: Decodable {
            var name: String
            var transport: ProjectMCPTransport
        }

        /// A malformed entry must not sink the whole file.
        struct TolerantServer: Decodable {
            let server: Server?
            init(from decoder: Decoder) throws {
                server = try? Server(from: decoder)
            }
        }
    }

    /// Tolerant decode: wrong shape or version yields nil (file treated as
    /// absent); bad individual entries are skipped; unknown keys are ignored.
    init?(jsonData: Data) {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: jsonData),
              wire.version == Self.currentVersion
        else { return nil }

        if let image = wire.icon?.image?.trimmingCharacters(in: .whitespacesAndNewlines), !image.isEmpty {
            icon = Icon(image: image)
        }
        let agent = wire.defaultAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
        defaultAgent = agent.flatMap { $0.isEmpty ? nil : $0 }

        var seen = Set<String>()
        mcpServers = (wire.mcpServers ?? []).compactMap { entry in
            guard let server = entry.server else { return nil }
            let name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return ProjectMCPServer(id: "repo:\(name)", name: name, transport: server.transport)
        }
    }
}
