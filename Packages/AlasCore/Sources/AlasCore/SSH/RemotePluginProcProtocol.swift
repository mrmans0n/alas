import Foundation

// MARK: - Helper messages (`pproc/*`)

public struct RemotePluginProcSpawnParams: Encodable, Sendable {
    public let procId: String
    public let lease: String
    /// Exactly the argv to run; the helper starts it without a shell.
    public let argv: [String]
    /// The worktree's real path on the host.
    public let cwd: String
    public let longRunning: Bool
    public let stdinBase64: String?
    /// stdout and stderr together, kept by the helper.
    public let outputLimit: Int
    public let leaseMs: Int
    public let timeoutMs: Int?

    public init(procId: String, lease: String, argv: [String], cwd: String, longRunning: Bool, stdinBase64: String?, outputLimit: Int, leaseMs: Int, timeoutMs: Int?) {
        self.procId = procId
        self.lease = lease
        self.argv = argv
        self.cwd = cwd
        self.longRunning = longRunning
        self.stdinBase64 = stdinBase64
        self.outputLimit = outputLimit
        self.leaseMs = leaseMs
        self.timeoutMs = timeoutMs
    }
}

public struct RemotePluginProcOwnedParams: Encodable, Sendable {
    public let procId: String
    public let lease: String
    public var offset: UInt64?
    public var leaseMs: Int?

    public init(procId: String, lease: String, offset: UInt64? = nil, leaseMs: Int? = nil) {
        self.procId = procId
        self.lease = lease
        self.offset = offset
        self.leaseMs = leaseMs
    }
}

public struct RemotePluginProcOK: Decodable, Sendable {
    public init() {
    }}

/// A run of one stream's output, at a logical offset over both streams.
public struct RemotePluginProcChunk: Codable, Equatable, Sendable {
    /// Set on notifications only.
    public var procId: String?
    public let seq: UInt64
    public let stream: String
    public let offset: UInt64
    public let dataBase64: String

    public init(procId: String? = nil, seq: UInt64, stream: String, offset: UInt64, dataBase64: String) {
        self.procId = procId
        self.seq = seq
        self.stream = stream
        self.offset = offset
        self.dataBase64 = dataBase64
    }
}

public struct RemotePluginProcAttachResult: Decodable, Sendable {
    public let running: Bool
    public let truncated: Bool
    public let chunks: [RemotePluginProcChunk]
    public let exit: Int32?
    public let timedOut: Bool?

    public init(running: Bool, truncated: Bool, chunks: [RemotePluginProcChunk], exit: Int32?, timedOut: Bool?) {
        self.running = running
        self.truncated = truncated
        self.chunks = chunks
        self.exit = exit
        self.timedOut = timedOut
    }
}

public struct RemotePluginProcExit: Codable, Equatable, Sendable {
    public let procId: String
    public let exit: Int32
    public let timedOut: Bool
    public let truncated: Bool

    public init(procId: String, exit: Int32, timedOut: Bool, truncated: Bool) {
        self.procId = procId
        self.exit = exit
        self.timedOut = timedOut
        self.truncated = truncated
    }
}

public enum RemotePluginProcEvent: Sendable {
    case output(RemotePluginProcChunk)
    case exit(RemotePluginProcExit)
}
