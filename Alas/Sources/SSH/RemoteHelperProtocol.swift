import Foundation

enum RemoteHelperProtocolVersion {
    static let current = 1
}

struct RemoteHelperHelloParams: Codable, Equatable, Sendable {
    let clientName: String
    let protocolVersion: Int

    init(clientName: String = "Alas", protocolVersion: Int = RemoteHelperProtocolVersion.current) {
        self.clientName = clientName
        self.protocolVersion = protocolVersion
    }
}

struct RemoteHelperHelloResult: Codable, Equatable, Sendable {
    let name: String
    let protocolVersion: Int
    let binaryVersion: String
    let capabilities: RemoteHelperCapabilities
}

struct RemoteHelperCapabilities: Codable, Equatable, Sendable {
    let watchKinds: [RemoteHelperWatchKind]
    let fs: RemoteHelperFSCapabilities
    let search: Bool?
    let proc: Bool?
    let ping: Bool
}

struct RemoteHelperFSCapabilities: Codable, Equatable, Sendable {
    let read: Bool
    let write: Bool
    let stat: Bool
    let lineCounts: Bool?
    let list: Bool?
}

enum RemoteHelperWatchKind: String, Codable, Equatable, Sendable {
    case files
    case git
}

struct RemoteHelperPingResult: Codable, Equatable, Sendable {
    let ok: Bool
}

struct RemoteHelperWatchSubscribeParams: Codable, Equatable, Sendable {
    let root: String
    let kinds: [RemoteHelperWatchKind]
}

struct RemoteHelperWatchSubscribeResult: Codable, Equatable, Sendable {
    let subscriptionId: String
}

struct RemoteHelperWatchUnsubscribeParams: Codable, Equatable, Sendable {
    let subscriptionId: String
}

struct RemoteHelperWatchUnsubscribeResult: Codable, Equatable, Sendable {
    let ok: Bool
}

struct RemoteHelperWatchEvent: Codable, Equatable, Sendable {
    let subscriptionId: String
    let root: String
    let kind: RemoteHelperWatchKind
    let paths: [String]
}

enum RemoteHelperWatchUpdate: Equatable, Sendable {
    case available
    case unavailable
    case event(RemoteHelperWatchEvent)
}

struct RemoteHelperWatchHandle: Sendable {
    let subscriptionId: String
    let updates: AsyncStream<RemoteHelperWatchUpdate>
}

struct RemoteHelperFSReadParams: Codable, Equatable, Sendable {
    let path: String
    let offset: UInt64?

    init(path: String, offset: UInt64? = nil) {
        self.path = path
        self.offset = offset
    }
}

struct RemoteHelperFSReadResult: Codable, Equatable, Sendable {
    let kind: String?
    let content: String?
    let contentBase64: String?
    let mtime: Double?
    let detail: String?
}

struct RemoteHelperFSWriteParams: Codable, Equatable, Sendable {
    let path: String
    let content: String
    let expectedMtime: Double?
    let expectedContent: String?

    init(path: String, content: String, expectedMtime: Double? = nil, expectedContent: String? = nil) {
        self.path = path
        self.content = content
        self.expectedMtime = expectedMtime
        self.expectedContent = expectedContent
    }
}

struct RemoteHelperFSWriteResult: Codable, Equatable, Sendable {
    let mtime: Double?
}

struct RemoteHelperFSStatParams: Codable, Equatable, Sendable {
    let paths: [String]
}

struct RemoteHelperFSStatResult: Codable, Equatable, Sendable {
    let entries: [RemoteHelperFSStatEntry]
}

struct RemoteHelperFSStatEntry: Codable, Equatable, Sendable {
    let path: String
    let exists: Bool
    let isDirectory: Bool
    let isFile: Bool
    let size: UInt64?
    let mtime: Double?
}

struct RemoteHelperFSLineCountsParams: Codable, Equatable, Sendable {
    let root: String
    let paths: [String]
}

struct RemoteHelperFSLineCountsResult: Codable, Equatable, Sendable {
    let entries: [RemoteHelperFSLineCountEntry]
}

