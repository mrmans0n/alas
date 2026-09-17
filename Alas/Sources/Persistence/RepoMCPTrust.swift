import Foundation

/// Per-user decision about an MCP server a repo wants to attach. Trust is
/// keyed by a hash of the server's canonical config, so editing the server
/// in the repo re-prompts, and the same config stays approved across
/// branches.
enum RepoMCPTrustState: String, Codable, Equatable {
    case approved
    case declined
}

enum RepoMCPTrust {
    /// Stable hash of one repo server's canonical config (name + transport).
    /// Reuses the attachment fingerprint's canonical encoding, so identical
    /// configs hash identically regardless of the derived `repo:<name>` id.
    static func hash(for server: ProjectMCPServer) -> String {
        MCPAttachmentPlanner.configurationFingerprint(for: [server])
    }
}
