import Foundation

enum AgentRunError: LocalizedError {
    /// Spawned binary couldn't be found on PATH (or via `binaryOverride`).
    /// `agentId` identifies the agent for tests / future telemetry;
    /// `displayName` is what the user message shows.
    case binaryNotFound(agentId: String, displayName: String)
    case nonZeroExit(stderr: String, exitCode: Int32)
    case timedOut(seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(_, let displayName):
            return "Agent CLI not found on PATH: \(displayName)"
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
