import Foundation
import Observation

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

    func refresh(
        projectId: String,
        repoPath: String,
        service: GGService,
        now: () -> Date = Date.init
    ) async {
        if states[projectId]?.isRefreshing == true { return }
        let generation = invalidationGenerations[projectId, default: 0]
        var state = states[projectId] ?? State()
        state.isRefreshing = true
        write(projectId, state)
        do {
            let snapshot = try await service.inbox(repoPath: repoPath)
            state.snapshot = snapshot
            state.fetchedAt = now()
            state.lastError = nil
        } catch let error as GGServiceError {
            state.lastError = error.userMessage
        } catch {
            state.lastError = error.localizedDescription
        }
        guard invalidationGenerations[projectId, default: 0] == generation else {
            var invalidated = states[projectId] ?? State()
            invalidated.isRefreshing = false
            invalidated.fetchedAt = nil
            write(projectId, invalidated)
            return
        }
        state.isRefreshing = false
        write(projectId, state)
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
}
