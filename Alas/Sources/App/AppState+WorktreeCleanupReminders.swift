import AlasCore
import Foundation

/// An inbox entry suggesting the cleanup sheet for a project with many
/// worktrees that look ready to remove.
struct WorktreeCleanupReminder: Identifiable, Equatable {
    let projectId: String
    let projectName: String
    let readyCount: Int

    var id: String { projectId }
}

enum WorktreeCleanupReminderPolicy {
    /// Below this, the project's "Clean Up Worktrees…" menu item is enough.
    static let minimumReadyWorktrees = 5
    /// A scan queries the code host, so each project is rescanned at most
    /// this often in the background.
    static let rescanInterval: TimeInterval = 6 * 60 * 60
    static let dismissalsDefaultsKey = "worktreeCleanupReminderDismissals"

    /// The worktrees to remind about, or nil when no reminder should show.
    /// Only worktrees that still exist count, and a dismissal holds until a
    /// worktree outside the dismissed set becomes ready.
    static func remindedWorktreeIds(
        ready: Set<String>,
        existing: Set<String>,
        dismissed: Set<String>
    ) -> Set<String>? {
        let current = ready.intersection(existing)
        guard current.count >= minimumReadyWorktrees, !current.isSubset(of: dismissed) else { return nil }
        return current
    }

    static func isDue(lastScan: Date?, now: Date) -> Bool {
        guard let lastScan else { return true }
        return now.timeIntervalSince(lastScan) >= rescanInterval
    }

    static func loadDismissals(defaults: UserDefaults = .standard) -> [String: Set<String>] {
        let stored = defaults.dictionary(forKey: dismissalsDefaultsKey) as? [String: [String]] ?? [:]
        return stored.mapValues(Set.init)
    }

    static func saveDismissals(_ dismissals: [String: Set<String>], defaults: UserDefaults = .standard) {
        defaults.set(dismissals.mapValues { $0.sorted() }, forKey: dismissalsDefaultsKey)
    }
}

extension AppState {
    var worktreeCleanupReminders: [WorktreeCleanupReminder] {
        projects.compactMap { project in
            guard let ready = worktreeCleanupReadyIds[project.id],
                  let reminded = WorktreeCleanupReminderPolicy.remindedWorktreeIds(
                      ready: ready,
                      existing: Set(projectsManager.visibleWorktrees(projectId: project.id).map(\.id)),
                      dismissed: worktreeCleanupDismissedIds[project.id] ?? []
                  )
            else { return nil }
            return WorktreeCleanupReminder(projectId: project.id, projectName: project.name, readyCount: reminded.count)
        }
    }

    /// Rescans projects in the background, one at a time, each at most every
    /// `rescanInterval`. The first pass waits a minute so it stays out of the
    /// way of launch work.
    func startWorktreeCleanupReminders() {
        guard worktreeCleanupReminderTask == nil else { return }
        worktreeCleanupReminderTask = Task(priority: .utility) { @MainActor [weak self] in
            var delay = Duration.seconds(60)
            while (try? await Task.sleep(for: delay)) != nil {
                guard let self else { return }
                await self.refreshDueWorktreeCleanupReminders()
                delay = .seconds(300)
            }
        }
    }

    func refreshDueWorktreeCleanupReminders() async {
        for project in projects {
            guard WorktreeCleanupReminderPolicy.isDue(
                lastScan: worktreeCleanupReminderScannedAt[project.id],
                now: Date()
            ) else { continue }
            await refreshWorktreeCleanupReminder(projectId: project.id)
        }
        let projectIds = Set(projects.map(\.id))
        worktreeCleanupReadyIds = worktreeCleanupReadyIds.filter { projectIds.contains($0.key) }
        worktreeCleanupReminderScannedAt = worktreeCleanupReminderScannedAt.filter { projectIds.contains($0.key) }
        let dismissals = worktreeCleanupDismissedIds.filter { projectIds.contains($0.key) }
        if dismissals.count != worktreeCleanupDismissedIds.count {
            worktreeCleanupDismissedIds = dismissals
            WorktreeCleanupReminderPolicy.saveDismissals(dismissals)
        }
    }

    /// Runs the cleanup sheet's own scan for one project and records which
    /// worktrees it would preselect.
    func refreshWorktreeCleanupReminder(projectId: String) async {
        guard let project = projects.first(where: { $0.id == projectId }),
              !project.isFolder,
              project.host == nil
        else {
            worktreeCleanupReadyIds[projectId] = nil
            return
        }
        worktreeCleanupReminderScannedAt[projectId] = Date()
        let targets = worktreeCleanupScanTargets(project: project)
        // Too few worktrees to ever reach the threshold: skip git and the network.
        guard targets.count >= WorktreeCleanupReminderPolicy.minimumReadyWorktrees else {
            worktreeCleanupReadyIds[projectId] = nil
            return
        }
        let candidates = await scanWorktreesForCleanup(project: project, worktrees: targets)
        worktreeCleanupReadyIds[projectId] = Set(candidates.filter(\.isSelectedByDefault).map(\.id))
    }

    func presentWorktreeCleanup(projectId: String) {
        worktreeCleanupPresentation = WorktreeCleanupPresentation(projectId: projectId)
    }

    func dismissWorktreeCleanupReminder(projectId: String) {
        worktreeCleanupDismissedIds[projectId] = worktreeCleanupReadyIds[projectId] ?? []
        WorktreeCleanupReminderPolicy.saveDismissals(worktreeCleanupDismissedIds)
    }
}
