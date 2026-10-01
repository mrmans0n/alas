import Foundation
import Observation

@Observable
@MainActor
final class WorktreeUpstreamStatusStore {
    nonisolated static let defaultFetchInterval: TimeInterval = 5 * 60

    /// Sidebar-initiated upstream pulls, keyed by worktree id. Drives the
    /// spinner in the sidebar's `↓N` badge; a second click while an entry is
    /// set falls through to selecting the worktree instead.
    private(set) var isPullingUpstreamByWorktreeID: Set<String> = []
    private(set) var statuses: [String: WorktreeUpstreamStatus] = [:]

    func isPullingUpstream(worktreeID: String) -> Bool {
        isPullingUpstreamByWorktreeID.contains(worktreeID)
    }

    func markPullingUpstream(worktreeID: String) {
        isPullingUpstreamByWorktreeID.insert(worktreeID)
    }

    func clearPullingUpstream(worktreeID: String) {
        isPullingUpstreamByWorktreeID.remove(worktreeID)
    }

    @ObservationIgnored private let git = GitService()
    @ObservationIgnored private var refreshGenerationByWorktreeID: [String: Int] = [:]
    @ObservationIgnored private var lastFetchAtByTarget: [String: Date] = [:]

    func status(for worktreeID: String) -> WorktreeUpstreamStatus? {
        statuses[worktreeID]
    }

    nonisolated static func fetchInterval(fetchIntervalMinutes: Int) -> TimeInterval {
        TimeInterval(max(1, fetchIntervalMinutes) * 60)
    }

    nonisolated static func shouldFetchUpstream(
        autoFetch: Bool,
        lastFetchAt: Date?,
        now: Date,
        minFetchInterval: TimeInterval
    ) -> Bool {
        guard autoFetch else { return false }
        guard let lastFetchAt else { return true }
        return now.timeIntervalSince(lastFetchAt) >= minFetchInterval
    }

    func refresh(
        worktrees: [Worktree],
        allowFetch: Bool = false,
        minFetchInterval: TimeInterval = WorktreeUpstreamStatusStore.defaultFetchInterval
    ) async {
        var generations: [String: Int] = [:]
        for worktree in worktrees {
            let generation = (refreshGenerationByWorktreeID[worktree.id] ?? 0) + 1
            refreshGenerationByWorktreeID[worktree.id] = generation
            generations[worktree.id] = generation
        }
        for worktree in worktrees {
            guard let generation = generations[worktree.id] else { continue }
            do {
                if let upstream = try await git.resolveUpstreamRef(worktreePath: worktree.path) {
                    await fetchUpstreamIfNeeded(
                        upstream,
                        for: worktree,
                        allowFetch: allowFetch,
                        minFetchInterval: minFetchInterval
                    )
                }
                guard let divergence = try await git.upstreamDivergence(worktreePath: worktree.path) else {
                    guard generation == refreshGenerationByWorktreeID[worktree.id] else { continue }
                    statuses[worktree.id] = nil
                    continue
                }
                guard generation == refreshGenerationByWorktreeID[worktree.id] else { continue }
                statuses[worktree.id] = WorktreeUpstreamStatus(
                    ahead: divergence.ahead,
                    behind: divergence.behind,
                    upstreamRef: divergence.upstreamRef
                )
            } catch {
                guard generation == refreshGenerationByWorktreeID[worktree.id] else { continue }
                statuses[worktree.id] = nil
            }
        }
    }

    private func fetchUpstreamIfNeeded(
        _ upstream: (remote: String, ref: String),
        for worktree: Worktree,
        allowFetch: Bool,
        minFetchInterval: TimeInterval
    ) async {
        let branch = String(upstream.ref.dropFirst(upstream.remote.count + 1))
        let target = "\(worktree.id)\u{0}\(upstream.remote)\u{0}\(branch)"
        let now = Date()
        guard Self.shouldFetchUpstream(
            autoFetch: allowFetch,
            lastFetchAt: lastFetchAtByTarget[target],
            now: now,
            minFetchInterval: minFetchInterval
        ) else { return }
        lastFetchAtByTarget[target] = now
        let _ = try? await git.fetchRef(worktreePath: worktree.path, remote: upstream.remote, branch: branch)
    }
}
