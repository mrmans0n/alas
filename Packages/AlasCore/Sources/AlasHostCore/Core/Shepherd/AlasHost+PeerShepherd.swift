import Foundation
import AlasCode
import AlasPlatform
import AlasIntegrations

/// What a paired Mac asks of a session's shepherd (`host.shepherds.v1`).
public enum HostShepherdAction: String, Codable, Sendable {
    /// Ship with agent: asks the session to open its pull request, or ship
    /// its gg stack, which the shepherd then watches.
    case ship
    /// Puts an escalated or paused shepherd back to watching.
    case resume
    /// Stops shepherding; the pull requests are left alone.
    case stop

    /// What a Mac offers for a session whose host pill is `shepherd`: Ship
    /// without one, Resume while it is escalated or paused, Stop until it finished.
    public static func offered(for shepherd: HostSessionShepherd?) -> [HostShepherdAction] {
        guard let shepherd else { return [.ship] }
        switch shepherd.badgeState {
        case .merged, .closed, nil: return []
        default: return shepherd.resumable == true ? [.resume, .stop] : [.stop]
        }
    }
}

extension SessionsAPI {
    public func shepherd(_ sessionID: String, action: HostShepherdAction, caller: HostCaller) async throws {
        caller.log("sessions.shepherd", sessionID)
        let stack = core.stackShepherd.record(forSession: sessionID).flatMap { $0.isFinished ? nil : $0 }
        let request = core.reviewShepherd.record(forSession: sessionID)
        switch action {
        case .stop, .resume:
            guard stack != nil || request != nil else {
                throw HostError.failed(message: "This session isn't shepherding anything.")
            }
            if let stack { action == .stop ? core.stackShepherd.stopShepherding(stack.id) : core.stackShepherd.resume(stack.id) }
            if let request { action == .stop ? core.reviewShepherd.stopShepherding(request.id) : core.reviewShepherd.resume(request.id) }
        case .ship:
            guard stack == nil, request == nil else {
                throw HostError.failed(message: "This session already shepherds a pull request.")
            }
            guard let manager = core.sessionManagers.values.first(where: { $0.liveSession(for: sessionID) != nil }),
                  let worktreeID = manager.liveSession(for: sessionID)?.worktreeId else {
                throw SessionRefusal.notFound
            }
            // Adopting rebinds the shepherd, which only the session's driver may do.
            guard manager.isWriter(for: sessionID) else { throw SessionRefusal.notWriter }
            guard let context = core.reviewShepherd.effects?.worktreeContext(worktreeID), context.isEligible else {
                throw HostError.failed(message: "The shepherd works on git worktrees only.")
            }
            if let stackName = core.stackShepherd.effects?.worktreeContext(worktreeID)?.stackName {
                let remotes = (try? await GitService().remotes(worktreePath: context.path)) ?? []
                guard let kind = CodeHostRemoteDetector.detect(from: remotes)?.kind else {
                    throw HostError.failed(message: "This worktree has no GitHub or GitLab remote.")
                }
                // As the app's Ship does, so an earlier partial choice never carries over.
                core.stackShepherd.setPendingShipPlan(
                    .wholeStack, sessionID: sessionID, id: StackShepherdRecordID(worktreeID: worktreeID, stackName: stackName)
                )
                // Answers once the session took the prompt, not when its turn ends.
                _ = try await submit(sessionID, prompt: StackShepherdPromptBuilder.shipPrompt(kind: kind, plan: .wholeStack), caller: caller)
                return
            }
            // As the app's Ship: the branch's open request is adopted, and
            // only a branch without one asks the agent to open it.
            let other = core.reviewShepherd.record(forWorktree: worktreeID)
                .flatMap { $0.sessionID != sessionID && !$0.phase.isTerminal ? $0 : nil }
            let snapshot = if let other {
                await core.reviewShepherd.statusSnapshot(for: other.id)
            } else {
                await core.reviewShepherd.fetchSnapshot(worktreePath: context.path, baseBranch: context.baseBranch)
            }
            let isBusy = await core.shepherdSessionState(sessionID: sessionID, in: manager) == .busy
            switch ShepherdShipAction.resolve(
                record: nil, otherRecord: other, request: snapshot?.reviewRequest, snapshot: snapshot, isBusy: isBusy
            ) {
            case .adopt(let request):
                let rules = try await core.headlessShepherdRules(worktreeID: worktreeID)
                _ = await core.bindPRShepherd(sessionID: sessionID, worktreeID: worktreeID, request: request, contextRules: rules)
            case .create(let kind):
                _ = try await submit(sessionID, prompt: ShepherdPromptBuilder.createPrompt(kind: kind), caller: caller)
            case .shepherding(let number):
                throw HostError.failed(message: "This session already shepherds \(number).")
            case .unavailable(let reason):
                throw HostError.failed(message: reason)
            }
        }
    }
}
