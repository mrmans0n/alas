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
    let ping: Bool
}

struct RemoteHelperFSCapabilities: Codable, Equatable, Sendable {
    let read: Bool
    let write: Bool
    let stat: Bool
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

struct RemoteHelperFSReadParams: Codable, Equatable, Sendable {
    let path: String
    let offset: UInt64?

    init(path: String, offset: UInt64? = nil) {
        self.path = path
        self.offset = offset
    }
}

struct RemoteHelperFSReadResult: Codable, Equatable, Sendable {
    let content: String
    let mtime: Double?
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
