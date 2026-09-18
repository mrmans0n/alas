import Foundation

enum AgentRunError: LocalizedError, Equatable {
    /// Spawned binary couldn't be found on PATH (or via `binaryOverride`).
    /// `agentId` identifies the agent for tests / future telemetry;
    /// `displayName` is what the user message shows.
    case binaryNotFound(agentId: String, displayName: String, host: String? = nil)
    case sshConnectionFailed(host: String, message: String)
    case missingRemoteWorkingDirectory(host: String)
    case nonZeroExit(stderr: String, exitCode: Int32)
    case timedOut(seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(_, let displayName, let host):
            if let host {
                return "Agent CLI not found on \(host) PATH: \(displayName)"
            }
            return "Agent CLI not found on PATH: \(displayName)"
        case .sshConnectionFailed(let host, let message):
            return "SSH connection to \(host) failed: \(message)"
        case .missingRemoteWorkingDirectory(let host):
            return "A remote working directory is required for \(host)"
        case .nonZeroExit(let stderr, _):
            let first = stderr
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first
                .map(String.init) ?? "Agent CLI exited with an error"
            return first
        case .timedOut(let s):
            return "Timed out after \(Int(s))s"
        }
    }
}
