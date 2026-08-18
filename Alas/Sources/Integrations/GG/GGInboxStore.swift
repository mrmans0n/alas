import Foundation
import Observation

struct GGInboxRefreshProgress: Equatable {
    let completed: Int
    let total: Int
}

/// Project id → gg inbox triage state. One `gg inbox` round-trip per
/// project. Snapshots are retained across refresh failures so the view can
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
    }

    var states: [String: State] = [:]
    @ObservationIgnored private var invalidationGenerations: [String: UInt64] = [:]

    /// A snapshot older than `threshold` (or missing) should be refetched
    /// when the tab appears or regains focus.
    static func isStale(fetchedAt: Date?, now: Date, threshold: TimeInterval = 120) -> Bool {
        guard let fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) >= threshold
    }

    @discardableResult
    func refresh(
        projectId: String,
        repoPath: String,
        service: GGService,
        now: () -> Date = Date.init
    ) async -> Bool {
        if states[projectId]?.isRefreshing == true { return false }
        let generation = invalidationGenerations[projectId, default: 0]
        var state = states[projectId] ?? State()
        let rollbackSnapshot = state.snapshot
        let rollbackFetchedAt = state.fetchedAt
        var partialBuckets = GGInboxBuckets()
        var partialStackErrors: [GGInboxStackError] = []
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
                    state.refreshProgress = .init(completed: payload.completed, total: payload.totalCandidates)
                    if payload.included, let bucket = payload.bucket {
                        partialBuckets.insert(payload.entry, into: bucket)
                    }
                    publishPartial = true
                case .entryError(let payload):
                    state.refreshProgress = .init(completed: payload.completed, total: payload.totalCandidates)
                    partialBuckets.insert(payload.failedEntry, into: .refreshFailed)
                    publishPartial = true
                case .summary(let snapshot):
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
                finishInvalidatedRefresh(projectId: projectId, rollbackSnapshot: rollbackSnapshot)
                return true
            }
            state.snapshot = rollbackSnapshot
            state.fetchedAt = rollbackFetchedAt
            state.refreshProgress = nil
            state.lastError = error.userMessage
        } catch {
            guard invalidationGenerations[projectId, default: 0] == generation else {
                finishInvalidatedRefresh(projectId: projectId, rollbackSnapshot: rollbackSnapshot)
                return true
            }
            state.snapshot = rollbackSnapshot
            state.fetchedAt = rollbackFetchedAt
            state.refreshProgress = nil
            state.lastError = error.localizedDescription
        }
        guard invalidationGenerations[projectId, default: 0] == generation else {
            finishInvalidatedRefresh(projectId: projectId, rollbackSnapshot: rollbackSnapshot)
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
        guard var state = states[projectId] else { return }
        state.fetchedAt = nil
        write(projectId, state)
    }

    /// Drops states for projects that no longer exist.
    func prune(keepingProjectIds: Set<String>) {
        let pruned = states.filter { keepingProjectIds.contains($0.key) }
        if pruned.count != states.count { states = pruned }
    }

    private func write(_ projectId: String, _ new: State) {
        if states[projectId] != new { states[projectId] = new }
    }

    private func finishInvalidatedRefresh(projectId: String, rollbackSnapshot: GGInboxSnapshot?) {
        var state = states[projectId] ?? State()
        state.snapshot = rollbackSnapshot
        state.fetchedAt = nil
        state.isRefreshing = false
        state.refreshProgress = nil
        write(projectId, state)
    }
}
