import Foundation

/// Serves the host protocol to any transport: each connection hands it the
/// messages it decoded and gets back the messages to send. The transport
/// says who the client is; nothing a client sends can.
@MainActor
public final class HostProtocolServer {
    /// Finds the run scripts of a worktree, on its project's host if remote.
    public typealias ScriptDiscovery = @Sendable (_ worktreeRoot: URL, _ remoteHost: String?) async -> [RunScript]

    let host: AlasHost
    let discoverScripts: ScriptDiscovery
    /// Set once the host stops serving: every connection, open ones
    /// included, answers that it is stopping instead of serving a request.
    public private(set) var isClosed = false
    /// The pairing of the Remote server this host serves headlessly, which
    /// mints codes for local clients; nil where the app shows codes itself.
    public var remotePairing: RemotePairingService?

    public init(
        host: AlasHost,
        discoverScripts: @escaping ScriptDiscovery = { await RunScriptStore.scripts(worktreeRoot: $0, remoteHost: $1) }
    ) {
        self.host = host
        self.discoverScripts = discoverScripts
    }

    /// A connection for a client the transport authenticated as `caller`.
    /// `send` returns once the message is on its way, so a client that reads
    /// slowly holds its events back, where they coalesce, rather than
    /// queueing without bound.
    public func connect(
        caller: HostCaller,
        send: @escaping @MainActor (HostServerMessage) async -> Void
    ) -> HostProtocolConnection {
        HostProtocolConnection(
            host: host, caller: caller, discoverScripts: discoverScripts,
            // Held by the connection: a caller may keep only the connection
            // (the Remote gateway does), and the server keeps no connection.
            isServerClosed: { [self] in isClosed }, remotePairing: { [self] in remotePairing }, send: send
        )
    }

    /// Stops serving requests, on every connection, before the host tears
    /// down: none can start work that teardown would miss.
    public func close() {
        isClosed = true
    }
}

@MainActor
public final class HostProtocolConnection {
    private let host: AlasHost
    private let caller: HostCaller
    private let discoverScripts: HostProtocolServer.ScriptDiscovery
    private let isServerClosed: @MainActor () -> Bool
    private let remotePairing: @MainActor () -> RemotePairingService?
    private let send: @MainActor (HostServerMessage) async -> Void
    private var subscription: HostSubscription?
    /// The last message handed to the transport. Every send waits for the
    /// one before it, so messages leave in the order they were queued, and
    /// an event batch whose subscription was replaced or ended by then is
    /// dropped rather than sent after that.
    private var sendTail: Task<Void, Never>?

    init(
        host: AlasHost,
        caller: HostCaller,
        discoverScripts: @escaping HostProtocolServer.ScriptDiscovery,
        isServerClosed: @escaping @MainActor () -> Bool = { false },
        remotePairing: @escaping @MainActor () -> RemotePairingService? = { nil },
        send: @escaping @MainActor (HostServerMessage) async -> Void
    ) {
        self.host = host
        self.caller = caller
        self.discoverScripts = discoverScripts
        self.isServerClosed = isServerClosed
        self.remotePairing = remotePairing
        self.send = send
    }

    /// Answers one message. Requests are independent: a client may send the
    /// next before this one is answered, and matches answers by id.
    public func receive(_ message: HostClientMessage) async {
        guard !isServerClosed() else {
            close()
            await enqueue(.response(id: message.id, result: .failure(error: .failed(message: "The host is stopping."))))
            return
        }
        if message.version == HostProtocolVersion.current {
            switch message.request {
            case .subscribe(let cursor):
                await subscribe(after: cursor, accepting: [], id: message.id)
                return
            case .subscribeAccepting(let cursor, let events):
                await subscribe(after: cursor, accepting: Set(events), id: message.id)
                return
            default:
                break
            }
        }
        let result: HostResponse
        if message.version != HostProtocolVersion.current {
            result = .failure(error: .unsupportedVersion(supported: HostProtocolVersion.current))
        } else {
            // Counted while it is served, not while its answer is sent, for
            // shutdown to wait on.
            host.core.requestsUnderway += 1
            do {
                result = try await respond(to: message.request)
            } catch {
                result = .failure(error: Self.hostError(error))
            }
            host.core.requestsUnderway -= 1
        }
        await enqueue(.response(id: message.id, result: result))
    }

