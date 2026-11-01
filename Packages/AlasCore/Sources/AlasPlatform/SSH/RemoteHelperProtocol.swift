import Foundation
import AlasFoundation
import AlasModel

public enum RemoteHelperProtocolVersion: Sendable {
    public static let current = 1
}

public struct RemoteHelperHelloParams: Codable, Equatable, Sendable {
    public let clientName: String
    public let protocolVersion: Int

    public init(clientName: String = "Alas", protocolVersion: Int = RemoteHelperProtocolVersion.current) {
        self.clientName = clientName
        self.protocolVersion = protocolVersion
    }
}

public struct RemoteHelperHelloResult: Codable, Equatable, Sendable {
    public let name: String
    public let protocolVersion: Int
    public let binaryVersion: String
    public let capabilities: RemoteHelperCapabilities

    public init(name: String, protocolVersion: Int, binaryVersion: String, capabilities: RemoteHelperCapabilities) {
        self.name = name
        self.protocolVersion = protocolVersion
        self.binaryVersion = binaryVersion
        self.capabilities = capabilities
    }
}

public struct RemoteHelperCapabilities: Codable, Equatable, Sendable {
    public var acpRawFrames: Int? = nil
    public var acpRawReplies: Int? = nil
    public let watchKinds: [RemoteHelperWatchKind]
    public let fs: RemoteHelperFSCapabilities
    public let search: Bool?
    public let proc: Bool?
    public let acp: Bool?
    public let ping: Bool
    public var sessionCoordination: Int? = nil
    /// `1` when the helper relays the visual-only MCP server (`mcp/*`).
    public var visualMCPRelay: Int? = nil
    /// `1` when that relay waits long enough for `pr_create`, so SSH
    /// sessions can also get the PR shepherd tools.
    public var remoteMCPTools: Int? = nil

    public init(watchKinds: [RemoteHelperWatchKind], fs: RemoteHelperFSCapabilities, search: Bool?, proc: Bool?, acp: Bool?, ping: Bool, sessionCoordination: Int? = nil, visualMCPRelay: Int? = nil) {
        self.watchKinds = watchKinds
        self.fs = fs
        self.search = search
        self.proc = proc
        self.acp = acp
        self.ping = ping
        self.sessionCoordination = sessionCoordination
        self.visualMCPRelay = visualMCPRelay
    }
}

public struct RemoteHelperFSCapabilities: Codable, Equatable, Sendable {
    public let read: Bool
    public let write: Bool
    public let stat: Bool
    public let lineCounts: Bool?
    public let list: Bool?

    public init(read: Bool, write: Bool, stat: Bool, lineCounts: Bool?, list: Bool?) {
        self.read = read
        self.write = write
        self.stat = stat
        self.lineCounts = lineCounts
        self.list = list
    }
}

public enum RemoteHelperWatchKind: String, Codable, Equatable, Sendable {
    case files
    case git
}

public struct RemoteHelperPingResult: Codable, Equatable, Sendable {
    public let ok: Bool

    public init(ok: Bool) {
        self.ok = ok
    }
}

public struct RemoteHelperWatchSubscribeParams: Codable, Equatable, Sendable {
    public let root: String
    public let kinds: [RemoteHelperWatchKind]

    public init(root: String, kinds: [RemoteHelperWatchKind]) {
        self.root = root
        self.kinds = kinds
    }
}

public struct RemoteHelperWatchSubscribeResult: Codable, Equatable, Sendable {
    public let subscriptionId: String

    public init(subscriptionId: String) {
        self.subscriptionId = subscriptionId
    }
}

public struct RemoteHelperWatchUnsubscribeParams: Codable, Equatable, Sendable {
    public let subscriptionId: String

    public init(subscriptionId: String) {
        self.subscriptionId = subscriptionId
    }
}

public struct RemoteHelperWatchUnsubscribeResult: Codable, Equatable, Sendable {
    public let ok: Bool

    public init(ok: Bool) {
        self.ok = ok
    }
}

public struct RemoteHelperWatchEvent: Codable, Equatable, Sendable {
    public let subscriptionId: String
    public let root: String
    public let kind: RemoteHelperWatchKind
    public let paths: [String]

