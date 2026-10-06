import Foundation

/// One entry of the official ACP agent registry
/// (`https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json`).
/// Only the fields Alas reads are decoded; the `preview` channel is ignored.
struct ACPRegistryAgent: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let version: String
    let description: String
    let website: String?
    let repository: String?
    let distribution: Distribution

    struct Distribution: Decodable, Equatable, Sendable {
        /// Keyed by platform (`darwin-aarch64`, `linux-x86_64`, …).
        let binary: [String: BinaryTarget]?
        let npx: Package?
        let uvx: Package?
    }

    struct BinaryTarget: Decodable, Equatable, Sendable {
        let archive: URL
        let sha256: String?
        /// Path of the executable relative to the extracted archive.
        let cmd: String
        let args: [String]?
        let env: [String: String]?
    }

    struct Package: Decodable, Equatable, Sendable {
        /// Package spec, optionally versioned (`@scope/name@1.2.3`).
        let package: String
        let args: [String]?
        let env: [String: String]?
    }

    /// How Alas installs this agent on `platform`. Prefers the native binary
    /// (no runtime dependency), then npm, then uv. Nil when the registry
    /// offers nothing runnable on this Mac.
    func installPlan(platform: String = ACPRegistryPlatform.current) -> ACPRegistryInstallPlan? {
        if let target = distribution.binary?[platform] { return .binary(target) }
        if let npx = distribution.npx { return .npm(npx) }
        if let uvx = distribution.uvx { return .uvx(uvx) }
        return nil
    }

    func matches(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(trimmed)
            || id.localizedCaseInsensitiveContains(trimmed)
            || description.localizedCaseInsensitiveContains(trimmed)
    }
}

enum ACPRegistryInstallPlan: Equatable, Sendable {
    case binary(ACPRegistryAgent.BinaryTarget)
    case npm(ACPRegistryAgent.Package)
    case uvx(ACPRegistryAgent.Package)

    var label: String {
        switch self {
        case .binary: return "binary"
        case .npm: return "npm"
        case .uvx: return "uv"
        }
    }
}

enum ACPRegistryPlatform {
    static var current: String {
        #if arch(arm64)
        return "darwin-aarch64"
        #else
        return "darwin-x86_64"
        #endif
    }
}

/// The registry document. Entries that fail to decode are dropped so one
/// malformed agent cannot hide the rest of the registry.
struct ACPRegistryIndex: Decodable, Equatable, Sendable {
    let agents: [ACPRegistryAgent]

    private enum CodingKeys: String, CodingKey { case agents }

    private struct LossyAgent: Decodable {
        let agent: ACPRegistryAgent?
        init(from decoder: Decoder) throws {
            agent = try? ACPRegistryAgent(from: decoder)
        }
    }

    init(agents: [ACPRegistryAgent]) {
        self.agents = agents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agents = try container.decode([LossyAgent].self, forKey: .agents).compactMap(\.agent)
    }
}

/// Registry agents Alas already ships as curated built-ins. The curated
/// launch specs and installers stay the defaults for these, so the registry
/// browser shows them as built in instead of offering a second install.
enum ACPRegistryCuratedAgents {
    static let builtinIDByRegistryID: [String: String] = [
        "claude-acp": "claude",
        "codex-acp": "codex",
        "pi-acp": "pi",
        "gemini": "gemini",
        "opencode": "opencode",
        "cursor": "cursor-agent",
        "github-copilot-cli": "copilot",
        "antigravity-acp": "antigravity",
    ]
}

/// What the registry browser offers for one entry.
enum ACPRegistryEntryStatus: Equatable {
    case builtin(agentID: String)
    case unsupported
    case notInstalled
    case installed
    case updateAvailable(installedVersion: String)

    static func resolve(
        agent: ACPRegistryAgent,
        installed: [ACPRegistryInstalledAgent],
        platform: String = ACPRegistryPlatform.current
    ) -> ACPRegistryEntryStatus {
        if let builtinID = ACPRegistryCuratedAgents.builtinIDByRegistryID[agent.id] {
            return .builtin(agentID: builtinID)
        }
        if let record = installed.first(where: { $0.registryID == agent.id }) {
            guard record.version != agent.version, agent.installPlan(platform: platform) != nil else {
                return .installed
            }
            return .updateAvailable(installedVersion: record.version)
        }
        return agent.installPlan(platform: platform) == nil ? .unsupported : .notInstalled
    }
}
