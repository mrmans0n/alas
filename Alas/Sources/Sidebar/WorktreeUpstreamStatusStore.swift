import Foundation
import Observation

@Observable
@MainActor
final class WorktreeUpstreamStatusStore {
    nonisolated static let defaultFetchInterval: TimeInterval = 5 * 60

    private(set) var statuses: [WorktreeStatusKey: WorktreeUpstreamStatus] = [:]

    @ObservationIgnored private let git = GitService()
    @ObservationIgnored private var refreshGenerationByKey: [WorktreeStatusKey: Int] = [:]
    @ObservationIgnored private var lastFetchAtByTarget: [String: Date] = [:]

    func status(for worktreeID: String, projectId: String) -> WorktreeUpstreamStatus? {
        statuses[WorktreeStatusKey(projectId: projectId, worktreeId: worktreeID)]
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

    struct WorktreeStatusKey: Hashable, Sendable {
        let projectId: String
        let worktreeId: String

        init(projectId: String, worktreeId: String) {
            self.projectId = projectId
            self.worktreeId = worktreeId
        }

        init(_ worktree: Worktree) {
            self.init(projectId: worktree.projectId, worktreeId: worktree.id)
        }
    }

    func refresh(
        worktrees: [Worktree],
        allowFetch: Bool = false,
        minFetchInterval: TimeInterval = WorktreeUpstreamStatusStore.defaultFetchInterval
    ) async {
        var generations: [WorktreeStatusKey: Int] = [:]
        for worktree in worktrees {
            let key = WorktreeStatusKey(worktree)
            let generation = (refreshGenerationByKey[key] ?? 0) + 1
            refreshGenerationByKey[key] = generation
            generations[key] = generation
        }
        for worktree in worktrees {
            let key = WorktreeStatusKey(worktree)
            let host = git.remoteHost(forWorktreePath: worktree.path)
            let scoped = host == nil ? git : git.scoped(to: .project(host))
            guard let generation = generations[key] else { continue }
            do {
                if let upstream = try await scoped.resolveUpstreamRef(worktreePath: worktree.path) {
                    await fetchUpstreamIfNeeded(
                        upstream,
                        for: worktree,
                        scoped: scoped,
                        allowFetch: allowFetch,
                        minFetchInterval: minFetchInterval
                    )
                }
                guard let divergence = try await scoped.upstreamDivergence(worktreePath: worktree.path) else {
                    guard generation == refreshGenerationByKey[key] else { continue }
                    statuses[key] = nil
                    continue
                }
                guard generation == refreshGenerationByKey[key] else { continue }
                statuses[key] = WorktreeUpstreamStatus(
                    ahead: divergence.ahead,
                    behind: divergence.behind,
                    upstreamRef: divergence.upstreamRef
                )
            } catch {
                guard generation == refreshGenerationByKey[key] else { continue }
                statuses[key] = nil
            }
        }
    }

    private func fetchUpstreamIfNeeded(
        _ upstream: (remote: String, ref: String),
        for worktree: Worktree,
        scoped: GitService,
        allowFetch: Bool,
        minFetchInterval: TimeInterval
    ) async {
        let branch = String(upstream.ref.dropFirst(upstream.remote.count + 1))
        let target = "\(worktree.projectId)\u{0}\(worktree.id)\u{0}\(upstream.remote)\u{0}\(branch)"
        let now = Date()
        guard Self.shouldFetchUpstream(
            autoFetch: allowFetch,
            lastFetchAt: lastFetchAtByTarget[target],
            now: now,
            minFetchInterval: minFetchInterval
        ) else { return }
        lastFetchAtByTarget[target] = now
        let _ = try? await scoped.fetchRef(worktreePath: worktree.path, remote: upstream.remote, branch: branch)
    }
}