    public func virtualized(host: String) -> Self {
        Self(
            subscriptionId: subscriptionId,
            root: remoteHelperVirtualPath(host: host, root),
            kind: kind,
            paths: paths.map { remoteHelperVirtualPath(host: host, $0) }
        )
    }

    public init(subscriptionId: String, root: String, kind: RemoteHelperWatchKind, paths: [String]) {
        self.subscriptionId = subscriptionId
        self.root = root
        self.kind = kind
        self.paths = paths
    }
}

/// Helper responses carry real remote paths; only absolute ones are
/// virtualized (line-count entries echo the caller's relative paths).
private func remoteHelperVirtualPath(host: String, _ path: String) -> String {
    path.hasPrefix("/") ? RemotePath.virtual(host: host, realPath: path) : path
}

public enum RemoteHelperWatchUpdate: Equatable, Sendable {
    case available
    case unavailable
    case event(RemoteHelperWatchEvent)
}

public struct RemoteHelperWatchHandle: Sendable {
    public let subscriptionId: String
    public let updates: AsyncStream<RemoteHelperWatchUpdate>

    public init(subscriptionId: String, updates: AsyncStream<RemoteHelperWatchUpdate>) {
        self.subscriptionId = subscriptionId
        self.updates = updates
    }
}

public struct RemoteHelperFSReadParams: Codable, Equatable, Sendable {
    public let path: String
    public let offset: UInt64?

    public init(path: String, offset: UInt64? = nil) {
        self.path = path
        self.offset = offset
    }
}

public struct RemoteHelperFSReadResult: Codable, Equatable, Sendable {
    public let kind: String?
    public let content: String?
    public let contentBase64: String?
    public let mtime: Double?
    public let detail: String?

    public init(kind: String?, content: String?, contentBase64: String?, mtime: Double?, detail: String?) {
        self.kind = kind
        self.content = content
        self.contentBase64 = contentBase64
        self.mtime = mtime
        self.detail = detail
    }
}

public struct RemoteHelperFSWriteParams: Codable, Equatable, Sendable {
    public let path: String
    public let content: String
    public let expectedMtime: Double?
    public let expectedContent: String?

    public init(path: String, content: String, expectedMtime: Double? = nil, expectedContent: String? = nil) {
        self.path = path
        self.content = content
        self.expectedMtime = expectedMtime
        self.expectedContent = expectedContent
    }
}

public struct RemoteHelperFSWriteResult: Codable, Equatable, Sendable {
    public let mtime: Double?

    public init(mtime: Double?) {
        self.mtime = mtime
    }
}

public struct RemoteHelperFSStatParams: Codable, Equatable, Sendable {
    public let paths: [String]

    public init(paths: [String]) {
        self.paths = paths
    }
}

public struct RemoteHelperFSStatResult: Codable, Equatable, Sendable {
    public let entries: [RemoteHelperFSStatEntry]

    public init(entries: [RemoteHelperFSStatEntry]) {
        self.entries = entries
    }
}

public struct RemoteHelperFSStatEntry: Codable, Equatable, Sendable {
    public let path: String
    public let exists: Bool
    public let isDirectory: Bool
    public let isFile: Bool
    public let size: UInt64?
    public let mtime: Double?

    public func virtualized(host: String) -> Self {
        Self(
            path: remoteHelperVirtualPath(host: host, path), exists: exists,
            isDirectory: isDirectory, isFile: isFile, size: size, mtime: mtime
        )
    }

    public init(path: String, exists: Bool, isDirectory: Bool, isFile: Bool, size: UInt64?, mtime: Double?) {
        self.path = path
        self.exists = exists
        self.isDirectory = isDirectory
        self.isFile = isFile
        self.size = size
        self.mtime = mtime
    }
}

public struct RemoteHelperFSLineCountsParams: Codable, Equatable, Sendable {
    public let root: String
    public let paths: [String]

    public init(root: String, paths: [String]) {
        self.root = root
        self.paths = paths
    }
}

public struct RemoteHelperFSLineCountsResult: Codable, Equatable, Sendable {
    public let entries: [RemoteHelperFSLineCountEntry]

