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

    init(path: String, content: String, expectedMtime: Double? = nil) {
        self.path = path
        self.content = content
        self.expectedMtime = expectedMtime
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
