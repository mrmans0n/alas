import Foundation

/// A session's MCP servers as the Mac's MCP pill shows them (`ACPMCPStatusState`): what Alas
/// asked the agent to attach when the session started, not whether each server is up.
public struct RemoteMCPStatus: Codable, Equatable, Sendable {
    public struct Server: Codable, Equatable, Sendable {
        public let name: String
        /// "stdio", "HTTP", "Legacy SSE", or what an external adapter runs it through.
        public let transport: String
        /// "Requested", or why it was skipped.
        public let detail: String
        public let requested: Bool

        public init(name: String, transport: String, detail: String, requested: Bool) {
            self.name = name
            self.transport = transport
            self.detail = detail
            self.requested = requested
        }
    }

    public let requested: Int
    public let skipped: Int
    /// What is wrong with Alas's own server, when something is.
    public let warning: String?
    public let servers: [Server]

    public init(requested: Int, skipped: Int, warning: String?, servers: [Server]) {
        self.requested = requested
        self.skipped = skipped
        self.warning = warning
        self.servers = servers
    }

    /// The pill's warning mark.
    public var needsAttention: Bool { skipped > 0 || warning != nil }
}