    public init(entries: [RemoteHelperFSLineCountEntry]) {
        self.entries = entries
    }
}

public struct RemoteHelperFSLineCountEntry: Codable, Equatable, Sendable {
    public let path: String
    public let lineCount: Int

    public func virtualized(host: String) -> Self {
        Self(path: remoteHelperVirtualPath(host: host, path), lineCount: lineCount)
    }

    public init(path: String, lineCount: Int) {
        self.path = path
        self.lineCount = lineCount
    }
}

public struct RemoteHelperFSListParams: Codable, Equatable, Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }
}

public struct RemoteHelperFSListResult: Codable, Equatable, Sendable {
    public let entries: [RemoteHelperFSListEntry]

    public init(entries: [RemoteHelperFSListEntry]) {
        self.entries = entries
    }
}

public struct RemoteHelperFSListEntry: Codable, Equatable, Sendable {
    public let name: String
    public let isDirectory: Bool

    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }
}

public struct RemoteHelperSearchStartParams: Codable, Equatable, Sendable {
    public let root: String
    public let query: String
    public let caseSensitive: Bool
    public let wholeWord: Bool
    public let regex: Bool

    public init(root: String, query: String, caseSensitive: Bool, wholeWord: Bool, regex: Bool) {
        self.root = root
        self.query = query
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
    }
}

public struct RemoteHelperSearchStartResult: Codable, Equatable, Sendable {
    public let searchId: String

    public init(searchId: String) {
        self.searchId = searchId
    }
}

public struct RemoteHelperSearchCancelParams: Codable, Equatable, Sendable {
    public let searchId: String

    public init(searchId: String) {
        self.searchId = searchId
    }
}

public struct RemoteHelperSearchCancelResult: Codable, Equatable, Sendable {
    public let ok: Bool

    public init(ok: Bool) {
        self.ok = ok
    }
}

public struct RemoteHelperSearchEventParams: Codable, Equatable, Sendable {
    public let searchId: String
    public let line: String

    public init(searchId: String, line: String) {
        self.searchId = searchId
        self.line = line
    }
}

public struct RemoteHelperSearchCompleteParams: Codable, Equatable, Sendable {
    public let searchId: String
    public let exitCode: Int32
    public let stderr: String
    public let cancelled: Bool

    public init(searchId: String, exitCode: Int32, stderr: String, cancelled: Bool) {
        self.searchId = searchId
        self.exitCode = exitCode
        self.stderr = stderr
        self.cancelled = cancelled
    }
}

public enum RemoteHelperSearchEvent: Equatable, Sendable {
    case line(String)
    case complete(exitCode: Int32, stderr: String, cancelled: Bool)
}

public struct RemoteHelperSearchHandle: Sendable {
    public let searchId: String
    public let events: AsyncThrowingStream<RemoteHelperSearchEvent, Error>

    public init(searchId: String, events: AsyncThrowingStream<RemoteHelperSearchEvent, Error>) {
        self.searchId = searchId
        self.events = events
    }
}

public struct RemoteHelperProcSpawnParams: Codable, Equatable, Sendable {
    public let procId: String
    public let command: String
    public let args: [String]
    public let cwd: String
    public let env: [String: String]
    public let pathPrefixDirectories: [String]
    public var leaseFence: RemoteSessionFence? = nil

    public init(procId: String, command: String, args: [String], cwd: String, env: [String: String], pathPrefixDirectories: [String], leaseFence: RemoteSessionFence? = nil) {
        self.procId = procId
        self.command = command
        self.args = args
        self.cwd = cwd
        self.env = env
        self.pathPrefixDirectories = pathPrefixDirectories
        self.leaseFence = leaseFence
    }
}

public struct RemoteHelperProcStatus: Codable, Equatable, Sendable {
    public let procId: String
    public let running: Bool
    public let exitCode: Int32?
    public let spawned: Bool?

    public init(procId: String, running: Bool, exitCode: Int32?, spawned: Bool?) {
        self.procId = procId
        self.running = running
        self.exitCode = exitCode
        self.spawned = spawned
    }
}

