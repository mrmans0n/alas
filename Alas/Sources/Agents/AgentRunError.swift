import Foundation

enum AgentRunError: LocalizedError {
    case binaryNotFound(agentId: String)
    case nonZeroExit(stderr: String, exitCode: Int32)
    case timedOut(seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let id):
            return "Agent CLI not found on PATH: \(id)"
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
