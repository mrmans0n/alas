import Foundation
import AlasModel
import AlasAgentKit

extension AlasCoreContext {
    public enum ScheduleTargetResolution {
        case targets([(project: ProjectConfig, worktree: Worktree)])
        /// Nothing to run against; `reason` is shown on the schedule row.
        case unavailable(String)
    }

    public func resolveScheduleTargets(
        _ target: RunScheduleTarget,
        invocation: RunScheduleInvocation = .scheduled
    ) -> ScheduleTargetResolution {
        switch target {
        case .allProjects:
            let candidates = projects.projects.compactMap { project -> (project: ProjectConfig, worktree: Worktree)? in
                guard let main = projects.visibleMainWorktree(projectId: project.id) else { return nil }
                return (project, main)
            }
            guard !candidates.isEmpty else { return .unavailable("No project has a main worktree to run in.") }
            // A schedule that names no single project still has to respect
            // "Pause <project>": without this the pause control would look
            // like it worked while the fan-out kept running there anyway.
            guard invocation.honorsProjectPauses else { return .targets(candidates) }
            let resolved = candidates.filter { !runScheduler.isProjectPaused($0.project.id) }
            guard !resolved.isEmpty else {
                return .unavailable("Every project with a main worktree is paused.")
            }
            return .targets(resolved)
        case .project(let id):
            guard let project = projects.projects.first(where: { $0.id == id }) else {
                return .unavailable("The project no longer exists.")
            }
            if invocation.honorsProjectPauses, runScheduler.isProjectPaused(id) {
                return .unavailable("\(project.name) is paused.")
            }
            guard let main = projects.visibleMainWorktree(projectId: id) else {
                return .unavailable("\(project.name) has no main worktree.")
            }
            return .targets([(project, main)])
        case let .worktree(projectId, worktreeId):
            guard let project = projects.projects.first(where: { $0.id == projectId }) else {
                return .unavailable("The project no longer exists.")
            }
            if invocation.honorsProjectPauses, runScheduler.isProjectPaused(projectId) {
                return .unavailable("\(project.name) is paused.")
            }
            guard let worktree = projects.worktrees(projectId: projectId).first(where: { $0.id == worktreeId }) else {
                return .unavailable("The worktree no longer exists in \(project.name).")
            }
            return .targets([(project, worktree)])
        }
    }

    /// Runs a schedule once against every target it resolves to, through
    /// `target` per project and worktree.
    public func runSchedule(
        _ schedule: RunSchedule,
        invocation: RunScheduleInvocation,
        target: @escaping @MainActor (RunSchedule, ProjectConfig, Worktree) async -> RunScheduleRunReport
    ) async -> RunScheduleRunReport {
        let targets: [(project: ProjectConfig, worktree: Worktree)]
        switch resolveScheduleTargets(schedule.target, invocation: invocation) {
        case .targets(let resolved):
            // A worktree-creating schedule skips folders, which cannot have one.
            targets = schedule.composition == nil ? resolved : resolved.filter { !$0.project.isFolder }
            guard !targets.isEmpty else {
                return RunScheduleRunReport(outcome: .skipped(reason: Self.folderWorktreeCreationMessage))
            }
        case .unavailable(let reason):
            return RunScheduleRunReport(outcome: .skipped(reason: reason))
        }
        // Start every target before waiting on any of them. Run scripts are
        // allowed to be long-running servers that never exit, so awaiting one
        // target's settlement before launching the next would let the first
        // project starve all the others indefinitely. Each child suspends on
        // its own run's settlement, which lets the next one start.
        let runs = targets.map { resolved in
            Task { @MainActor in
                await target(schedule, resolved.project, resolved.worktree)
            }
        }
        // Cancellation is forwarded by hand because these children are
        // unstructured and so do not inherit it. `RunScheduler` cancels the
        // task it dispatched when a schedule is removed, and without this
        // the targets would carry on regardless — including a prompt still
        // waiting to be typed into, and submitted to, an agent belonging to
        // a schedule that no longer exists.
        let reports = await withTaskCancellationHandler {
            var collected: [RunScheduleRunReport] = []
            for run in runs {
                collected.append(await run.value)
            }
            return collected
        } onCancel: {
            for run in runs { run.cancel() }
        }
        // Every target's run is linked, not just the one whose outcome won:
        // a fan-out that failed in one project should still let the user open
        // the reports of the projects that did run.
        return RunScheduleRunReport(
            outcome: .combined(reports.map(\.outcome)),
            runs: reports.flatMap(\.runs),
            agentReports: reports.flatMap(\.agentReports)
        )
    }
}