public struct RemoteHelperProcAttachParams: Codable, Equatable, Sendable {
    public let procId: String
    public let stdoutOffset: UInt64?
    public let stderrOffset: UInt64?

    public init(procId: String, stdoutOffset: UInt64?, stderrOffset: UInt64?) {
        self.procId = procId
        self.stdoutOffset = stdoutOffset
        self.stderrOffset = stderrOffset
    }
}

public struct RemoteHelperProcReplayFrame: Codable, Equatable, Sendable {
    public let offset: UInt64
    public let dataBase64: String

    public init(offset: UInt64, dataBase64: String) {
        self.offset = offset
        self.dataBase64 = dataBase64
    }
}

public struct RemoteHelperProcAttachResult: Codable, Equatable, Sendable {
    public let procId: String
    public let running: Bool
    public let exitCode: Int32?
    public let stdinOffset: UInt64
    public let stdoutOffset: UInt64
    public let stderrOffset: UInt64
    public let stdoutFrames: [RemoteHelperProcReplayFrame]
    public let stderrChunks: [RemoteHelperProcReplayFrame]

    public init(procId: String, running: Bool, exitCode: Int32?, stdinOffset: UInt64, stdoutOffset: UInt64, stderrOffset: UInt64, stdoutFrames: [RemoteHelperProcReplayFrame], stderrChunks: [RemoteHelperProcReplayFrame]) {
        self.procId = procId
        self.running = running
        self.exitCode = exitCode
        self.stdinOffset = stdinOffset
        self.stdoutOffset = stdoutOffset
        self.stderrOffset = stderrOffset
        self.stdoutFrames = stdoutFrames
        self.stderrChunks = stderrChunks
    }
}

public struct RemoteHelperProcWriteParams: Codable, Equatable, Sendable {
    public let procId: String
    public let dataBase64: String
    public let expectedStdinOffset: UInt64?
    public var leaseFence: RemoteSessionFence? = nil

    public init(procId: String, dataBase64: String, expectedStdinOffset: UInt64?, leaseFence: RemoteSessionFence? = nil) {
        self.procId = procId
        self.dataBase64 = dataBase64
        self.expectedStdinOffset = expectedStdinOffset
        self.leaseFence = leaseFence
    }
}

public struct RemoteHelperProcWriteResult: Codable, Equatable, Sendable {
    public let ok: Bool
    public let stdinOffset: UInt64

    public init(ok: Bool, stdinOffset: UInt64) {
        self.ok = ok
        self.stdinOffset = stdinOffset
    }
}

public struct RemoteHelperProcKillParams: Codable, Equatable, Sendable {
    public let procId: String
    public var leaseFence: RemoteSessionFence? = nil

    public init(procId: String, leaseFence: RemoteSessionFence? = nil) {
        self.procId = procId
        self.leaseFence = leaseFence
    }
}

public struct RemoteHelperProcKillResult: Codable, Equatable, Sendable {
    public let ok: Bool

    public init(ok: Bool) {
        self.ok = ok
    }
}

public struct RemoteHelperProcListResult: Codable, Equatable, Sendable {
    public let entries: [RemoteHelperProcStatus]

    public init(entries: [RemoteHelperProcStatus]) {
        self.entries = entries
    }
}

public struct RemoteHelperProcOutputParams: Codable, Equatable, Sendable {
    public let procId: String
    public let stream: String
    public let offset: UInt64
    public let dataBase64: String

    public init(procId: String, stream: String, offset: UInt64, dataBase64: String) {
        self.procId = procId
        self.stream = stream
        self.offset = offset
        self.dataBase64 = dataBase64
    }
}

public struct RemoteHelperProcExitParams: Codable, Equatable, Sendable {
    public let procId: String
    public let exitCode: Int32?

    public init(procId: String, exitCode: Int32?) {
        self.procId = procId
        self.exitCode = exitCode
    }
}

public enum RemoteHelperProcEvent: Equatable, Sendable {
    case available
    case unavailable
    case stdout(Data, offset: UInt64)
    case stderr(Data, offset: UInt64)
    case exited(Int32?)
}

public struct RemoteHelperProcAttachHandle: Sendable {
    public let procId: String
    public let attachmentId: String
    public let stdinOffset: UInt64
    public let stdoutOffset: UInt64
    public let stderrOffset: UInt64
    public let events: AsyncStream<RemoteHelperProcEvent>

