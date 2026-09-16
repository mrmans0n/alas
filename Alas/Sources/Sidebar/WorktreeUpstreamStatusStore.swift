import Foundation
import Observation

@Observable
@MainActor
final class WorktreeUpstreamStatusStore {
    private(set) var statuses: [String: WorktreeUpstreamStatus] = [:]

    @ObservationIgnored private let git = GitService()
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var lastFetchAtByTarget: [String: Date] = [:]

    func status(for worktreeID: String) -> WorktreeUpstreamStatus? {
        statuses[worktreeID]
    }

    func refresh(worktrees: [Worktree]) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        for worktree in worktrees {
            do {
                if let upstream = try await git.resolveUpstreamRef(worktreePath: worktree.path) {
                    await fetchUpstreamIfNeeded(upstream, for: worktree)
                }
                guard let divergence = try await git.upstreamDivergence(worktreePath: worktree.path) else {
                    guard generation == refreshGeneration else { return }
                    statuses[worktree.id] = nil
                    continue
                }
                guard generation == refreshGeneration else { return }
                statuses[worktree.id] = WorktreeUpstreamStatus(
                    ahead: divergence.ahead,
                    behind: divergence.behind,
                    upstreamRef: divergence.upstreamRef
                )
            } catch {
                guard generation == refreshGeneration else { return }
                statuses[worktree.id] = nil
            }
        }
    }

    private func fetchUpstreamIfNeeded(
        _ upstream: (remote: String, ref: String),
        for worktree: Worktree
    ) async {
        let branch = String(upstream.ref.dropFirst(upstream.remote.count + 1))
        let target = "\(worktree.id)\u{0}\(upstream.remote)\u{0}\(branch)"
        let now = Date()
        guard now.timeIntervalSince(lastFetchAtByTarget[target] ?? .distantPast) > 30 else { return }
        lastFetchAtByTarget[target] = now
        let _ = try? await git.fetchRef(worktreePath: worktree.path, remote: upstream.remote, branch: branch)
    }
}
