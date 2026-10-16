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
    public let localSessionId: String?
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
    public static func applying(
        changed: [ACPDiscoveredSession],
        removed: [String],
        to rows: [ACPDiscoveredSession],
        filter: ACPSessionBrowserFilter
    ) -> [ACPDiscoveredSession] {
        let removedIds = Set(removed)
        var result = rows.filter { !removedIds.contains($0.remoteSessionId) }
        for row in changed where !removedIds.contains(row.remoteSessionId) {
            let existing = result.firstIndex { $0.remoteSessionId == row.remoteSessionId }
            guard row.isArchived == filter.showArchived else {
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
    private let agentId: String
    private let cwd: String
    private let persistence: ACPSessionPersistence
    private let connection: ACPConnection
    /// Maps a row's cwd to the Alas worktree whose path it is, and that
    /// worktree's session store (each worktree has its own).
    private let worktreeResolver: @MainActor (String) -> ACPSessionBrowserTarget?
    private let onClosed: (@MainActor @Sendable () -> Void)?
    private var nextCursor: String?
    private var hasLoadedPage = false
    private var closed = false
    private var subscriptionId: String?
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
        let ownCWD = Self.standardized(cwd)
        let own = ACPSessionBrowserTarget(worktreeId: worktreeId, persistence: persistence)
        self.worktreeResolver = worktreeResolver ?? { Self.standardized($0) == ownCWD ? own : nil }
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

    /// Changes the scope and archive filter. Only an agent with the session
    /// index honors them; the next load starts from the first page.
    public func setFilter(_ filter: ACPSessionBrowserFilter) {
        guard sessionIndex != nil else { return }
        self.filter = filter
        refresh()
    }

    public func loadNextPage() async throws -> [ACPDiscoveredSession] {
        guard !closed, canLoadMore else { return [] }
        let (rows, cursor) = try await readPages(from: nextCursor)
        hasLoadedPage = true
        nextCursor = cursor
        return rows
    }

    /// The first page again, without moving the browser's own cursor, so a
    /// reconcile neither races nor undoes "Load more".
    public func firstPage() async throws -> [ACPDiscoveredSession] {
        guard !closed else { return [] }
        return try await readPages(from: nil).rows
    }

    private func readPages(from start: String?) async throws -> (rows: [ACPDiscoveredSession], cursor: String?) {
        let options = sessionIndex == nil ? nil : filter.listOptions
        var discovered: [ACPDiscoveredSession] = []
        var cursor = start
        var requests = 0
        repeat {
            let page = try await connection.listSessions(cwd: cwd, cursor: cursor, index: options)
            cursor = page.nextCursor
            requests += 1
            for info in page.sessions {
                if let row = await discoveredSession(info) { discovered.append(row) }
            }
        } while discovered.isEmpty && cursor != nil && requests < Self.maxPagesPerLoad
        return (discovered, cursor)
    }

    /// A browser row for `info`, or nil when it is outside the browser's
    /// scope: without the linked-worktree scope only this worktree's exact
    /// cwd is listed, as before the session index.
    private func discoveredSession(_ info: ACPAgentSessionInfo) async -> ACPDiscoveredSession? {
        let target = worktreeResolver(info.cwd)
        let includeLinked = sessionIndex != nil && filter.includeLinkedWorktrees
        guard includeLinked || target?.worktreeId == worktreeId else { return nil }
        let local = try? await target?.persistence?.loadSession(agentId: agentId, remoteSessionId: info.sessionId)
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
    public func subscribe() async throws -> AsyncStream<(changed: [ACPDiscoveredSession], removed: [String])>? {
        guard !closed, sessionIndex?.listSubscribe == true, subscriptionId == nil else { return nil }
        // Subscribe before relisting: changes are tracked from the answer on.
        let id = try await connection.subscribeSessionList(cwd: cwd)
        subscriptionId = id
        let incoming = connection.client.sessionListChanges
        return AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                for await changes in incoming where changes.subscriptionId == id {
                    guard let self, !self.closed else { break }
                    var rows: [ACPDiscoveredSession] = []
                    for info in changes.sessions {
                        if let row = await self.discoveredSession(info) { rows.append(row) }
                    }
                    continuation.yield((rows, changes.removed))
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

    /// Adapters report the cwd with symlinks resolved (`/private/var/…`
    /// for `/var/…`), so both sides are compared that way.
    private nonisolated static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
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
    public private(set) var filter = ACPSessionBrowserFilter()
    /// Rows with a rename or archive request in flight.
    public private(set) var updatingSessionIds: Set<String> = []
    private var handle: ACPSessionDiscoveryHandle?
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

    public var canLoadMore: Bool { handle?.canLoadMore == true }

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

    public func removeLocalHistory(
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

    /// Switches scope or archive filter and reloads from the first page.
    public func setFilter(_ newFilter: ACPSessionBrowserFilter) async throws {
        guard let handle, sessionIndex != nil, newFilter != filter else { return }
        filter = newFilter
        handle.setFilter(newFilter)
        replaceSessionsOnNextLoad = true
        try await loadMore()
    }

    /// Reads the first page again and merges it into the listed rows, keeping
    /// rows loaded from later pages.
    public func reconcile() async {
        guard let handle, !stopped else { return }
        let reconciledFilter = filter
        guard let page = try? await handle.firstPage(), filter == reconciledFilter else { return }
        sessions = ACPSessionBrowserReducer.applying(changed: page, removed: [], to: sessions, filter: filter)
    }

    /// Renames the agent's session; on success `renameLocal` gets the Alas
    /// session id and new title so the Alas copy, in whichever worktree it
    /// lives, shows the same title.
    public func rename(
        _ session: ACPDiscoveredSession,
        to title: String,
        renameLocal: @MainActor (_ localSessionId: String, _ title: String) -> Void
    ) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let handle, !trimmed.isEmpty else { return }
        guard updatingSessionIds.insert(session.remoteSessionId).inserted else { return }
        defer { updatingSessionIds.remove(session.remoteSessionId) }
        try await handle.renameSession(remoteSessionId: session.remoteSessionId, title: trimmed)
        if let index = sessions.firstIndex(where: { $0.remoteSessionId == session.remoteSessionId }) {
            sessions[index].title = trimmed
        }
        if let localSessionId = session.localSessionId {
            renameLocal(localSessionId, trimmed)
        }
    }

    /// Archives or unarchives the agent's session. The Alas session, if any,
    /// is left alone: archive is neither remote deletion nor local removal.
    public func setArchived(_ archived: Bool, for session: ACPDiscoveredSession) async throws {
        guard let handle else { return }
        guard updatingSessionIds.insert(session.remoteSessionId).inserted else { return }
        defer { updatingSessionIds.remove(session.remoteSessionId) }
        try await handle.setArchived(archived, remoteSessionId: session.remoteSessionId)
        var updated = session
        updated.index = (session.index ?? .init()).with(archived: archived)
        sessions = ACPSessionBrowserReducer.applying(changed: [updated], removed: [], to: sessions, filter: filter)
    }

    private func startSubscription() async {
        guard let handle, !stopped,
              let stream = try? await handle.subscribe()
        else { return }
        subscriptionTask = Task { @MainActor [weak self] in
            for await (changed, removed) in stream {
                guard let self, !self.stopped else { break }
                self.sessions = ACPSessionBrowserReducer.applying(
                    changed: changed, removed: removed, to: self.sessions, filter: self.filter
                )
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