    private func enqueue(_ message: HostServerMessage, from source: HostSubscription? = nil) async {
        let previous = sendTail
        let sending = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            if let source, subscription !== source { return }
            await send(message)
        }
        sendTail = sending
        await sending.value
    }

    /// Replaces the subscription, and forwards its events only once the
    /// client has been told it subscribed, unless another request replaced
    /// or ended it meanwhile.
    private func subscribe(after cursor: HostCursor, accepting: Set<String>, id: Int) async {
        close()
        let next = host.subscribe(after: cursor)
        subscription = next
        await enqueue(.response(id: id, result: .subscribed))
        guard subscription === next else { return }
        follow(next, accepting: accepting)
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
        case .subscribe, .subscribeAccepting:
            // Handled before a response is built; see `subscribe(after:accepting:id:)`.
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
            // The list can lag the disk: checked before anything in the
            // checkout is stopped, and again by the host right before removal.
            if !listed.path.isRemoteAlasPath, let lineageID,
               AlasCoreContext.checkoutChange(listed, lineageID: lineageID) != nil {
                throw WorktreeDeletionRefusal.changed("The checkout at this path changed.")
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
            // The list can lag the disk: checked now, so a replaced checkout
            // is not stopped, and again by the host right before hiding it.
            guard !listed.path.isRemoteAlasPath else { throw WorktreeArchiveRefusal.remoteUnsupported }
            guard let lineageID, AlasCoreContext.checkoutChange(listed, lineageID: lineageID) == nil else {
                throw WorktreeArchiveRefusal.changed("The checkout at this path changed.")
            }
            try await host.worktrees.archive(listed, verifiesCheckout: true, caller: caller)
            return .done
        case .unarchiveWorktree(let ref):
            try host.worktrees.unarchive(path: try worktree(ref).path, projectID: ref.projectID, caller: caller)
            return .done
        case .listWorkspaceCheckouts:
            return .workspaceCheckouts(checkouts: try await host.workspaces.list())
        case .workspaceCheckout(let id):
            return .workspaceCheckout(checkout: try await host.workspaces.checkout(id: id))
        case .startRun(let scriptKey, let ref):
            let projectHost = host.core.projects.projects.first { $0.id == ref.projectID }?.host
            if let refusal = try archivedRunRefusal(ref) { return refusal }
            let scripts = await discoverScripts(try worktree(ref).path, projectHost)
            guard let script = scripts.first(where: { $0.key == scriptKey }) else {
                throw HostError.notFound(what: "script \(scriptKey)")
            }
            // Discovery can take a while on a remote host: the worktree may
            // have been archived or removed meanwhile.
            if let refusal = try archivedRunRefusal(ref) { return refusal }
            return .runStart(start: host.runs.start(script, in: try worktree(ref), caller: caller))
        case .stopRun(let scriptKey, let ref):
            host.runs.stop(scriptKey: scriptKey, in: try worktree(ref), caller: caller)
            return .done
        case .createSession(let target, let agentID, let modelID, let autoRun):
            return .session(session: try await sessions.create(target, agentID: agentID, modelID: modelID, autoRun: autoRun, caller: caller))
        case .sendPrompt(let id, let prompt):
            try await sessions.send(id, prompt: prompt, caller: caller)
        case .stopSession(let id):
            try await sessions.stop(id, caller: caller)
        case .renameSession(let id, let title):
            try sessions.rename(id, title: title, caller: caller)
        case .archiveSession(let id):
            try await sessions.archive(id, caller: caller)
        case .setSessionModel(let id, let modelID):
            try await sessions.setModel(id, modelID: modelID, caller: caller)
        case .setSessionMode(let id, let modeID):
            try await sessions.setMode(id, modeID: modeID, caller: caller)
        case .setSessionConfigOption(let id, let configID, let value):
            try await sessions.setConfigOption(id, configID: configID, value: value, caller: caller)
        case .answerPermission(let id, let requestID, let optionID, let scope):
            try await sessions.answerPermission(id, requestID: requestID, optionID: optionID, scope: scope, caller: caller)
        case .answerQuestion(let id, let requestID, let answers):
            try await sessions.answerQuestion(id, requestID: requestID, answers: answers, caller: caller)
        case .respondToPlan(let id, let requestID, let action):
            try await sessions.respondToPlan(id, requestID: requestID, action: action, caller: caller)
        case .respondToUserInput(let id, let requestID, let answer):
            try await sessions.respondToUserInput(id, requestID: requestID, answer: answer, caller: caller)
        case .followSession(let id, let revision):
            try subscribed().follow(id, from: revision)
        case .unfollowSession(let id):
            try subscribed().unfollow(id)
        case .followWorktree(let id):
            // Only a listed worktree: an unknown id would keep a refresh
            // waking for nothing, with no removal to end it.
            guard host.worktrees.list(includingArchived: true).contains(where: { $0.worktree.id == id }) else {
                throw HostError.notFound(what: "worktree \(id)")
            }
            try subscribed().followWorktree(id)
        case .unfollowWorktree(let id):
            try subscribed().unfollowWorktree(id)
        case .capabilities:
            return .capabilities(capabilities: HostProtocolCapability.served)
        case .runOutput(let runID, let projectID):
            return .runOutput(output: await host.runs.output(of: runID, projectID: projectID))
        case .remotePairingCode:
            // A code admits a new device, so only the local user mints one:
            // never a paired device over Remote's own host channel.
            guard case .localUser = caller, let pairing = remotePairing() else {
                throw HostError.failed(message: "This host does not mint Remote pairing codes.")
            }
            let code = pairing.beginPairing()
            return .remotePairingCode(code: code, expiresAt: Date().addingTimeInterval(RemotePairingService.codeTTL))
        }
        return .done
    }

    private var sessions: SessionsAPI { host.sessions }

    /// Following acts on the connection's subscription, so it needs one.
    private func subscribed() throws -> HostSubscription {
        guard let subscription else { throw HostError.invalidRequest(reason: "Subscribe before following a session.") }
        return subscription
    }

    /// Forwards the subscription's batches until it ends or another replaces it.
    private func follow(_ next: HostSubscription, accepting: Set<String>) {
        Task { @MainActor [weak self] in
            while let events = await next.next() {
                guard let self else { return }
                // Events a version 1 client cannot decode go only to the
                // clients that accepted their kind.
                let sent = events.filter { event in event.optInKind.map(accepting.contains) ?? true }
                guard !sent.isEmpty else { continue }
                await enqueue(.events(events: sent, cursor: next.cursor), from: next)
            }
        }
    }

    /// Archiving stopped everything in a worktree; nothing starts there
    /// again until it is unarchived.
    private func archivedRunRefusal(_ ref: WorktreeRef) throws -> HostResponse? {
        let listed = try worktree(ref)
        guard host.core.projects.isWorktreeHidden(projectId: ref.projectID, path: listed.path) else { return nil }
        return .runStart(start: .refused(title: "Worktree archived", message: "Unarchive the worktree to run scripts in it."))
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
        case let refusal as SessionRefusal: .session(refusal: refusal)
        case is AlasCoreContext.WorktreeOperationInProgress: .operationInProgress
        default: .failed(message: error.localizedDescription)
        }
    }
}
