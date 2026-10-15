import Foundation

/// Serves the host protocol to any transport: each connection hands it the
/// messages it decoded and gets back the messages to send. The transport
/// says who the client is; nothing a client sends can.
@MainActor
public final class HostProtocolServer {
    let host: AlasHost

    public init(host: AlasHost) {
        self.host = host
    }

    /// A connection for a client the transport authenticated as `caller`.
    /// `send` returns once the message is on its way, so a client that reads
    /// slowly holds its events back, where they coalesce, rather than
    /// queueing without bound.
    public func connect(
        caller: HostCaller,
        send: @escaping @MainActor (HostServerMessage) async -> Void
    ) -> HostProtocolConnection {
        HostProtocolConnection(host: host, caller: caller, send: send)
    }
}

@MainActor
public final class HostProtocolConnection {
    private let host: AlasHost
    private let caller: HostCaller
    private let send: @MainActor (HostServerMessage) async -> Void
    private var subscription: HostSubscription?

    init(host: AlasHost, caller: HostCaller, send: @escaping @MainActor (HostServerMessage) async -> Void) {
        self.host = host
        self.caller = caller
        self.send = send
    }

    /// Answers one message. Requests are independent: a client may send the
    /// next before this one is answered, and matches answers by id.
    public func receive(_ message: HostClientMessage) async {
        if message.version == HostProtocolVersion.current, case .subscribe(let cursor) = message.request {
            await subscribe(after: cursor, id: message.id)
            return
        }
        let result: HostResponse
        if message.version != HostProtocolVersion.current {
            result = .failure(error: .unsupportedVersion(supported: HostProtocolVersion.current))
        } else {
            do {
                result = try await respond(to: message.request)
            } catch {
                result = .failure(error: Self.hostError(error))
            }
        }
        await send(.response(id: message.id, result: result))
    }

    /// Replaces the subscription, and forwards its events only once the
    /// client has been told it subscribed, unless another request replaced
    /// or ended it meanwhile.
    private func subscribe(after cursor: HostCursor, id: Int) async {
        close()
        let next = host.subscribe(after: cursor)
        subscription = next
        await send(.response(id: id, result: .subscribed))
        guard subscription === next else { return }
        follow(next)
    }

    /// Ends the connection's subscription. The transport calls it when the
    /// client goes away.
    public func close() {
        subscription?.cancel()
        subscription = nil
    }

    private func respond(to request: HostRequest) async throws -> HostResponse {
        switch request {
        case .snapshot:
            return .snapshot(snapshot: try await host.snapshot())
        case .subscribe:
            // Handled before a response is built; see `subscribe(after:id:)`.
            return .subscribed
        case .unsubscribe:
            close()
            return .unsubscribed
        case .listSessions:
            return .sessions(sessions: host.sessions.list())
        case .addProject(let path, let displayName, let projectHost, let kind):
            return .project(project: try await host.projects.add(
                path: URL(fileURLWithPath: path), displayName: displayName, icon: .default(),
                host: projectHost, kind: kind, caller: caller
            ))
        case .createWorktree(let projectID, let base, let branch, let destination):
            let request = WorktreeCreateRequest(
                projectID: projectID, base: base, branch: branch, destination: URL(fileURLWithPath: destination)
            )
            return .worktree(worktree: try await host.worktrees.create(request, caller: caller))
        case .deleteWorktree(let ref, let lineageID, let branch, let force, let deleteBranchIfMerged):
            let listed = try worktree(ref)
            // What the client saw must still be what is listed; the host then
            // checks what is listed against the checkout on disk.
            guard listed.lineageID == lineageID, listed.branch == branch else {
                throw WorktreeDeletionRefusal.changed("The worktree changed since it was listed.")
            }
            try await host.worktrees.delete(
                listed, force: force, deleteBranchIfMerged: deleteBranchIfMerged, caller: caller
            )
            return .done
        case .archiveWorktree(let ref, let lineageID, let branch):
            let listed = try worktree(ref)
            guard listed.lineageID == lineageID, listed.branch == branch else {
                throw WorktreeArchiveRefusal.changed("The worktree changed since it was listed.")
            }
            // The list can lag the disk. Checked in the same turn the host
            // claims the worktree, so nothing starts in between.
            guard !listed.path.isRemoteAlasPath else { throw WorktreeArchiveRefusal.remoteUnsupported }
            guard let lineageID,
                  WorktreeService.existingLocalLineageID(forWorktreeAt: listed.path) == lineageID,
                  WorktreeService.localBranchName(forWorktreeAt: listed.path) == branch
            else { throw WorktreeArchiveRefusal.changed("The checkout at this path changed.") }
            try await host.worktrees.archive(listed, caller: caller)
            return .done
        case .unarchiveWorktree(let ref):
            try host.worktrees.unarchive(path: URL(fileURLWithPath: ref.path), projectID: ref.projectID, caller: caller)
            return .done
        case .listWorkspaceCheckouts:
            return .workspaceCheckouts(checkouts: try await host.workspaces.list())
        case .workspaceCheckout(let id):
            return .workspaceCheckout(checkout: try await host.workspaces.checkout(id: id))
        case .startRun(let scriptKey, let ref):
            let worktree = try worktree(ref)
            // Archiving stopped everything in it; nothing starts there again
            // until it is unarchived.
            guard !host.core.projects.isWorktreeHidden(projectId: ref.projectID, path: worktree.path) else {
                return .runStart(start: .refused(title: "Worktree archived", message: "Unarchive the worktree to run scripts in it."))
            }
            let projectHost = host.core.projects.projects.first { $0.id == ref.projectID }?.host
            let scripts = await RunScriptStore.scripts(worktreeRoot: worktree.path, remoteHost: projectHost)
            guard let script = scripts.first(where: { $0.key == scriptKey }) else {
                throw HostError.notFound(what: "script \(scriptKey)")
            }
            return .runStart(start: host.runs.start(script, in: worktree, caller: caller))
        case .stopRun(let scriptKey, let ref):
            host.runs.stop(scriptKey: scriptKey, in: try worktree(ref), caller: caller)
            return .done
        }
    }

    /// Forwards the subscription's batches until it ends or another replaces it.
    private func follow(_ next: HostSubscription) {
        Task { @MainActor [weak self] in
            while let events = await next.next() {
                guard let self else { return }
                await send(.events(events: events, cursor: next.cursor))
            }
        }
    }

    /// The listed, unarchived or archived, worktree a reference names.
    private func worktree(_ ref: WorktreeRef) throws -> Worktree {
        let path = URL(fileURLWithPath: ref.path).standardizedFileURL.path
        guard let worktree = host.core.projects.worktrees(projectId: ref.projectID)
            .first(where: { $0.path.standardizedFileURL.path == path })
        else { throw HostError.notFound(what: "worktree \(ref.path) in project \(ref.projectID)") }
        return worktree
    }

    static func hostError(_ error: any Error) -> HostError {
        switch error {
        case let error as HostError: error
        case let refusal as WorktreeDeletionRefusal: .worktreeDeletion(refusal: refusal)
        case let refusal as WorktreeArchiveRefusal: .worktreeArchive(refusal: refusal)
        case let refusal as WorktreeCreationRefusal: .worktreeCreation(refusal: refusal)
        case let failure as WorktreeCreationError: .worktreeCreationFailed(message: failure.message)
        case let error as ProjectCreationError: .project(error: error)
        case let error as WorkspaceAutomationError: .workspace(error: error)
        case is AlasCoreContext.WorktreeOperationInProgress: .operationInProgress
        default: .failed(message: error.localizedDescription)
        }
    }
}
