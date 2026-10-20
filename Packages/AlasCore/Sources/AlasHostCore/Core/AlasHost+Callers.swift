import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents

extension AlasHost {
    /// Who sent a command: the session, its owner and the worktree it acts in.
    public var callers: CallersAPI { CallersAPI(core: core) }
}

@MainActor
public struct CallersAPI {
    let core: AlasCoreContext

    /// The owner of session `id`: a terminal the environment knows of, else
    /// a loaded ACP session.
    public func owner(ofSession id: String) -> SessionOwnerID? {
        core.environment.terminalSessionOwner(id) ?? core.acpSessionOwner(id)
    }

    /// The loaded ACP session `id` as delegation sees it; nil for a terminal
    /// or an unknown session.
    public func acpOrigin(ofSession id: String) -> ACPOrchestrationSessionOrigin? {
        core.acpSessionLocation(id)?.origin
    }

    /// The worktree a command from session `id` acts in: its owner's for a
    /// worktree-owned session, and for a checkout-owned one the member
    /// worktree holding `cwd`.
    public func worktree(ofSession id: String, cwd: String?) async -> Worktree? {
        switch owner(ofSession: id) {
        case .worktree(let worktreeID):
            return core.projectAndWorktree(withWorktreeId: worktreeID)?.worktree
        case .workspaceCheckout(let checkoutID, let location):
            guard let cwd else { return nil }
            return await core.checkoutMemberWorktree(checkoutID, location: location, holding: cwd)
        case nil:
            return nil
        }
    }

    /// The listed worktree holding `directory`, the most specific when
    /// worktrees nest.
    public func worktree(owning directory: String) -> Worktree? {
        WorktreePaths.worktree(owning: directory, in: core.projects.projects.flatMap {
            core.projects.visibleWorktrees(projectId: $0.id)
        })
    }
}

extension AlasCoreContext {
    func acpSessionOwner(_ sessionID: String) -> SessionOwnerID? {
        sessionManagers.first { $0.value.liveSession(for: sessionID) != nil }?.key
    }

    /// The loaded ACP session `sessionID`, its manager, and where delegation
    /// places it. A checkout-owned session is placed in its owner's scope,
    /// which no project worktree resolves to.
    @_spi(AppHost) public func acpSessionLocation(_ sessionID: String) -> ACPSessionOrchestrationCoordinator.SessionLocation? {
        guard let (owner, manager) = sessionManagers.first(where: { $0.value.liveSession(for: sessionID) != nil }) else { return nil }
        let origin: ACPOrchestrationSessionOrigin
        switch owner {
        case .worktree(let worktreeID):
            guard let worktree = projectAndWorktree(withWorktreeId: worktreeID)?.worktree else { return nil }
            origin = .init(sessionId: sessionID, projectId: worktree.projectId, worktreeId: worktree.id)
        case .workspaceCheckout(let checkoutID, let location):
            guard environment.workspaceCheckout(id: checkoutID)?.executionLocation.normalized == location.normalized else {
                return nil
            }
            origin = .init(sessionId: sessionID, projectId: owner.storageKey, worktreeId: owner.storageKey)
        }
        return .init(origin: origin, manager: manager)
    }

    /// The available member of a live checkout whose worktree holds `cwd`,
    /// with paths compared on the checkout's own host.
    func checkoutMemberWorktree(_ checkoutID: UUID, location: ExecutionLocation, holding cwd: String) async -> Worktree? {
        guard let checkout = environment.workspaceCheckout(id: checkoutID),
              checkout.archivedAt == nil,
              checkout.executionLocation.normalized == location.normalized
        else { return nil }
        let transport = environment.workspaceRemoteTransport
        func physicalPath(_ path: String) async -> String? {
            switch location.normalized {
            case .local:
                return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            case .ssh(let host):
                // A legacy project host that cannot form a virtual path never matches.
                guard RemotePath.isValidHost(host) else { return nil }
                let result = try? await transport.run(
                    host: host, command: "cd \(SSHCommand.shellQuote(RemotePath.realPath(path))) 2>/dev/null && pwd -P"
                )
                guard result?.exitCode == 0 else { return nil }
                let resolved = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return resolved.isEmpty ? nil : RemotePath.virtual(host: host, realPath: resolved)
            }
        }
        guard let cwdPath = await physicalPath(cwd) else { return nil }
        for member in checkout.members where member.availability == .available {
            guard let memberPath = await physicalPath(member.worktreePath),
                  cwdPath == memberPath || cwdPath.hasPrefix(memberPath + "/")
            else { continue }
            let worktree = projects.worktrees(projectId: member.projectID).first {
                let worktreePath = switch location.normalized {
                case .local: $0.path.resolvingSymlinksInPath().standardizedFileURL.path
                case .ssh: $0.path.standardizedFileURL.path
                }
                return worktreePath == memberPath
            }
            if let worktree { return worktree }
        }
        return nil
    }
}
