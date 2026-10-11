import Foundation

public struct ACPEnvVar: Codable, Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct ACPTerminalCreateParams: Codable, Equatable, Sendable {
    public let sessionId: String
    public let command: String
    public let args: [String]?
    public let env: [ACPEnvVar]?
    public let cwd: String?
    public let outputByteLimit: Int?

    public init(sessionId: String, command: String, args: [String]?, env: [ACPEnvVar]?, cwd: String?, outputByteLimit: Int?) {
        self.sessionId = sessionId
        self.command = command
        self.args = args
        self.env = env
        self.cwd = cwd
        self.outputByteLimit = outputByteLimit
    }
}

public struct ACPTerminalCreateResult: Codable, Equatable, Sendable {
    public let terminalId: String

    public init(terminalId: String) {
        self.terminalId = terminalId
    }
}

public struct ACPTerminalOutputParams: Codable, Equatable, Sendable {
    public let sessionId: String
    public let terminalId: String

    public init(sessionId: String, terminalId: String) {
        self.sessionId = sessionId
        self.terminalId = terminalId
    }
}

public struct ACPTerminalOutputResult: Codable, Equatable, Sendable {
    public let output: String
    public let truncated: Bool
    public let exitStatus: ACPTerminalExitStatus?

    public init(output: String, truncated: Bool, exitStatus: ACPTerminalExitStatus?) {
        self.output = output
        self.truncated = truncated
        self.exitStatus = exitStatus
    }
}

public struct ACPTerminalExitStatus: Codable, Equatable, Sendable {
    public let exitCode: Int?
    public let signal: String?

    public init(exitCode: Int?, signal: String?) {
        self.exitCode = exitCode
        self.signal = signal
    }
}

public struct ACPTerminalIdParams: Codable, Equatable, Sendable {
    public let sessionId: String
    public let terminalId: String

    public init(sessionId: String, terminalId: String) {
        self.sessionId = sessionId
        self.terminalId = terminalId
    }
}

// `terminal/wait_for_exit` returns the exit status object itself
// (`{ exitCode, signal }`) — ACP spec WaitForTerminalExitResponse. The
// host method therefore returns `ACPTerminalExitStatus` directly; no
// wrapper type.

public enum ACPTerminalRequest: Sendable {
    case create(id: JSONRPCID, params: ACPTerminalCreateParams)
    case output(id: JSONRPCID, params: ACPTerminalOutputParams)
    case waitForExit(id: JSONRPCID, params: ACPTerminalIdParams)
    case kill(id: JSONRPCID, params: ACPTerminalIdParams)
    case release(id: JSONRPCID, params: ACPTerminalIdParams)
}