struct RemoteHelperFSLineCountEntry: Codable, Equatable, Sendable {
    let path: String
    let lineCount: Int
}

struct RemoteHelperFSListParams: Codable, Equatable, Sendable {
    let path: String
}

struct RemoteHelperFSListResult: Codable, Equatable, Sendable {
    let entries: [RemoteHelperFSListEntry]
}

struct RemoteHelperFSListEntry: Codable, Equatable, Sendable {
    let name: String
    let isDirectory: Bool
}

struct RemoteHelperSearchStartParams: Codable, Equatable, Sendable {
    let root: String
    let query: String
    let caseSensitive: Bool
    let wholeWord: Bool
    let regex: Bool
}

struct RemoteHelperSearchStartResult: Codable, Equatable, Sendable {
    let searchId: String
}

struct RemoteHelperSearchCancelParams: Codable, Equatable, Sendable {
    let searchId: String
}

struct RemoteHelperSearchCancelResult: Codable, Equatable, Sendable {
    let ok: Bool
}

struct RemoteHelperSearchEventParams: Codable, Equatable, Sendable {
    let searchId: String
    let line: String
}

struct RemoteHelperSearchCompleteParams: Codable, Equatable, Sendable {
    let searchId: String
    let exitCode: Int32
    let stderr: String
    let cancelled: Bool
}

enum RemoteHelperSearchEvent: Equatable, Sendable {
    case line(String)
    case complete(exitCode: Int32, stderr: String, cancelled: Bool)
}

struct RemoteHelperSearchHandle: Sendable {
    let searchId: String
    let events: AsyncThrowingStream<RemoteHelperSearchEvent, Error>
}

struct RemoteHelperProcSpawnParams: Codable, Equatable, Sendable {
    let procId: String
    let command: String
    let args: [String]
    let cwd: String
    let env: [String: String]
}

struct RemoteHelperProcStatus: Codable, Equatable, Sendable {
    let procId: String
    let running: Bool
    let exitCode: Int32?
}

struct RemoteHelperProcAttachParams: Codable, Equatable, Sendable {
    let procId: String
    let stdoutOffset: UInt64?
    let stderrOffset: UInt64?
}

struct RemoteHelperProcReplayFrame: Codable, Equatable, Sendable {
    let offset: UInt64
    let dataBase64: String
}

struct RemoteHelperProcAttachResult: Codable, Equatable, Sendable {
    let procId: String
    let running: Bool
    let exitCode: Int32?
    let stdoutOffset: UInt64
    let stderrOffset: UInt64
    let stdoutFrames: [RemoteHelperProcReplayFrame]
    let stderrChunks: [RemoteHelperProcReplayFrame]
}

struct RemoteHelperProcWriteParams: Codable, Equatable, Sendable {
    let procId: String
    let dataBase64: String
    let expectedStdinOffset: UInt64?
}

struct RemoteHelperProcWriteResult: Codable, Equatable, Sendable {
    let ok: Bool
    let stdinOffset: UInt64
}

struct RemoteHelperProcKillParams: Codable, Equatable, Sendable {
    let procId: String
}

struct RemoteHelperProcKillResult: Codable, Equatable, Sendable {
    let ok: Bool
}

struct RemoteHelperProcListResult: Codable, Equatable, Sendable {
    let entries: [RemoteHelperProcStatus]
}

struct RemoteHelperProcOutputParams: Codable, Equatable, Sendable {
    let procId: String
    let stream: String
    let offset: UInt64
    let dataBase64: String
}

struct RemoteHelperProcExitParams: Codable, Equatable, Sendable {
    let procId: String
    let exitCode: Int32?
}

enum RemoteHelperProcEvent: Equatable, Sendable {
    case available
    case unavailable
    case stdout(Data, offset: UInt64)
    case stderr(Data, offset: UInt64)
    case exited(Int32?)
}

struct RemoteHelperProcAttachHandle: Sendable {
    let procId: String
    let events: AsyncStream<RemoteHelperProcEvent>
}
