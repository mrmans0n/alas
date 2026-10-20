import Foundation
import Observation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP

/// The Alas worktree a listed session runs in, with its session store.
public struct ACPSessionBrowserTarget: Sendable {
    public let worktreeId: String
    /// Nil when the worktree has no session store yet, so no Alas session.
    public let persistence: ACPSessionPersistence?

    public init(worktreeId: String, persistence: ACPSessionPersistence?) {
        self.worktreeId = worktreeId
        self.persistence = persistence
    }
}

@MainActor
public final class ACPSessionDiscoveryHandle {
    nonisolated public let capabilities: ACPSessionDiscoveryCapabilities
    /// The client-neutral session index, when the agent advertised it.
    nonisolated public let sessionIndex: ACPSessionIndexSupport?
    private let worktreeId: String
    /// The worktree this browser lists from.
    nonisolated public var browsingWorktreeId: String { worktreeId }
    package let agentId: String
    private let cwd: String
    private let persistence: ACPSessionPersistence
    private let connection: ACPConnection
    /// Maps a row's cwd to the Alas worktree whose path it is, and that
    /// worktree's session store (each worktree has its own).
    private let worktreeResolver: @MainActor (String) -> ACPSessionBrowserTarget?
    /// Only a browser given a project resolver lists linked worktrees; a
    /// workspace checkout's browser stays on its own directory.
    nonisolated public let canListLinkedWorktrees: Bool
    private let onClosed: (@MainActor @Sendable () -> Void)?
    private var nextCursor: String?
    private var hasLoadedPage = false
    private var closed = false
    private var subscriptionId: String?
    /// Alas copies removed while browsing, by agent session id. A store read
    /// that raced the removal still returns the removed id; a later import
    /// gets a new one.
    private var removedLocalCopies: [String: String] = [:]
    public private(set) var filter = ACPSessionBrowserFilter()

    /// Session index pages that hold no row for this browser but still have
    /// a cursor are followed, at most this many requests per load.
    static let maxPagesPerLoad = 10

    public init(
        worktreeId: String,
        agentId: String,
        cwd: String,
        persistence: ACPSessionPersistence,
        connection: ACPConnection,
        capabilities: ACPSessionDiscoveryCapabilities,
        sessionIndex: ACPSessionIndexSupport? = nil,
        worktreeResolver: (@MainActor (String) -> ACPSessionBrowserTarget?)? = nil,
        onClosed: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.worktreeId = worktreeId
        self.agentId = agentId
        self.cwd = cwd
        self.persistence = persistence
        self.connection = connection
        self.capabilities = capabilities
        self.sessionIndex = sessionIndex
        let ownCWD = ACPSessionBrowserPaths.key(cwd, context: cwd)
        canListLinkedWorktrees = sessionIndex != nil && worktreeResolver != nil
        let own = ACPSessionBrowserTarget(worktreeId: worktreeId, persistence: persistence)
        self.worktreeResolver = worktreeResolver ?? { ACPSessionBrowserPaths.key($0, context: cwd) == ownCWD ? own : nil }
        self.onClosed = onClosed
    }

    deinit {
        guard !closed else { return }
        let connection = connection
        let onClosed = onClosed
        Task { @MainActor in
            await connection.shutdown()
            onClosed?()
        }
    }

    public var canLoadMore: Bool { !hasLoadedPage || nextCursor != nil }

    /// `isCurrent` is asked once the page arrives: when it says no (the
    /// browser changed filter meanwhile), the page is dropped and the cursor
    /// stays where the newer load put it.
    public func loadNextPage(isCurrent: @MainActor () -> Bool = { true }) async throws -> [ACPDiscoveredSession] {
        guard !closed, canLoadMore else { return [] }
        let (rows, cursor) = try await readPages(from: nextCursor, filter: filter)
        guard isCurrent() else { return [] }
        hasLoadedPage = true
        nextCursor = cursor
        return rows
    }

    /// The first page for `filter`, without changing the handle's filter or
    /// cursor: a filter change commits it with `commit(filter:cursor:)` only
    /// if it is still the latest, and a reconcile never moves "Load more".
    public func firstPage(filter: ACPSessionBrowserFilter) async throws -> (rows: [ACPDiscoveredSession], cursor: String?) {
        guard !closed else { return ([], nil) }
        return try await readPages(from: nil, filter: filter)
    }

    /// The page after `cursor` for `filter`, without changing the handle's
    /// cursor.
    public func page(
        after cursor: String,
        filter: ACPSessionBrowserFilter
    ) async throws -> (rows: [ACPDiscoveredSession], cursor: String?) {
        guard !closed else { return ([], nil) }
        return try await readPages(from: cursor, filter: filter)
    }

    /// Makes `filter` the handle's filter, continuing after its first page.
    /// Only an agent with the session index honors a filter.
    public func commit(filter: ACPSessionBrowserFilter, cursor: String?) {
        guard sessionIndex != nil else { return }
        self.filter = filter
        hasLoadedPage = true
        nextCursor = cursor
    }

