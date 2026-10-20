import Foundation
import Observation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP
import AlasSessions

/// ISO 8601 timestamps of `session/list` rows, with or without fractional
/// seconds (Claude sends `.000Z`, Codex whole seconds).
extension ACPSessionIndexRowMeta {
    func with(archived: Bool) -> Self {
        var copy = self
        copy.archived = archived
        return copy
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
    /// Every list read started, Load more included; each read's index is
    /// the count after it started.
    private var listReadsStarted = 0
    /// The index of the newest list read whose applied page showed each
    /// session, by agent session id.
    private var pageReadIndex: [String: Int] = [:]
    /// Bumped by every completed local action (rename, archive, delete,
    /// remove from Alas). A first page read across one may predate it: a
    /// filter load reads again, a reconcile drops its page.
    private var localActionGeneration = 0
    /// The newest version of each row seen in a live change, also after it
    /// left the current filter, so a local patch starts from the newest data.
    private var latestLiveRows: [String: ACPDiscoveredSession] = [:]
    /// Sessions deleted agent-side whose Alas copy could not be removed:
    /// their row stays for a Remove from Alas retry, whatever removals the
    /// agent later reports.
    private var cleanupRetryRows: [String: ACPDiscoveredSession] = [:]
    private var cleanupRetryIds: Set<String> { Set(cleanupRetryRows.keys) }
    /// The `localActionGeneration` each session's last local action ended at.
    private var lastLocalAction: [String: Int] = [:]
    /// Live changes that arrived while a list read was in flight. They are
    /// applied at once and again when the last read finishes, so a page read
    /// before a change cannot undo it.
    private var pendingChanges: [PendingChange] = []

    /// A change waiting for the pending list reads to end.
    private enum PendingChange {
        /// Agent-reported rows and removals; `stamp` is nil for removals of
        /// this browser's own deletions.
        case live(changed: [ACPDiscoveredSession], removed: [String], stamp: ACPSessionBrowserStamp?)
        /// A local action's effect, applied to the row as it is at replay
        /// time so data a later page brought is kept. `fallback` is used when
        /// the row is not known at all.
        case patch(id: String, fallback: ACPDiscoveredSession?, apply: (inout ACPDiscoveredSession) -> Void)
        /// A cleanup-retry row, put back after a page that left it out.
        case restore(ACPDiscoveredSession)
    }
    /// Rows with a rename or archive request in flight.
    public private(set) var updatingSessionIds: Set<String> = []
    private var handle: ACPSessionDiscoveryHandle?
    /// Bumped by every filter change; a load that started under an older
    /// generation is discarded.
    private var filterGeneration = 0
    private var subscriptionTask: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?
    /// While the browser is open, the first page is read again this often to
    /// pick up changes a subscription missed or could not deliver. It stops
    /// when the browser stops.
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
            if listReadsInFlight > 0 { pendingChanges.append(.live(changed: [], removed: [session.remoteSessionId], stamp: nil)) }
        }

