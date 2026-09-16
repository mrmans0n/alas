import Foundation
import Observation

@Observable
@MainActor
final class WorktreeUpstreamStatusStore {
    private(set) var statuses: [String: WorktreeUpstreamStatus] = [:]

    @ObservationIgnored private let git = GitService()
    @ObservationIgnored private var refreshGenerationByWorktreeID: [String: Int] = [:]
    @ObservationIgnored private var lastFetchAtByTarget: [String: Date] = [:]

    func status(for worktreeID: String) -> WorktreeUpstreamStatus? {
        statuses[worktreeID]
    }

    func refresh(worktrees: [Worktree]) async {
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
                    await fetchUpstreamIfNeeded(upstream, for: worktree)
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
