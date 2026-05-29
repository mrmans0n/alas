import Foundation

struct ACPEnvVar: Codable, Equatable {
    let name: String
    let value: String
}

struct ACPTerminalCreateParams: Codable, Equatable {
    let sessionId: String
    let command: String
    let args: [String]?
    let env: [ACPEnvVar]?
    let cwd: String?
    let outputByteLimit: Int?
}

struct ACPTerminalCreateResult: Codable, Equatable {
    let terminalId: String
}

struct ACPTerminalOutputParams: Codable, Equatable {
    let sessionId: String
    let terminalId: String
}

struct ACPTerminalOutputResult: Codable, Equatable {
    let output: String
    let truncated: Bool
    let exitStatus: ACPTerminalExitStatus?
}

struct ACPTerminalExitStatus: Codable, Equatable {
    let exitCode: Int?
    let signal: String?
}

struct ACPTerminalIdParams: Codable, Equatable {
    let sessionId: String
    let terminalId: String
}

// `terminal/wait_for_exit` returns the exit status object itself
// (`{ exitCode, signal }`) — ACP spec WaitForTerminalExitResponse. The
// host method therefore returns `ACPTerminalExitStatus` directly; no
// wrapper type.

enum ACPTerminalRequest {
    case create(id: JSONRPCID, params: ACPTerminalCreateParams)
    case output(id: JSONRPCID, params: ACPTerminalOutputParams)
    case waitForExit(id: JSONRPCID, params: ACPTerminalIdParams)
    case kill(id: JSONRPCID, params: ACPTerminalIdParams)
    case release(id: JSONRPCID, params: ACPTerminalIdParams)
}