        try await refreshAfterDeletion()
        if removeLocalHistory, let localSessionId = session.localSessionId {
            do {
                try await manager.deletePersistedSession(id: localSessionId)
            } catch {
                // Keep the row for a local-cleanup retry: drop the queued
                // removal, and ignore later ones, until the retry succeeds.
                cleanupRetryRows[session.remoteSessionId] = session
                pendingChanges.removeAll {
                    if case .live(let changed, let removed, nil) = $0 {
                        return changed.isEmpty && removed == [session.remoteSessionId]
                    }
                    return false
                }
                restoreRetryRow(session)
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
        cleanupRetryRows[session.remoteSessionId] = nil
        localActionGeneration += 1
        lastLocalAction[session.remoteSessionId] = localActionGeneration
        handle?.forgetLocalCopy(localSessionId, of: session.remoteSessionId)
        // Replayed after any pending read, like the other local actions, so
        // an older page cannot bring the Alas copy back.
        applyLocalPatch(id: session.remoteSessionId) { $0.localSessionId = nil }
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
        // The handle still holds the previous filter's cursor until the
        // pending filter page commits.
        guard let handle, filterLoadsInFlight == 0 else { return }
        let generation = filterGeneration
        // Buffers live changes too: a removal that lands while this page is
        // in flight is replayed after the page is appended.
        let read = beginListRead()
        defer { finishListRead(read) }
        do {
            let page = try await handle.loadNextPage { generation == self.filterGeneration }
            guard generation == filterGeneration else { return }
            if replaceSessionsOnNextLoad {
                sessions = page
                reapplyRetryRows()
                notePageRows(page, read: read)
                replaceSessionsOnNextLoad = false
                paginationError = nil
                return
            }
            var known = Set(sessions.map(\.remoteSessionId))
            sessions.append(contentsOf: page.filter { known.insert($0.remoteSessionId).inserted })
            notePageRows(page, read: read)
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
        let read = beginListRead()
        defer {
            filterLoadsInFlight -= 1
            finishListRead(read)
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
            reapplyRetryRows()
            notePageRows(page.rows, read: read)
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
        let read = beginListRead()
        defer { finishListRead(read) }
        guard let page = try? await handle.firstPage(filter: listedFilter),
              generation == filterGeneration, listedFilter == appliedFilter, filterLoadsInFlight == 0,
              actions == localActionGeneration
        else { return }
        // Rows the page lacks but cannot prove gone: read past the boundary
        // until each is found or provably absent, so a missed deletion is
        // not kept forever.
        var confirmedGone: Set<String> = []
        var found: [ACPDiscoveredSession] = []
        // Every listed row, also ones loaded with Load more: a missed removal
        // beyond the first page is settled the same way. Cleanup-retry rows
        // are left out: the agent deleted them and never lists them again.
        let listedIds = Set(sessions.map(\.remoteSessionId)).subtracting(cleanupRetryIds)
        let candidates = ACPSessionBrowserReducer.unsettledCandidates(
            firstPage: page.rows, listedBefore: listedIds, rows: sessions
        )
        if !candidates.isEmpty, var cursor = page.cursor {
            let candidateDates = sessions.filter { candidates.contains($0.remoteSessionId) }.map(\.lastActivity)
            // Rows come newest first: once a row older than every candidate
            // shows up, an unseen dated candidate is gone. An undated one can
            // be anywhere, so only the list's end settles it.
            let oldestCandidate = candidateDates.contains(nil) ? nil : candidateDates.compactMap { $0 }.min()
            var seen: Set<String> = []
            // Until settled or the list ends, however long; a cursor the
            // adapter repeats would never end, so it stops the scan.
            var cursorsRead: Set<String> = []
            while cursorsRead.insert(cursor).inserted {
                guard let next = try? await handle.page(after: cursor, filter: listedFilter) else { break }
                seen.formUnion(next.rows.map(\.remoteSessionId))
                found += next.rows.filter { candidates.contains($0.remoteSessionId) }
                let pastCandidates = oldestCandidate.map { oldest in
                    next.rows.contains { ($0.lastActivity ?? .distantFuture) < oldest }
                } ?? false
                if candidates.isSubset(of: seen) || next.cursor == nil || pastCandidates {
                    confirmedGone = candidates.subtracting(seen)
                    break
                }
                cursor = next.cursor!
            }
            guard generation == filterGeneration, listedFilter == appliedFilter, actions == localActionGeneration else { return }
        }
        notePageRows(page.rows, read: read)
        let listedBefore = Set(sessions.map(\.remoteSessionId))
        sessions = ACPSessionBrowserReducer.reconciling(
            firstPage: page.rows,
            hasMorePages: page.cursor != nil,
            listedBefore: listedIds,
            rows: sessions,
            filter: appliedFilter,
            browsingWorktreeId: handle.browsingWorktreeId,
            confirmedGone: confirmedGone
        )
        // Rows the boundary scan found are current too.
        if !found.isEmpty {
            notePageRows(found, read: read)
            sessions = ACPSessionBrowserReducer.applying(
                changed: found, removed: [], to: sessions, filter: appliedFilter,
                browsingWorktreeId: handle.browsingWorktreeId
            )
        }
        reapplyRetryRows()
        // This read proved those sessions gone: an older notification about
        // them is superseded like one about a row the page showed.
        for id in listedBefore.subtracting(sessions.map(\.remoteSessionId)) {
            pageReadIndex[id] = max(pageReadIndex[id] ?? 0, read)
        }
    }

    /// Renames the agent's session and its Alas copy, in whichever worktree
    /// it lives, through `renameLocal`, which returns once the title is
    /// stored, with a closure that restores the previous title and its
    /// source and returns the title stored afterwards. The Alas copy is renamed first: a row is listed with its Alas
    /// title, so a change notification the rename triggers must already read
    /// the new one. A failed rename runs the restore.
    public func rename(
        _ session: ACPDiscoveredSession,
        to title: String,
        renameLocal: @MainActor (_ localSessionId: String, _ title: String) async throws -> (@MainActor () async throws -> String)?
    ) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let handle, !trimmed.isEmpty else { return }
        guard updatingSessionIds.insert(session.remoteSessionId).inserted else { return }
        defer { updatingSessionIds.remove(session.remoteSessionId) }
        var restoreLocal: (@MainActor () async throws -> String)?
        if let localSessionId = session.localSessionId {
            // A failure to store the Alas title stops here: the agent is not
            // renamed unless the Alas copy was.
            restoreLocal = try await renameLocal(localSessionId, trimmed)
        }
        do {
            try await handle.renameSession(remoteSessionId: session.remoteSessionId, title: trimmed)
        } catch {
            // Only an Alas copy was changed before the request; a row without
            // one shows whatever the agent last reported.
            // The row shows the Alas title as stored: the original if the
            // restore stored it again, else the new one, which stays stored.
            if let restoreLocal {
                // The title stored after the rollback: the original, a newer
                // rename's, or this one's if the rollback failed.
                let stored = (try? await restoreLocal()) ?? trimmed
                // A page read meanwhile may show another title: drop such pages.
                localActionGeneration += 1
                lastLocalAction[session.remoteSessionId] = localActionGeneration
                applyLocalPatch(id: session.remoteSessionId) { $0.title = stored }
            }
            throw error
        }
        localActionGeneration += 1
        lastLocalAction[session.remoteSessionId] = localActionGeneration
        // Patched on the row as it is now, and replayed after any pending
        // list read so an older page cannot bring the old title back.
        applyLocalPatch(id: session.remoteSessionId) { $0.title = trimmed }
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
        // the request ran. Replayed after any pending list read.
        applyLocalPatch(id: session.remoteSessionId, fallback: session) {
            $0.index = ($0.index ?? .init()).with(archived: archived)
        }
    }

    /// A committed page is at least as new as the live rows cached before
    /// it; changes buffered meanwhile are replayed after it and win again.
    private func notePageRows(_ rows: [ACPDiscoveredSession], read: Int) {
        for row in rows {
            latestLiveRows[row.remoteSessionId] = row
            pageReadIndex[row.remoteSessionId] = max(pageReadIndex[row.remoteSessionId] ?? 0, read)
        }
    }

    /// `stamp` is set for a notification; a local action's own result has
    /// none and is never superseded.
    private func applyLiveChanges(
        changed: [ACPDiscoveredSession],
        removed: [String],
        stamp: ACPSessionBrowserStamp? = nil
    ) {
        guard let handle else { return }
        let removed = removed.filter { !cleanupRetryIds.contains($0) }
        // Applied now so the listed rows stay current, and replayed after the
        // pending reads in case a page that predates the change lands later.
        if listReadsInFlight > 0 { pendingChanges.append(.live(changed: changed, removed: removed, stamp: stamp)) }
        for row in changed { latestLiveRows[row.remoteSessionId] = row }
        // A removed session must not come back through a later local patch.
        for id in removed { latestLiveRows[id] = nil }
        sessions = ACPSessionBrowserReducer.applying(
            changed: changed, removed: removed, to: sessions, filter: appliedFilter,
            browsingWorktreeId: handle.browsingWorktreeId
        )
    }

    /// The newest known version of a session's row.
    private func currentRow(_ id: String) -> ACPDiscoveredSession? {
        latestLiveRows[id] ?? sessions.first { $0.remoteSessionId == id }
    }

    /// Applies a local action's effect to the row as it is now, and again
    /// to the row as it is after the pending list reads.
    private func applyLocalPatch(
        id: String,
        fallback: ACPDiscoveredSession? = nil,
        _ apply: @escaping (inout ACPDiscoveredSession) -> Void
    ) {
        if listReadsInFlight > 0 { pendingChanges.append(.patch(id: id, fallback: fallback, apply: apply)) }
        reducePatch(id: id, fallback: fallback, apply)
    }

    private func reducePatch(id: String, fallback: ACPDiscoveredSession?, _ apply: (inout ACPDiscoveredSession) -> Void) {
        guard let handle, var row = currentRow(id) ?? fallback else { return }
        apply(&row)
        latestLiveRows[id] = row
        sessions = ACPSessionBrowserReducer.applying(
            changed: [row], removed: [], to: sessions, filter: appliedFilter,
            browsingWorktreeId: handle.browsingWorktreeId
        )
    }

    /// Puts a cleanup-retry row back if it matches what the browser lists,
    /// now and after the pending list reads.
    private func restoreRetryRow(_ row: ACPDiscoveredSession) {
        if listReadsInFlight > 0 { pendingChanges.append(.restore(row)) }
        reduceRestore(row)
    }

    /// A page from the agent never lists a session it deleted: put back the
    /// cleanup-retry rows that match the listed filter after each one.
    private func reapplyRetryRows() {
        for row in cleanupRetryRows.values { reduceRestore(row) }
    }

    private func reduceRestore(_ row: ACPDiscoveredSession) {
        guard let handle, !sessions.contains(where: { $0.remoteSessionId == row.remoteSessionId }) else { return }
        sessions = ACPSessionBrowserReducer.applying(
            changed: [row], removed: [], to: sessions, filter: appliedFilter,
            browsingWorktreeId: handle.browsingWorktreeId
        )
    }

    /// Starts a list read, which buffers live changes until it ends, and
    /// returns its index.
    private func beginListRead() -> Int {
        listReadsInFlight += 1
        listReadsStarted += 1
        return listReadsStarted
    }

    /// Ends a list read after its page was applied (or dropped). The last one
    /// to finish replays the changes buffered meanwhile, whatever order the
    /// reads complete in.
    private func finishListRead(_ read: Int) {
        listReadsInFlight -= 1
        guard listReadsInFlight == 0, let handle else { return }
        let changes = pendingChanges
        pendingChanges = []
        for change in changes {
            let (changedRows, removedIds, stamp): ([ACPDiscoveredSession], [String], ACPSessionBrowserStamp?)
            switch change {
            case .patch(let id, let fallback, let apply):
                reducePatch(id: id, fallback: fallback, apply)
                continue
            case .restore(let row):
                reduceRestore(row)
                continue
            case .live(let changed, let removed, let liveStamp):
                (changedRows, removedIds, stamp) = (changed, removed, liveStamp)
            }
            // A page that started after the change and showed a session is newer.
            var (changed, removed) = stamp.map {
                ACPSessionBrowserReducer.unsuperseded(
                    changed: changedRows, removed: removedIds, stamp: $0, pageReadIndex: pageReadIndex
                )
            } ?? (changedRows, removedIds)
            removed.removeAll { cleanupRetryIds.contains($0) }
            for id in removed { latestLiveRows[id] = nil }
            // The page applied before the replay cached older rows.
            for row in changed { latestLiveRows[row.remoteSessionId] = row }
            sessions = ACPSessionBrowserReducer.applying(
                changed: changed, removed: removed, to: sessions, filter: appliedFilter,
                browsingWorktreeId: handle.browsingWorktreeId
            )
        }
    }

    /// Subscribes to list changes when the agent can, and relists the first
    /// page periodically either way: a subscription is best effort, and one
    /// that could not be set up must not leave the rows stale.
    private func startSubscription() async {
        guard let handle, !stopped, handle.sessionIndex != nil else { return }
        if let stream = try? await handle.subscribe(stamp: { [weak self] in
            .init(localActions: self?.localActionGeneration ?? 0, listReads: self?.listReadsStarted ?? 0)
        }) {
            consume(stream)
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

    private func consume(
        _ stream: AsyncStream<(changed: [ACPDiscoveredSession], removed: [String], stamp: ACPSessionBrowserStamp)>
    ) {
        subscriptionTask = Task { @MainActor [weak self] in
            for await (changed, removed, stamp) in stream {
                guard let self, !self.stopped else { break }
                let current = ACPSessionBrowserReducer.droppingRows(
                    changed, predating: stamp, lastLocalAction: self.lastLocalAction
                )
                // Removals too: one read before a later archive or unarchive
                // must not hide the row that action put back.
                let currentRemovals = removed.filter { (self.lastLocalAction[$0] ?? Int.min) <= stamp.localActions }
                let fresh = ACPSessionBrowserReducer.unsuperseded(
                    changed: current, removed: currentRemovals, stamp: stamp, pageReadIndex: self.pageReadIndex
                )
                self.applyLiveChanges(changed: fresh.changed, removed: fresh.removed, stamp: stamp)
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
