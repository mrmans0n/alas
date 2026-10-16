import Foundation
import Observation

public struct ACPSessionDiscoveryCapabilities: Equatable, Sendable {
    public let canLoad: Bool
    public let canResume: Bool
    public let canFork: Bool
    public let canDelete: Bool

    public var canOpenRemoteSession: Bool { canLoad || canResume }

    public init(canLoad: Bool, canResume: Bool, canFork: Bool, canDelete: Bool) {
        self.canLoad = canLoad
        self.canResume = canResume
        self.canFork = canFork
        self.canDelete = canDelete
    }
}

public struct ACPDiscoveredSession: Identifiable, Equatable, Sendable {
    public var id: String { remoteSessionId }

    /// The Alas worktree the session runs in: the one whose path is `cwd`.
    /// Nil for a session outside every Alas worktree of the project, such as
    /// a worktree the agent made itself; such a row can be browsed but not
    /// opened.
    public let worktreeId: String?
    public let agentId: String
    public let remoteSessionId: String
    public let cwd: String
    public var title: String
    public let updatedAt: Date?
    public let additionalDirectories: [String]
    public var localSessionId: String?
    /// Session index row fields, when the agent sent them.
    public var index: ACPSessionIndexRowMeta?

    public var isAlreadyInAlas: Bool { localSessionId != nil }
    public var isCompatibleWithAlas: Bool { additionalDirectories.isEmpty }
    public var isArchived: Bool { index?.archived == true }
    /// The list order key of the session index: last prompt, else last activity.
    public var lastActivity: Date? {
        index?.lastPromptAt.flatMap(ACPSessionIndexDates.parse) ?? updatedAt
    }

    public init(
        worktreeId: String?,
        agentId: String,
        remoteSessionId: String,
        cwd: String,
        title: String,
        updatedAt: Date?,
        additionalDirectories: [String],
        localSessionId: String?,
        index: ACPSessionIndexRowMeta? = nil
    ) {
        self.worktreeId = worktreeId
        self.agentId = agentId
        self.remoteSessionId = remoteSessionId
        self.cwd = cwd
        self.title = title
        self.updatedAt = updatedAt
        self.additionalDirectories = additionalDirectories
        self.localSessionId = localSessionId
        self.index = index
    }
}

/// ISO 8601 timestamps of `session/list` rows, with or without fractional
/// seconds (Claude sends `.000Z`, Codex whole seconds).
extension ACPSessionIndexRowMeta {
    func with(archived: Bool) -> Self {
        var copy = self
        copy.archived = archived
        return copy
    }
}

