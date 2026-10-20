import Foundation
import AlasFoundation

/// One entry of the official ACP agent registry
/// (`https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json`).
/// Only the fields Alas reads are decoded; the `preview` channel is ignored.
public struct ACPRegistryAgent: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let description: String
    public let website: String?
    public let repository: String?
    public let distribution: Distribution

    public struct Distribution: Decodable, Equatable, Sendable {
        /// Keyed by platform (`darwin-aarch64`, `linux-x86_64`, …).
        public let binary: [String: BinaryTarget]?
        public let npx: Package?
        public let uvx: Package?

        public init(binary: [String: BinaryTarget]?, npx: Package?, uvx: Package?) {
            self.binary = binary
            self.npx = npx
            self.uvx = uvx
        }
    }

    public struct BinaryTarget: Decodable, Equatable, Sendable {
        public let archive: URL
        public let sha256: String?
        /// Path of the executable relative to the extracted archive.
        public let cmd: String
        public let args: [String]?
        public let env: [String: String]?

        public init(archive: URL, sha256: String?, cmd: String, args: [String]?, env: [String: String]?) {
            self.archive = archive
            self.sha256 = sha256
            self.cmd = cmd
            self.args = args
            self.env = env
        }
    }

    public struct Package: Decodable, Equatable, Sendable {
        /// Package spec, optionally versioned (`@scope/name@1.2.3`).
        public let package: String
        public let args: [String]?
        public let env: [String: String]?

        public init(package: String, args: [String]?, env: [String: String]?) {
            self.package = package
            self.args = args
            self.env = env
        }
    }

    /// How Alas installs this agent on `platform`. Prefers the native binary
    /// (no runtime dependency), then npm, then uv. Nil when the registry
    /// offers nothing runnable on this Mac.
    public func installPlan(platform: String = ACPRegistryPlatform.current) -> ACPRegistryInstallPlan? {
        if let target = distribution.binary?[platform] { return .binary(target) }
        if let npx = distribution.npx { return .npm(npx) }
        if let uvx = distribution.uvx { return .uvx(uvx) }
        return nil
    }

    public func matches(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(trimmed)
            || id.localizedCaseInsensitiveContains(trimmed)
            || description.localizedCaseInsensitiveContains(trimmed)
    }

    public init(id: String, name: String, version: String, description: String, website: String?, repository: String?, distribution: Distribution) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.website = website
        self.repository = repository
        self.distribution = distribution
    }
}

public enum ACPRegistryInstallPlan: Equatable, Sendable {
    case binary(ACPRegistryAgent.BinaryTarget)
    case npm(ACPRegistryAgent.Package)
    case uvx(ACPRegistryAgent.Package)

    public var label: String {
        switch self {
        case .binary: return "binary"
        case .npm: return "npm"
        case .uvx: return "uv"
        }
    }
}

public enum ACPRegistryPlatform: Sendable {
    public static var current: String {
        #if arch(arm64)
        return "darwin-aarch64"
        #else
        return "darwin-x86_64"
        #endif
    }
}

/// The registry document. Entries that fail to decode are dropped so one
/// malformed agent cannot hide the rest of the registry.
public struct ACPRegistryIndex: Decodable, Equatable, Sendable {
    public let agents: [ACPRegistryAgent]

    private enum CodingKeys: String, CodingKey { case agents }

    private struct LossyAgent: Decodable {
        let agent: ACPRegistryAgent?
        init(from decoder: Decoder) throws {
            agent = try? ACPRegistryAgent(from: decoder)
        }
    }

    public init(agents: [ACPRegistryAgent]) {
        self.agents = agents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agents = try container.decode([LossyAgent].self, forKey: .agents).compactMap(\.agent)
    }
}

/// Registry agents Alas already ships as curated built-ins. The curated
/// launch specs and installers stay the defaults for these, so the registry
/// browser shows them as built in instead of offering a second install.
public enum ACPRegistryCuratedAgents: Sendable {
    public static let builtinIDByRegistryID: [String: String] = [
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
public enum ACPRegistryEntryStatus: Equatable, Sendable {
    case builtin(agentID: String)
    case unsupported
    case notInstalled
    case installed
    case updateAvailable(installedVersion: String)

    public static func resolve(
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
