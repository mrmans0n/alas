import Foundation
import Observation

struct ACPSessionDiscoveryCapabilities: Equatable {
    let canLoad: Bool
    let canResume: Bool
    let canFork: Bool
    let canDelete: Bool

    var canOpenRemoteSession: Bool { canLoad || canResume }
}

struct ACPDiscoveredSession: Identifiable, Equatable {
    var id: String { remoteSessionId }

    let worktreeId: String
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
    case deletionUnsupported

    var errorDescription: String? {
        switch self {
        case .noLaunchSpec(let agentId):
            return "No ACP launch configuration is available for \(agentId)."
        case .setupRequired(let reason):
            return reason
        case .listingUnsupported:
            return "This agent does not support session browsing."
        case .deletionUnsupported:
            return "This agent does not support deleting session history."
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
    private let worktreeId: String
    private let agentId: String
    private let cwd: String
    private let persistence: ACPSessionPersistence
    private let connection: ACPConnection
    private var nextCursor: String?
    private var hasLoadedPage = false
    private var closed = false

    init(
        worktreeId: String,
        agentId: String,
        cwd: String,
        persistence: ACPSessionPersistence,
        connection: ACPConnection,
        capabilities: ACPSessionDiscoveryCapabilities
    ) {
        self.worktreeId = worktreeId
        self.agentId = agentId
        self.cwd = cwd
        self.persistence = persistence
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
        var discovered: [ACPDiscoveredSession] = []
        discovered.reserveCapacity(page.sessions.count)
        for info in page.sessions {
            guard URL(fileURLWithPath: info.cwd).standardizedFileURL.path == expectedCWD else {
                continue
            }
            let local = try? await persistence.loadSession(
                agentId: agentId,
                remoteSessionId: info.sessionId
            )
            let remoteTitle = info.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = if let remoteTitle, !remoteTitle.isEmpty {
                remoteTitle
            } else {
                "Agent session"
            }
            discovered.append(ACPDiscoveredSession(
                worktreeId: worktreeId,
                agentId: agentId,
                remoteSessionId: info.sessionId,
                cwd: info.cwd,
                title: local?.title ?? displayTitle,
                updatedAt: info.updatedAt.flatMap { ISO8601DateFormatter().date(from: $0) },
                additionalDirectories: info.additionalDirectories ?? [],
                localSessionId: local?.id
            ))
        }
        return discovered
    }

    func refresh() {
        nextCursor = nil
        hasLoadedPage = false
    }

    func deleteSession(remoteSessionId: String) async throws {
        guard capabilities.canDelete else { throw ACPSessionDiscoveryError.deletionUnsupported }
        try await connection.deleteSession(sessionId: remoteSessionId)
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
    private(set) var deletingSessionIds: Set<String> = []
    private(set) var remotelyDeletedSessionIds: Set<String> = []
    private var handle: ACPSessionDiscoveryHandle?
    private var stopped = false
    private var replaceSessionsOnNextLoad = false
    private var deletionActive = false
    private var deletionQueue: [CheckedContinuation<Void, Never>] = []
    private var deletionWaiters: [CheckedContinuation<Void, Never>] = []

    var canLoadMore: Bool { handle?.canLoadMore == true }

    func deleteAgentHistory(
        for session: ACPDiscoveredSession,
        removeLocalHistory: Bool,
        manager: ACPSessionManager
    ) async throws {
        guard capabilities?.canDelete == true, let handle else {
            throw ACPSessionDiscoveryError.deletionUnsupported
        }
        guard await beginDeletion(session.remoteSessionId) else { return }
        defer { finishDeletion(session.remoteSessionId) }

        if !remotelyDeletedSessionIds.contains(session.remoteSessionId) {
            try await manager.closeActiveSessionForDeletion(
                localSessionId: session.localSessionId,
                agentId: session.agentId,
                remoteSessionId: session.remoteSessionId
            )
            try await handle.deleteSession(remoteSessionId: session.remoteSessionId)
            remotelyDeletedSessionIds.insert(session.remoteSessionId)
        }

        try await refreshAfterDeletion()
        if removeLocalHistory, let localSessionId = session.localSessionId {
            do {
                try await manager.deletePersistedSession(id: localSessionId)
            } catch {
                if !sessions.contains(where: { $0.remoteSessionId == session.remoteSessionId }) {
                    sessions.append(session)
                }
                throw error
            }
        }
    }

    func removeLocalHistory(
        for session: ACPDiscoveredSession,
        manager: ACPSessionManager
    ) async throws {
        guard let localSessionId = session.localSessionId else { return }
        guard await beginDeletion(session.remoteSessionId) else { return }
        defer { finishDeletion(session.remoteSessionId) }
        try await manager.deletePersistedSession(id: localSessionId)
        try await refreshAfterDeletion()
    }

    private func refreshAfterDeletion() async throws {
        guard let handle else { return }
        let previous = sessions
        handle.refresh()
        replaceSessionsOnNextLoad = true
        sessions = []
        do {
            try await loadMore()
        } catch {
            sessions = previous
            throw error
        }
    }

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
            if replaceSessionsOnNextLoad {
                sessions = page
                replaceSessionsOnNextLoad = false
                paginationError = nil
                return
            }
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
        if !deletingSessionIds.isEmpty {
            await withCheckedContinuation { deletionWaiters.append($0) }
        }
        await handle?.close()
        handle = nil
    }

    private func beginDeletion(_ remoteSessionId: String) async -> Bool {
        guard deletingSessionIds.insert(remoteSessionId).inserted else { return false }
        if deletionActive {
            await withCheckedContinuation { deletionQueue.append($0) }
        }
        deletionActive = true
        return true
    }

    private func finishDeletion(_ remoteSessionId: String) {
        deletingSessionIds.remove(remoteSessionId)
        if !deletionQueue.isEmpty {
            deletionQueue.removeFirst().resume()
        } else {
            deletionActive = false
        }
        guard deletingSessionIds.isEmpty else { return }
        let waiters = deletionWaiters
        deletionWaiters = []
        waiters.forEach { $0.resume() }
    }
}
