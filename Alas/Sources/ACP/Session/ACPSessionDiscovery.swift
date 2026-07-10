import Foundation
import Observation

struct ACPSessionDiscoveryCapabilities: Equatable {
    let canLoad: Bool
    let canResume: Bool
    let canFork: Bool

    var canOpenRemoteSession: Bool { canLoad || canResume }
}

struct ACPDiscoveredSession: Identifiable, Equatable {
    var id: String { remoteSessionId }

    let agentId: String
    let remoteSessionId: String
    let cwd: String
    let title: String
    let updatedAt: Date?
    let additionalDirectories: [String]
    let localSessionId: String?

    var isAlreadyInAlas: Bool { localSessionId != nil }
    var isCompatibleWithAlas: Bool { additionalDirectories.isEmpty }
}

enum ACPSessionRestoreOperation: Equatable {
    case resume
    case loadWithRecovery
    case loadStrict
    case unavailable
}

enum ACPSessionRestorePolicy {
    static func operation(
        origin: ACPSessionOrigin,
        canLoad: Bool,
        canResume: Bool,
        hasLocalTranscript: Bool = false
    ) -> ACPSessionRestoreOperation {
        switch origin {
        case .alasCreated:
            return canResume ? .resume : .loadWithRecovery
        case .agentImported, .agentForked:
            if hasLocalTranscript, canResume { return .resume }
            if canLoad { return .loadStrict }
            if canResume { return .resume }
            return .unavailable
        }
    }
}

enum ACPSessionDiscoveryError: LocalizedError, Equatable {
    case noLaunchSpec(String)
    case setupRequired(String)
    case listingUnsupported

    var errorDescription: String? {
        switch self {
        case .noLaunchSpec(let agentId):
            return "No ACP launch configuration is available for \(agentId)."
        case .setupRequired(let reason):
            return reason
        case .listingUnsupported:
            return "This agent does not support session browsing."
        }
    }
}

enum ACPSessionAttachError: LocalizedError, Equatable {
    case remoteSessionUnsupported

    var errorDescription: String? {
        "This agent cannot reopen the selected session."
    }
}

@MainActor
final class ACPSessionDiscoveryHandle {
    let capabilities: ACPSessionDiscoveryCapabilities
    private let agentId: String
    private let cwd: String
    private let store: ACPSessionStore
    private let connection: ACPConnection
    private var nextCursor: String?
    private var hasLoadedPage = false
    private var closed = false

    init(
        agentId: String,
        cwd: String,
        store: ACPSessionStore,
        connection: ACPConnection,
        capabilities: ACPSessionDiscoveryCapabilities
    ) {
        self.agentId = agentId
        self.cwd = cwd
        self.store = store
        self.connection = connection
        self.capabilities = capabilities
    }

    var canLoadMore: Bool { !hasLoadedPage || nextCursor != nil }

    func loadNextPage() async throws -> [ACPDiscoveredSession] {
        guard !closed, canLoadMore else { return [] }
        let page = try await connection.listSessions(cwd: cwd, cursor: nextCursor)
        hasLoadedPage = true
        nextCursor = page.nextCursor
        let expectedCWD = URL(fileURLWithPath: cwd).standardizedFileURL.path
        return page.sessions.compactMap { info in
            guard URL(fileURLWithPath: info.cwd).standardizedFileURL.path == expectedCWD else {
                return nil
            }
            let local = try? store.loadSession(agentId: agentId, remoteSessionId: info.sessionId)
            let remoteTitle = info.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = if let remoteTitle, !remoteTitle.isEmpty {
                remoteTitle
            } else {
                "Agent session"
            }
            return ACPDiscoveredSession(
                agentId: agentId,
                remoteSessionId: info.sessionId,
                cwd: info.cwd,
                title: local?.title ?? displayTitle,
                updatedAt: info.updatedAt.flatMap { ISO8601DateFormatter().date(from: $0) },
                additionalDirectories: info.additionalDirectories ?? [],
                localSessionId: local?.id
            )
        }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await connection.shutdown()
    }
}

@MainActor
@Observable
final class ACPSessionDiscoveryModel {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case unsupported
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var sessions: [ACPDiscoveredSession] = []
    private(set) var capabilities: ACPSessionDiscoveryCapabilities?
    private(set) var paginationError: String?
    private var handle: ACPSessionDiscoveryHandle?
    private var stopped = false

    var canLoadMore: Bool { handle?.canLoadMore == true }

    func start(manager: ACPSessionManager, agentId: String) async {
        guard phase == .idle, !stopped else { return }
        phase = .loading
        do {
            let handle = try await manager.makeSessionDiscoveryHandle(agentId: agentId)
            guard !stopped else {
                await handle.close()
                return
            }
            self.handle = handle
            capabilities = handle.capabilities
            try await loadMore()
            phase = .ready
        } catch ACPSessionDiscoveryError.listingUnsupported {
            phase = .unsupported
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func loadMore() async throws {
        guard let handle else { return }
        do {
            let page = try await handle.loadNextPage()
            var known = Set(sessions.map(\.remoteSessionId))
            sessions.append(contentsOf: page.filter { known.insert($0.remoteSessionId).inserted })
            paginationError = nil
        } catch {
            paginationError = error.localizedDescription
            throw error
        }
    }

    func stop() async {
        stopped = true
        await handle?.close()
        handle = nil
    }
}