    public init(procId: String, attachmentId: String, stdinOffset: UInt64, stdoutOffset: UInt64, stderrOffset: UInt64, events: AsyncStream<RemoteHelperProcEvent>) {
        self.procId = procId
        self.attachmentId = attachmentId
        self.stdinOffset = stdinOffset
        self.stdoutOffset = stdoutOffset
        self.stderrOffset = stderrOffset
        self.events = events
    }
}

// MARK: Visual MCP relay (`mcp/*`)

/// Byte limits of the visual MCP relay. A raw MCP frame is bounded so that
/// its base64 form plus envelope metadata stays under the envelope limit.
public enum RemoteMCPRelayLimits: Sendable {
    public static let protocolVersion = 1
    public static let maxFrameBytes = 4 * 1024 * 1024
    public static let maxEnvelopeBytes = 6 * 1024 * 1024
}

/// The app's local identity for one relay route. It survives helper
/// reconnects; each helper registration behind it gets a fresh relay id.
public struct RemoteMCPRouteHandle: Hashable, Sendable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

/// The `mcp/register` result: the stable stdio command the remote agent runs.
public struct RemoteMCPRouteDescriptor: Codable, Equatable, Sendable {
    public let recordId: String
    public let relayId: String
    public let proxyCommand: String
    public let proxyArgs: [String]
    public let relayProtocolVersion: Int

    public init(recordId: String, relayId: String, proxyCommand: String, proxyArgs: [String], relayProtocolVersion: Int) {
        self.recordId = recordId
        self.relayId = relayId
        self.proxyCommand = proxyCommand
        self.proxyArgs = proxyArgs
        self.relayProtocolVersion = relayProtocolVersion
    }
}

/// Where a relayed request came from. Only the helper client creates one,
/// and a completion is accepted only for the registration and helper
/// generation that delivered it.
public struct RemoteMCPRelayOrigin: Equatable, Sendable {
    public let route: RemoteMCPRouteHandle
    public let relayId: String
    public let helperGeneration: Int
    public let requestId: String

    public init(route: RemoteMCPRouteHandle, relayId: String, helperGeneration: Int, requestId: String) {
        self.route = route
        self.relayId = relayId
        self.helperGeneration = helperGeneration
        self.requestId = requestId
    }
}

public enum RemoteMCPRelayEvent: Equatable, Sendable {
    case available
    case request(origin: RemoteMCPRelayOrigin, frame: Data)
    case unavailable
}

public enum RemoteMCPRelayCompletion: Equatable, Sendable {
    /// The MCP response bytes for an inner request.
    case frame(Data)
    /// Acknowledges an inner notification; the proxy writes nothing.
    case notification
    case failed(code: Int, message: String)
}

struct RemoteMCPRegisterParams: Codable, Equatable, Sendable {
    let fence: RemoteSessionFence
    let relayId: String
}

struct RemoteMCPRequestParams: Codable, Equatable, Sendable {
    let requestId: String
    let recordId: String
    let relayId: String
    let frameBase64: String
}

struct RemoteMCPCompleteParams: Encodable, Sendable {
    let fence: RemoteSessionFence
    let relayId: String
    let requestId: String
    let completion: RemoteMCPRelayCompletion

    private enum CodingKeys: String, CodingKey {
        case fence, relayId, requestId, responseBase64, error
    }

    private struct Failure: Encodable {
        let code: Int
        let message: String
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fence, forKey: .fence)
        try container.encode(relayId, forKey: .relayId)
        try container.encode(requestId, forKey: .requestId)
        switch completion {
        case .frame(let data):
            try container.encode(data.base64EncodedString(), forKey: .responseBase64)
        case .notification:
            // An explicit null, distinct from an omitted field, acknowledges a notification.
            try container.encodeNil(forKey: .responseBase64)
        case .failed(let code, let message):
            try container.encode(Failure(code: code, message: message), forKey: .error)
        }
    }
}

struct RemoteMCPOKResult: Codable, Equatable, Sendable {
    let ok: Bool
}
