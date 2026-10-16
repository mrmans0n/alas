import Foundation

/// Per-session state of the built-in Alas MCP server that has to survive an
/// app restart, because an agent kept alive in its broker outlives the app
/// and keeps the MCP configuration it was started with.
///
/// - The HTTP endpoint (port and bearer token) lets the supervisor bring the
///   server back at the address the surviving agent already has.
/// - The agent record says which built-in server a broker generation's agent
///   was given, so an attach that adopts that agent can tell whether it still
///   reaches the server this attach would configure.
///
/// One owner-only JSON file per session and kind, so separate sessions (and a
/// second app instance) never rewrite each other's records. With no directory
/// the state lives in memory only.
@MainActor
public final class BuiltInMCPSessionState {
    public struct HTTPEndpoint: Codable, Equatable, Sendable {
        public let port: Int
        public let token: String

        public init(port: Int, token: String) {
            self.port = port
            self.token = token
        }
    }

    public struct AgentRecord: Codable, Equatable, Sendable {
        public let brokerGeneration: ACPBrokerGeneration
        /// `BuiltInAlasMCP.agentFingerprint` of the server the agent was given.
        public let fingerprint: String

        public init(brokerGeneration: ACPBrokerGeneration, fingerprint: String) {
            self.brokerGeneration = brokerGeneration
            self.fingerprint = fingerprint
        }
    }

    private enum Kind: String, CaseIterable {
        case httpEndpoint = "http"
        case agent
    }

    private let directory: URL?
    private var memory: [String: Data] = [:]

    public init(directory: URL? = nil) {
        self.directory = directory
    }

    public func httpEndpoint(sessionId: String) -> HTTPEndpoint? {
        read(HTTPEndpoint.self, kind: .httpEndpoint, sessionId: sessionId)
    }

    public func setHTTPEndpoint(_ endpoint: HTTPEndpoint, sessionId: String) {
        write(endpoint, kind: .httpEndpoint, sessionId: sessionId)
    }

    public func agentRecord(sessionId: String) -> AgentRecord? {
        read(AgentRecord.self, kind: .agent, sessionId: sessionId)
    }

    public func setAgentRecord(_ record: AgentRecord?, sessionId: String) {
        if let record {
            write(record, kind: .agent, sessionId: sessionId)
        } else {
            remove(kind: .agent, sessionId: sessionId)
        }
    }

    /// Drops every record of a session that no longer exists.
    public func forget(sessionId: String) {
        for kind in Kind.allCases {
            remove(kind: kind, sessionId: sessionId)
        }
    }

    private func key(kind: Kind, sessionId: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let sanitized = String(sessionId.map { allowed.contains($0) ? $0 : "_" })
        return "\(sanitized).\(kind.rawValue).json"
    }

    private func read<Value: Decodable>(_ type: Value.Type, kind: Kind, sessionId: String) -> Value? {
        let name = key(kind: kind, sessionId: sessionId)
        let data: Data?
        if let directory {
            data = try? Data(contentsOf: directory.appendingPathComponent(name))
        } else {
            data = memory[name]
        }
        return data.flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private func write(_ value: some Encodable, kind: Kind, sessionId: String) {
        let name = key(kind: kind, sessionId: sessionId)
        guard let data = try? JSONEncoder().encode(value) else { return }
        guard let directory else {
            memory[name] = data
            return
        }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let target = directory.appendingPathComponent(name)
            let staging = directory.appendingPathComponent(".\(name).\(UUID().uuidString.prefix(8))")
            guard fileManager.createFile(
                atPath: staging.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else { return }
            if rename(staging.path, target.path) != 0 {
                try? fileManager.removeItem(at: staging)
            }
        } catch {
            return
        }
    }

    private func remove(kind: Kind, sessionId: String) {
        let name = key(kind: kind, sessionId: sessionId)
        guard let directory else {
            memory[name] = nil
            return
        }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
}