public enum ACPSessionIndexDates {
    public static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// How a session's cwd is matched to an Alas worktree path.
public enum ACPSessionBrowserPaths {
    /// Adapters report agent-side paths: an SSH worktree's real path rather
    /// than its `/.alas-remote/<host>/…` id, and a local cwd with symlinks
    /// resolved (`/private/var/…` for `/var/…`). Both sides are keyed that
    /// way. `context` is the browsing worktree's path: under an SSH worktree
    /// a plain path is the remote host's, so it is never resolved against
    /// this Mac's file system.
    public static func key(_ path: String, context: String) -> String {
        if let remote = RemotePath.split(path) {
            return URL(fileURLWithPath: remote.realPath).standardizedFileURL.path
        }
        if RemotePath.split(context) != nil {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// When a live change started being turned into rows: the local actions
/// completed and the list reads started by then.
public struct ACPSessionBrowserStamp: Equatable, Sendable {
    public var localActions: Int
    public var listReads: Int

    public init(localActions: Int = 0, listReads: Int = 0) {
        self.localActions = localActions
        self.listReads = listReads
    }
}

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

/// What the session browser shows: the browsing worktree alone or every
/// linked worktree of its repository, and active or archived sessions.
public struct ACPSessionBrowserFilter: Equatable, Sendable {
    public var includeLinkedWorktrees: Bool
    public var showArchived: Bool

    public init(includeLinkedWorktrees: Bool = false, showArchived: Bool = false) {
        self.includeLinkedWorktrees = includeLinkedWorktrees
        self.showArchived = showArchived
    }

    var listOptions: ACPSessionIndexListOptions {
        .init(includeWorktrees: includeLinkedWorktrees, archived: showArchived ? .archived : .unarchived)
    }
}

/// Applies `_session/list/changes` to the rows the browser shows.
public enum ACPSessionBrowserReducer {
    /// A changed row replaces the listed row in place, so selection and
    /// scrolling stay put. A new row is inserted by last activity, newest
    /// first. A row that no longer matches the archive filter leaves, and so
    /// does every removed id. Ids stay unique.
    /// Without the linked-worktree scope, a row of another worktree leaves
    /// too: subscriptions always cover every linked worktree.
    public static func applying(
        changed: [ACPDiscoveredSession],
        removed: [String],
        to rows: [ACPDiscoveredSession],
        filter: ACPSessionBrowserFilter,
        browsingWorktreeId: String?
    ) -> [ACPDiscoveredSession] {
        let removedIds = Set(removed)
        var result = rows.filter { !removedIds.contains($0.remoteSessionId) }
        for row in changed where !removedIds.contains(row.remoteSessionId) {
            let existing = result.firstIndex { $0.remoteSessionId == row.remoteSessionId }
            let inScope = filter.includeLinkedWorktrees || row.worktreeId == browsingWorktreeId
            guard row.isArchived == filter.showArchived, inScope else {
                if let existing { result.remove(at: existing) }
                continue
            }
            if let existing {
                result[existing] = row
            } else {
                let date = row.lastActivity ?? .distantFuture
                let index = result.firstIndex { ($0.lastActivity ?? .distantPast) < date } ?? result.endIndex
                result.insert(row, at: index)
            }
        }
        return result
    }

    /// Live rows that may be older than what the browser already shows are
    /// left out; the next relist brings the agent's current state. A list
    /// read started after the change arrived has newer data for every row,
    /// and a local action completed meanwhile has newer data for its session.
    public static func droppingRows(
        _ rows: [ACPDiscoveredSession],
        predating stamp: ACPSessionBrowserStamp,
        listReadsStarted: Int,
        lastLocalAction: [String: Int]
    ) -> [ACPDiscoveredSession] {
        guard listReadsStarted == stamp.listReads else { return [] }
        return rows.filter { (lastLocalAction[$0.remoteSessionId] ?? Int.min) <= stamp.localActions }
    }

    /// Merges a freshly read first page. A row the previous first page held
    /// that the new one lacks is gone (a missed removal) when the new page is
    /// the whole list, or when it is newer than the new page's oldest row;
    /// an older one may just have moved to the next page, so it stays.
    public static func reconciling(
        firstPage: [ACPDiscoveredSession],
        hasMorePages: Bool,
        previousFirstPage: Set<String>,
        rows: [ACPDiscoveredSession],
        filter: ACPSessionBrowserFilter,
        browsingWorktreeId: String?
    ) -> [ACPDiscoveredSession] {
        let present = Set(firstPage.map(\.remoteSessionId))
        let oldest = firstPage.compactMap(\.lastActivity).min()
        let vanished = rows.filter { row in
            guard previousFirstPage.contains(row.remoteSessionId), !present.contains(row.remoteSessionId) else { return false }
            guard hasMorePages else { return true }
            guard let oldest, let activity = row.lastActivity else { return false }
            return activity > oldest
        }
        return applying(
            changed: firstPage,
            removed: vanished.map(\.remoteSessionId),
            to: rows,
            filter: filter,
            browsingWorktreeId: browsingWorktreeId
        )
    }
}

public enum ACPSessionRestoreOperation: Equatable, Sendable {
    case resume
    case loadWithRecovery
    case loadStrict
    case unavailable
}

public enum ACPSessionRestorePolicy: Sendable {
    public static func operation(
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

public enum ACPSessionDiscoveryError: LocalizedError, Equatable, Sendable {
    case noLaunchSpec(String)
    case setupRequired(String)
    case setupFailed(String)
    case listingUnsupported
    case deletionUnsupported
    case renameUnsupported
    case archiveUnsupported

    public var errorDescription: String? {
        switch self {
        case .noLaunchSpec(let agentId):
            return "No ACP launch configuration is available for \(agentId)."
        case .setupRequired(let reason), .setupFailed(let reason):
            return reason
        case .listingUnsupported:
            return "This agent does not support session browsing."
        case .deletionUnsupported:
            return "This agent does not support deleting session history."
        case .renameUnsupported:
            return "This agent does not support renaming sessions."
        case .archiveUnsupported:
            return "This agent does not support archiving sessions."
        }
    }
}

public enum ACPSessionAttachError: LocalizedError, Equatable, Sendable {
    case remoteSessionUnsupported

    public var errorDescription: String? {
        "This agent cannot reopen the selected session."
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
    private let agentId: String
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
        return AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                for await changes in incoming where changes.subscriptionId == id {
                    guard let self, !self.closed else { break }
                    let started = stamp()
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
            continuation.onTermination = { _ in task.cancel() }
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

@MainActor
@Observable
public final class ACPSessionDiscoveryModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case ready
        case unsupported
        /// The agent's adapter is missing or unusable; the reason says why.
        case needsSetup(String)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var sessions: [ACPDiscoveredSession] = []
    public private(set) var capabilities: ACPSessionDiscoveryCapabilities?
    public private(set) var paginationError: String?
    public private(set) var deletingSessionIds: Set<String> = []
    public private(set) var remotelyDeletedSessionIds: Set<String> = []
    /// The client-neutral session index of the agent, once started.
    public private(set) var sessionIndex: ACPSessionIndexSupport?
    /// The filter the user picked; the chips show it.
    public private(set) var filter = ACPSessionBrowserFilter()
    /// The filter `sessions` was listed with. It becomes `filter` only when
    /// that filter's first page arrives, so updates meanwhile, and a failed
    /// change, keep the rows consistent with what was listed.
    private var appliedFilter = ACPSessionBrowserFilter()
    private var filterLoadsInFlight = 0
    /// First-page reads in flight: filter loads and reconciles.
    private var listReadsInFlight = 0
    /// Every list read started, Load more included.
    private var listReadsStarted = 0
    /// Bumped by every completed local action (rename, archive, delete,
    /// remove from Alas). A first page read across one may predate it: a
    /// filter load reads again, a reconcile drops its page.
    private var localActionGeneration = 0
    /// The newest version of each row seen in a live change, also after it
    /// left the current filter, so a local patch starts from the newest data.
    private var latestLiveRows: [String: ACPDiscoveredSession] = [:]
    /// The `localActionGeneration` each session's last local action ended at.
    private var lastLocalAction: [String: Int] = [:]
    /// Live changes that arrived while a list read was in flight. They are
    /// applied at once and again when the last read finishes, so a page read
    /// before a change cannot undo it.
    private var pendingChanges: [(changed: [ACPDiscoveredSession], removed: [String])] = []
    /// Rows with a rename or archive request in flight.
    public private(set) var updatingSessionIds: Set<String> = []
    private var handle: ACPSessionDiscoveryHandle?
    /// Bumped by every filter change; a load that started under an older
    /// generation is discarded.
    private var filterGeneration = 0
    /// Ids of the last first page read, for `reconcile`.
    private var firstPageIds: Set<String> = []
    private var subscriptionTask: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?
    /// While a subscription is open, the first page is read again this often
    /// to pick up changes the adapter missed (subscriptions are best effort).
    /// It stops when the browser stops.
    public static let reconcileInterval: Duration = .seconds(60)
    private var stopped = false
    private var replaceSessionsOnNextLoad = false
    private var deletionActive = false
    private var deletionQueue: [CheckedContinuation<Void, Never>] = []
    private var deletionWaiters: [CheckedContinuation<Void, Never>] = []

    public var canLoadMore: Bool { filterLoadsInFlight == 0 && handle?.canLoadMore == true }

    public func deleteAgentHistory(
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
            if try await !manager.deleteCoordinatedAgentHistory(session) {
                try await manager.closeActiveSessionForDeletion(
                    localSessionId: session.localSessionId,
                    agentId: session.agentId,
                    remoteSessionId: session.remoteSessionId
                )
                try await handle.deleteSession(remoteSessionId: session.remoteSessionId)
            }
            remotelyDeletedSessionIds.insert(session.remoteSessionId)
            localActionGeneration += 1
            lastLocalAction[session.remoteSessionId] = localActionGeneration
            // The relist below shows the deletion; a list page read before it
            // must not bring the row back once that read finishes.
            if listReadsInFlight > 0 { pendingChanges.append(([], [session.remoteSessionId])) }
        }

        try await refreshAfterDeletion()
        if removeLocalHistory, let localSessionId = session.localSessionId {
            do {
                try await manager.deletePersistedSession(id: localSessionId)
            } catch {
                // Keep the row for a local-cleanup retry: drop the queued
                // removal so a pending read's replay does not hide it again.
                pendingChanges.removeAll { $0.changed.isEmpty && $0.removed == [session.remoteSessionId] }
                if !sessions.contains(where: { $0.remoteSessionId == session.remoteSessionId }) {
                    sessions.append(session)
                }
                throw error
            }
        }
    }

    public func removeLocalHistory(
        for session: ACPDiscoveredSession,
        manager: ACPSessionManager
    ) async throws {
        guard let localSessionId = session.localSessionId else { return }
        guard await beginDeletion(session.remoteSessionId) else { return }
        defer { finishDeletion(session.remoteSessionId) }
        try await manager.deletePersistedSession(id: localSessionId)
        localActionGeneration += 1
        lastLocalAction[session.remoteSessionId] = localActionGeneration
        handle?.forgetLocalCopy(localSessionId, of: session.remoteSessionId)
        // Replayed after any pending read, like the other local actions, so
        // an older page cannot bring the Alas copy back.
        if var current = sessions.first(where: { $0.remoteSessionId == session.remoteSessionId }) {
            current.localSessionId = nil
            applyLiveChanges(changed: [current], removed: [])
        }
        try await refreshAfterDeletion()
    }

    private func refreshAfterDeletion() async throws {
        // A pending filter load replaces the rows itself: it reads again after
        // this local action, and its replay drops a deleted row. Clearing the
        // rows here would leave them empty if that load then fails.
        guard let handle, filterLoadsInFlight == 0 else { return }
        let previous = sessions
        // A Load more still running reads from the old cursor: drop it.
        filterGeneration += 1
        handle.refresh()
        replaceSessionsOnNextLoad = true
        sessions = []
        do {
            try await loadMore()
            firstPageIds = Set(sessions.map(\.remoteSessionId))
        } catch {
            sessions = previous
            throw error
        }
    }

    public func start(
        manager: ACPSessionManager,
        agentId: String,
        worktreeResolver: (@MainActor (String) -> ACPSessionBrowserTarget?)? = nil
    ) async {
        guard phase == .idle, !stopped else { return }
        phase = .loading
        do {
            let handle = try await manager.makeSessionDiscoveryHandle(
                agentId: agentId,
                worktreeResolver: worktreeResolver
            )
            guard !stopped else {
                await handle.close()
                return
            }
            self.handle = handle
            capabilities = handle.capabilities
            sessionIndex = handle.sessionIndex
            try await loadMore()
            firstPageIds = Set(sessions.map(\.remoteSessionId))
            phase = .ready
            await startSubscription()
        } catch ACPSessionDiscoveryError.listingUnsupported {
            phase = .unsupported
        } catch ACPSessionDiscoveryError.setupRequired(let reason) {
            phase = .needsSetup(reason)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    public func loadMore() async throws {
        // The handle still holds the previous filter's cursor until the
        // pending filter page commits.
        guard let handle, filterLoadsInFlight == 0 else { return }
        let generation = filterGeneration
        listReadsStarted += 1
        do {
            let page = try await handle.loadNextPage { generation == self.filterGeneration }
            guard generation == filterGeneration else { return }
            if replaceSessionsOnNextLoad {
                sessions = page
                notePageRows(page)
                replaceSessionsOnNextLoad = false
                paginationError = nil
                return
            }
            var known = Set(sessions.map(\.remoteSessionId))
            sessions.append(contentsOf: page.filter { known.insert($0.remoteSessionId).inserted })
            notePageRows(page)
            paginationError = nil
        } catch {
            paginationError = error.localizedDescription
            throw error
        }
    }

    /// Whether the scope chips may offer every linked worktree.
    public var canListLinkedWorktrees: Bool { handle?.canListLinkedWorktrees == true }

    /// Switches scope or archive filter and shows its first page. When
    /// changes overlap, only the latest one's page is shown; a failed change
    /// restores the previous filter and keeps its rows.
    public func setFilter(_ newFilter: ACPSessionBrowserFilter) async throws {
        guard let handle, sessionIndex != nil, newFilter != filter,
              !newFilter.includeLinkedWorktrees || handle.canListLinkedWorktrees
        else { return }
        let previous = appliedFilter
        filter = newFilter
        filterGeneration += 1
        let generation = filterGeneration
        filterLoadsInFlight += 1
        beginListRead()
        defer {
            filterLoadsInFlight -= 1
            finishListRead()
        }
        do {
            var actions = localActionGeneration
            var page = try await handle.firstPage(filter: newFilter)
            // A page read across a local action may predate it: read again.
            for _ in 1 ..< 3 where actions != localActionGeneration && generation == filterGeneration {
                actions = localActionGeneration
                page = try await handle.firstPage(filter: newFilter)
            }
            guard generation == filterGeneration, !stopped else { return }
            handle.commit(filter: newFilter, cursor: page.cursor)
            appliedFilter = newFilter
            sessions = page.rows
            notePageRows(page.rows)
            firstPageIds = Set(page.rows.map(\.remoteSessionId))
            replaceSessionsOnNextLoad = false
            paginationError = nil
        } catch {
            guard generation == filterGeneration else { return }
            filter = previous
            throw error
        }
    }

    /// Reads the first page again and merges it into the listed rows, keeping
    /// rows loaded from later pages.
    public func reconcile() async {
        // A pending filter change replaces the rows anyway.
        guard let handle, !stopped, filterLoadsInFlight == 0 else { return }
        let generation = filterGeneration
        let listedFilter = appliedFilter
        let actions = localActionGeneration
        beginListRead()
        defer { finishListRead() }
        guard let page = try? await handle.firstPage(filter: listedFilter),
              generation == filterGeneration, listedFilter == appliedFilter, filterLoadsInFlight == 0,
              actions == localActionGeneration
        else { return }
        notePageRows(page.rows)
        sessions = ACPSessionBrowserReducer.reconciling(
            firstPage: page.rows,
            hasMorePages: page.cursor != nil,
            previousFirstPage: firstPageIds,
            rows: sessions,
            filter: appliedFilter,
            browsingWorktreeId: handle.browsingWorktreeId
        )
        firstPageIds = Set(page.rows.map(\.remoteSessionId))
    }

    /// Renames the agent's session and its Alas copy, in whichever worktree
    /// it lives, through `renameLocal`, which returns once the title is
    /// stored, with a closure that restores the previous title and its
    /// source. The Alas copy is renamed first: a row is listed with its Alas
    /// title, so a change notification the rename triggers must already read
    /// the new one. A failed rename runs the restore.
    public func rename(
        _ session: ACPDiscoveredSession,
        to title: String,
        renameLocal: @MainActor (_ localSessionId: String, _ title: String) async -> (@MainActor () async -> Void)?
    ) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let handle, !trimmed.isEmpty else { return }
        guard updatingSessionIds.insert(session.remoteSessionId).inserted else { return }
        defer { updatingSessionIds.remove(session.remoteSessionId) }
        var restoreLocal: (@MainActor () async -> Void)?
        if let localSessionId = session.localSessionId {
            restoreLocal = await renameLocal(localSessionId, trimmed)
        }
        do {
            try await handle.renameSession(remoteSessionId: session.remoteSessionId, title: trimmed)
        } catch {
            // Only an Alas copy was changed before the request; a row without
            // one shows whatever the agent last reported.
            if let restoreLocal {
                await restoreLocal()
                // A page read meanwhile may show the stored, now undone title:
                // drop such pages and show the original title again.
                localActionGeneration += 1
                lastLocalAction[session.remoteSessionId] = localActionGeneration
                if var current = sessions.first(where: { $0.remoteSessionId == session.remoteSessionId }) {
                    current.title = session.title
                    applyLiveChanges(changed: [current], removed: [])
                }
            }
            throw error
        }
        localActionGeneration += 1
        lastLocalAction[session.remoteSessionId] = localActionGeneration
        // Patched on the row as it is now, and replayed after any pending
        // list read so an older page cannot bring the old title back.
        if var updated = sessions.first(where: { $0.remoteSessionId == session.remoteSessionId }) {
            updated.title = trimmed
            applyLiveChanges(changed: [updated], removed: [])
        }
    }

    /// Archives or unarchives the agent's session. The Alas session, if any,
    /// is left alone: archive is neither remote deletion nor local removal.
    public func setArchived(_ archived: Bool, for session: ACPDiscoveredSession) async throws {
        guard let handle else { return }
        guard updatingSessionIds.insert(session.remoteSessionId).inserted else { return }
        defer { updatingSessionIds.remove(session.remoteSessionId) }
        try await handle.setArchived(archived, remoteSessionId: session.remoteSessionId)
        localActionGeneration += 1
        lastLocalAction[session.remoteSessionId] = localActionGeneration
        // Patch the newest version of the row: a live update (often the
        // archive notification itself) may have changed or moved it while
        // the request ran.
        var updated = latestLiveRows[session.remoteSessionId]
            ?? sessions.first { $0.remoteSessionId == session.remoteSessionId }
            ?? session
        updated.index = (updated.index ?? .init()).with(archived: archived)
        // Like a pushed change: a list page read before the archive must not
        // bring the row back.
        applyLiveChanges(changed: [updated], removed: [])
    }

    /// A committed page is at least as new as the live rows cached before
    /// it; changes buffered meanwhile are replayed after it and win again.
    private func notePageRows(_ rows: [ACPDiscoveredSession]) {
        for row in rows { latestLiveRows[row.remoteSessionId] = row }
    }

    private func applyLiveChanges(changed: [ACPDiscoveredSession], removed: [String]) {
        guard let handle else { return }
        // Applied now so the listed rows stay current, and replayed after the
        // pending read in case its page predates the change.
        if listReadsInFlight > 0 { pendingChanges.append((changed, removed)) }
        for row in changed { latestLiveRows[row.remoteSessionId] = row }
        sessions = ACPSessionBrowserReducer.applying(
            changed: changed, removed: removed, to: sessions, filter: appliedFilter,
            browsingWorktreeId: handle.browsingWorktreeId
        )
    }

    private func beginListRead() {
        listReadsInFlight += 1
        listReadsStarted += 1
    }

    /// Ends a list read after its page was applied (or dropped). The last one
    /// to finish replays the changes buffered meanwhile, whatever order the
    /// reads complete in.
    private func finishListRead() {
        listReadsInFlight -= 1
        guard listReadsInFlight == 0, let handle else { return }
        let changes = pendingChanges
        pendingChanges = []
        for change in changes {
            // The page applied before the replay cached older rows.
            for row in change.changed { latestLiveRows[row.remoteSessionId] = row }
            sessions = ACPSessionBrowserReducer.applying(
                changed: change.changed, removed: change.removed, to: sessions, filter: appliedFilter,
                browsingWorktreeId: handle.browsingWorktreeId
            )
        }
    }

    private func startSubscription() async {
        guard let handle, !stopped,
              let stream = try? await handle.subscribe(stamp: { [weak self] in
                  .init(localActions: self?.localActionGeneration ?? 0, listReads: self?.listReadsStarted ?? 0)
              })
        else { return }
        subscriptionTask = Task { @MainActor [weak self] in
            for await (changed, removed, stamp) in stream {
                guard let self, !self.stopped else { break }
                let current = ACPSessionBrowserReducer.droppingRows(
                    changed, predating: stamp, listReadsStarted: self.listReadsStarted,
                    lastLocalAction: self.lastLocalAction
                )
                self.applyLiveChanges(changed: current, removed: removed)
            }
        }
        // Rows that changed between the first page and the subscription.
        await reconcile()
        reconcileTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.reconcileInterval)
                guard let self, !self.stopped, !Task.isCancelled else { return }
                await self.reconcile()
            }
        }
    }

    public func stop() async {
        stopped = true
        reconcileTask?.cancel()
        subscriptionTask?.cancel()
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

    public init() {}
}

/// What a session browser row says and allows.
public enum ACPSessionBrowserRowPolicy {
    /// A row opens only in its own Alas worktree: one outside every Alas
    /// worktree is browse-only.
    public static func canOpen(_ session: ACPDiscoveredSession, capabilities: ACPSessionDiscoveryCapabilities?) -> Bool {
        // Codex refuses to load an archived thread, and loading one does not
        // unarchive it in either adapter: unarchive first.
        guard session.worktreeId != nil, !session.isArchived else { return false }
        return session.isAlreadyInAlas
            || (capabilities?.canOpenRemoteSession == true && session.isCompatibleWithAlas)
    }

    public static func stateLabel(_ state: String?) -> String? {
        switch state {
        case "running": "Running"
        case "requires_action": "Needs input"
        case "reviewing": "Reviewing"
        case "error": "Failed"
        default: nil
        }
    }

    /// The one-line detail under the title. `worktreeName` names the row's
    /// worktree when it is not the browsing one.
    public static func detail(
        for session: ACPDiscoveredSession,
        browsingWorktreeId: String?,
        worktreeName: String?,
        canOpen: Bool,
        formatDate: (Date) -> String
    ) -> String {
        var parts: [String] = []
        if session.worktreeId == nil {
            parts.append("Not an Alas worktree: \(URL(fileURLWithPath: session.cwd).lastPathComponent)")
        } else if session.worktreeId != browsingWorktreeId {
            parts.append(worktreeName ?? URL(fileURLWithPath: session.cwd).lastPathComponent)
        }
        if session.isArchived {
            parts.append("Archived, unarchive to open")
        } else if session.isAlreadyInAlas {
            parts.append("Already in Alas")
        } else if !session.isCompatibleWithAlas {
            parts.append("Uses unsupported additional folders")
        } else if !canOpen, session.worktreeId != nil {
            parts.append("Browsing only")
        }
        if let state = stateLabel(session.index?.state) { parts.append(state) }
        if let date = session.lastActivity {
            parts.append(formatDate(date))
        } else if parts.isEmpty {
            parts.append("Agent history")
        }
        if let model = session.index?.model, !model.isEmpty { parts.append(model) }
        return parts.joined(separator: " · ")
    }
}

/// The session browser's highlight: row 0 is "New chat", row `i + 1` is
/// session `i`.
public enum ACPSessionBrowserSelection {
    /// The index of the same session after the rows changed, or "New chat"
    /// when it left the list.
    public static func remapped(_ index: Int, from old: [String], to new: [String]) -> Int {
        guard index > 0, old.indices.contains(index - 1) else { return min(index, new.count) }
        return new.firstIndex(of: old[index - 1]).map { $0 + 1 } ?? 0
    }
}