    private func readPages(
        from start: String?,
        filter: ACPSessionBrowserFilter
    ) async throws -> (rows: [ACPDiscoveredSession], cursor: String?) {
        let options = sessionIndex == nil ? nil : filter.listOptions
        var discovered: [ACPDiscoveredSession] = []
        var cursor = start
        var requests = 0
        repeat {
            let page = try await connection.listSessions(cwd: cwd, cursor: cursor, index: options)
            cursor = page.nextCursor
            requests += 1
            for info in page.sessions {
                if let row = await discoveredSession(info, filter: filter) { discovered.append(row) }
            }
        } while discovered.isEmpty && cursor != nil && requests < Self.maxPagesPerLoad
        return (discovered, cursor)
    }

    /// A browser row for `info`, or nil when it is outside the browser's
    /// scope: without the linked-worktree scope only this worktree's exact
    /// cwd is listed, as before the session index.
    private func discoveredSession(_ info: ACPAgentSessionInfo, filter: ACPSessionBrowserFilter) async -> ACPDiscoveredSession? {
        let target = worktreeResolver(info.cwd)
        let includeLinked = canListLinkedWorktrees && filter.includeLinkedWorktrees
        guard includeLinked || target?.worktreeId == worktreeId else { return nil }
        var local = try? await target?.persistence?.loadSession(agentId: agentId, remoteSessionId: info.sessionId)
        if let id = local?.id, removedLocalCopies[info.sessionId] == id { local = nil }
        let remoteTitle = info.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = if let remoteTitle, !remoteTitle.isEmpty { remoteTitle } else { "Agent session" }
        return ACPDiscoveredSession(
            worktreeId: target?.worktreeId,
            agentId: agentId,
            remoteSessionId: info.sessionId,
            cwd: info.cwd,
            title: local?.title ?? displayTitle,
            updatedAt: info.updatedAt.flatMap(ACPSessionIndexDates.parse),
            additionalDirectories: info.additionalDirectories ?? [],
            localSessionId: local?.id,
            index: info.index
        )
    }

    public func refresh() {
        nextCursor = nil
        hasLoadedPage = false
    }

    /// Rows built from now on never show `localSessionId` for `remoteSessionId`.
    public func forgetLocalCopy(_ localSessionId: String, of remoteSessionId: String) {
        removedLocalCopies[remoteSessionId] = localSessionId
    }

    public func deleteSession(remoteSessionId: String) async throws {
        guard capabilities.canDelete else { throw ACPSessionDiscoveryError.deletionUnsupported }
        try await connection.deleteSession(sessionId: remoteSessionId)
    }

    public func renameSession(remoteSessionId: String, title: String) async throws {
        guard sessionIndex?.rename == true else { throw ACPSessionDiscoveryError.renameUnsupported }
        try await connection.renameSession(sessionId: remoteSessionId, title: title)
    }

    public func setArchived(_ archived: Bool, remoteSessionId: String) async throws {
        guard sessionIndex?.archive == true else { throw ACPSessionDiscoveryError.archiveUnsupported }
        if archived {
            try await connection.archiveSession(sessionId: remoteSessionId)
        } else {
            try await connection.unarchiveSession(sessionId: remoteSessionId)
        }
    }

    /// Subscribes to list changes of this worktree and its linked worktrees,
    /// and yields them as browser rows in the current scope. The stream ends
    /// when the handle closes or its connection goes away. Nil when the agent
    /// has no list subscription.
    /// `stamp` is read when a notification starts being turned into rows
    /// (which reads the session store) and yielded with them, so the caller
    /// can tell which local actions and list reads happened meanwhile.
    public func subscribe(
        stamp: @escaping @MainActor () -> ACPSessionBrowserStamp = { .init() }
    ) async throws -> AsyncStream<(changed: [ACPDiscoveredSession], removed: [String], stamp: ACPSessionBrowserStamp)>? {
        guard !closed, sessionIndex?.listSubscribe == true, subscriptionId == nil else { return nil }
        // Subscribe before relisting: changes are tracked from the answer on.
        let id = try await connection.subscribeSessionList(cwd: cwd)
        subscriptionId = id
        let incoming = connection.client.sessionListChanges
        // Stamped on arrival, before waiting behind a batch whose rows are
        // still being read from the session store.
        let (stamped, stampedContinuation) = AsyncStream<(ACPSessionListChanges, ACPSessionBrowserStamp)>.makeStream()
        let receiver = Task { @MainActor in
            for await changes in incoming where changes.subscriptionId == id {
                stampedContinuation.yield((changes, stamp()))
            }
            stampedContinuation.finish()
        }
        return AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                for await (changes, started) in stamped {
                    guard let self, !self.closed else { break }
                    var rows: [ACPDiscoveredSession] = []
                    for info in changes.sessions {
                        // Mapped with the linked scope: the model scopes rows by
                        // its current filter, which may be newer than the handle's.
                        if let row = await self.discoveredSession(info, filter: .init(includeLinkedWorktrees: true)) {
                            rows.append(row)
                        }
                    }
                    continuation.yield((rows, changes.removed, started))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                receiver.cancel()
            }
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        if let subscriptionId {
            self.subscriptionId = nil
            try? await connection.unsubscribeSessionList(subscriptionId: subscriptionId)
        }
        await connection.shutdown()
        onClosed?()
    }
}
