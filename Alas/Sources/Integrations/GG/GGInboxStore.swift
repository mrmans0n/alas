import Foundation
import Observation

struct GGInboxRefreshProgress: Equatable {
    let completed: Int
    let total: Int
}

/// Project id → gg inbox triage state. One shared `gg inbox` process per
/// project, with bounded per-PR provider requests. Snapshots survive failures so the view can
/// show stale data alongside the error. All writes are value-diffed.
@MainActor
@Observable
final class GGInboxStore {
    static let shared = GGInboxStore()

    struct State: Equatable {
        var snapshot: GGInboxSnapshot? = nil
        var fetchedAt: Date? = nil
        var isRefreshing: Bool = false
        var refreshProgress: GGInboxRefreshProgress? = nil
        var lastError: String? = nil
        /// Includes merged and closed entries excluded from actionable buckets.
        /// Last known states survive partial/fatal refresh failures.
        var reviewStates: [GGInboxEntryIdentity: String] = [:]
    }

    var states: [String: State] = [:]
    @ObservationIgnored private var invalidationGenerations: [String: UInt64] = [:]
    @ObservationIgnored private var activeRefreshes: [String: UUID] = [:]
    @ObservationIgnored var onInvalidation: ((String) -> Void)?

    /// A snapshot older than `threshold` (or missing) should be refetched
    /// when the tab appears or regains focus.
    static func isStale(fetchedAt: Date?, now: Date, threshold: TimeInterval = 120) -> Bool {
        guard let fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) >= threshold
    }

    /// Join a tab-owned refresh before deciding whether another run is needed.
    /// Invalidation during that run leaves fetchedAt nil, so the background
    /// consumer follows it with one fresh pass instead of losing the request.
    func refreshIfStale(projectId: String, repoPath: String, service: GGService) async {
        while states[projectId]?.isRefreshing == true {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        guard !Task.isCancelled, Self.isStale(fetchedAt: states[projectId]?.fetchedAt, now: Date()) else { return }
        await refresh(projectId: projectId, repoPath: repoPath, service: service)
    }

    @discardableResult
    func refresh(
        projectId: String,
        repoPath: String,
        service: GGService,
        now: () -> Date = Date.init
    ) async -> Bool {
        if states[projectId]?.isRefreshing == true { return false }
        let refreshId = UUID()
        activeRefreshes[projectId] = refreshId
        defer {
            if activeRefreshes[projectId] == refreshId { activeRefreshes[projectId] = nil }
        }
        let generation = invalidationGenerations[projectId, default: 0]
        var state = states[projectId] ?? State()
        let rollbackSnapshot = state.snapshot
        let rollbackFetchedAt = state.fetchedAt
        var partialBuckets = GGInboxBuckets()
        var partialStackErrors: [GGInboxStackError] = []
        var seenIdentities: Set<GGInboxEntryIdentity> = []
        var sawSummary = false
        state.isRefreshing = true
        state.refreshProgress = nil
        write(projectId, state)
        do {
            for try await event in service.inboxStream(repoPath: repoPath) {
                guard invalidationGenerations[projectId, default: 0] == generation else {
                    continue
                }

                var publishPartial = false
                switch event {
                case .start(let total, _):
                    state.refreshProgress = .init(completed: 0, total: total)
                case .stackError(let error):
                    partialStackErrors.append(error)
                case .entry(let payload):
                    seenIdentities.insert(payload.entry.identity)
                    state.reviewStates[payload.entry.identity] = payload.remoteState
                    state.refreshProgress = .init(completed: payload.completed, total: payload.totalCandidates)
                    if payload.included, let bucket = payload.bucket {
                        partialBuckets.insert(payload.entry, into: bucket)
                    }
                    publishPartial = true
                case .entryError(let payload):
                    seenIdentities.insert(payload.failedEntry.identity)
                    state.refreshProgress = .init(completed: payload.completed, total: payload.totalCandidates)
                    partialBuckets.insert(payload.failedEntry, into: .refreshFailed)
                    publishPartial = true
                case .summary(let snapshot):
                    let failedStacks = Set(snapshot.stackErrors.map(\.stackName))
                    state.reviewStates = state.reviewStates.filter {
                        seenIdentities.contains($0.key) || failedStacks.contains($0.key.stackName)
                    }
                    state.snapshot = snapshot
                    state.fetchedAt = now()
                    state.refreshProgress = nil
                    state.lastError = nil
                    sawSummary = true
                case .error:
                    preconditionFailure("GGService intercepts fatal inbox events")
                }

                if publishPartial {
                    state.snapshot = GGInboxSnapshot(
                        totalItems: GGInboxBucket.allCases.reduce(0) { $0 + $1.entries(in: partialBuckets).count },
                        buckets: partialBuckets,
                        stackErrors: partialStackErrors
                    )
                }
                guard invalidationGenerations[projectId, default: 0] == generation else {
                    continue
                }
                write(projectId, state)
            }
        } catch let error as GGServiceError {
            guard invalidationGenerations[projectId, default: 0] == generation else {
                finishInvalidatedRefresh(projectId: projectId, refreshId: refreshId, rollbackSnapshot: rollbackSnapshot)
                return true
            }
            state.snapshot = rollbackSnapshot
            state.fetchedAt = rollbackFetchedAt
            state.refreshProgress = nil
            state.lastError = error.userMessage
        } catch {
            guard invalidationGenerations[projectId, default: 0] == generation else {
                finishInvalidatedRefresh(projectId: projectId, refreshId: refreshId, rollbackSnapshot: rollbackSnapshot)
                return true
            }
            state.snapshot = rollbackSnapshot
            state.fetchedAt = rollbackFetchedAt
            state.refreshProgress = nil
            state.lastError = error.localizedDescription
        }
        guard invalidationGenerations[projectId, default: 0] == generation else {
            finishInvalidatedRefresh(projectId: projectId, refreshId: refreshId, rollbackSnapshot: rollbackSnapshot)
            return true
        }
        if !sawSummary && state.lastError == nil {
            state.snapshot = rollbackSnapshot
            state.fetchedAt = rollbackFetchedAt
            state.refreshProgress = nil
            state.lastError = "gg inbox ended without a summary event."
        }
        state.isRefreshing = false
        write(projectId, state)
        return true
    }

    /// Expires cached freshness while retaining the last visible result.
    func invalidate(projectId: String) {
        invalidationGenerations[projectId, default: 0] &+= 1
        defer { onInvalidation?(projectId) }
        guard var state = states[projectId] else { return }
        state.fetchedAt = nil
        write(projectId, state)
    }

    /// Drops states for projects that no longer exist.
    func prune(keepingProjectIds: Set<String>) {
        for projectId in states.keys where !keepingProjectIds.contains(projectId) {
            remove(projectId: projectId)
        }
    }

    /// A replaced repository must not inherit PR numbers or freshness from
    /// the repository that previously occupied this project ID.
    func remove(projectId: String) {
        invalidationGenerations[projectId, default: 0] &+= 1
        activeRefreshes[projectId] = nil
        states[projectId] = nil
    }

    private func write(_ projectId: String, _ new: State) {
        if states[projectId] != new { states[projectId] = new }
    }

    private func finishInvalidatedRefresh(projectId: String, refreshId: UUID, rollbackSnapshot: GGInboxSnapshot?) {
        guard activeRefreshes[projectId] == refreshId, var state = states[projectId] else { return }
        state.snapshot = rollbackSnapshot
        state.fetchedAt = nil
        state.isRefreshing = false
        state.refreshProgress = nil
        write(projectId, state)
    }
}
