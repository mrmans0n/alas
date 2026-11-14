import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasIntegrations

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
    /// The Macs paired with that server, which a local client lists and
    /// forgets; nil where the app manages them itself.
    public var remotePeers: RemotePeerManager?
    /// The pairing link for a code that `remotePairing` minted, with the
    /// addresses the server is reached at now; nil leaves the code alone.
    public var remotePairingLink: (@MainActor (String) -> String?)?
    /// Who the paired devices are, for their `delegation` requests; without it
    /// those are refused. Only the connections of a peer link need it.
    public var delegationPairing: RemotePairingService?

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
    /// queueing without bound. A `delegationOnly` client, one whose token
    /// was scoped to it, is served only `delegationOnlyRequests`.
    public func connect(
        caller: HostCaller,
        delegationOnly: Bool = false,
        send: @escaping @MainActor (HostServerMessage) async -> Void
    ) -> HostProtocolConnection {
        HostProtocolConnection(
            host: host, caller: caller, delegationOnly: delegationOnly, discoverScripts: discoverScripts,
            // Held by the connection: a caller may keep only the connection
            // (the Remote gateway does), and the server keeps no connection.
            isServerClosed: { [self] in isClosed }, remotePairing: { [self] in remotePairing },
            remotePeers: { [self] in remotePeers }, remotePairingLink: { [self] in remotePairingLink },
            delegationPairing: { [self] in delegationPairing }, send: send
        )
    }

    /// A delegation-only connection for a caller whose device the transport
    /// describes itself, rather than one paired here: a host that sends its
    /// requests back over this Mac's own link to it. `device` is read on each
    /// request, so a change of consent applies at once.
    public func connect(
        caller: HostCaller,
        device: @escaping @MainActor () -> RemoteDevice?,
        send: @escaping @MainActor (HostServerMessage) async -> Void
    ) -> HostProtocolConnection {
        HostProtocolConnection(
            host: host, caller: caller, delegationOnly: true, discoverScripts: discoverScripts,
            isServerClosed: { [self] in isClosed }, device: device, send: send
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
    /// Serves only what a peer needs to delegate, and its snapshot shows
    /// nothing: see `RemoteDeviceScope.delegation`.
    private let delegationOnly: Bool
    private let discoverScripts: HostProtocolServer.ScriptDiscovery
    private let isServerClosed: @MainActor () -> Bool
    private let remotePairing: @MainActor () -> RemotePairingService?
    private let remotePeers: @MainActor () -> RemotePeerManager?
    private let remotePairingLink: @MainActor () -> (@MainActor (String) -> String?)?
    private let delegationPairing: @MainActor () -> RemotePairingService?
    /// The caller's device as its transport describes it, in place of a
    /// lookup in `delegationPairing`.
    private let device: (@MainActor () -> RemoteDevice?)?
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
        delegationOnly: Bool = false,
        discoverScripts: @escaping HostProtocolServer.ScriptDiscovery,
        isServerClosed: @escaping @MainActor () -> Bool = { false },
        remotePairing: @escaping @MainActor () -> RemotePairingService? = { nil },
        remotePeers: @escaping @MainActor () -> RemotePeerManager? = { nil },
        remotePairingLink: @escaping @MainActor () -> (@MainActor (String) -> String?)? = { nil },
        delegationPairing: @escaping @MainActor () -> RemotePairingService? = { nil },
        device: (@MainActor () -> RemoteDevice?)? = nil,
        send: @escaping @MainActor (HostServerMessage) async -> Void
    ) {
        self.host = host
        self.caller = caller
        self.delegationOnly = delegationOnly
        self.discoverScripts = discoverScripts
        self.isServerClosed = isServerClosed
        self.remotePairing = remotePairing
        self.remotePeers = remotePeers
        self.remotePairingLink = remotePairingLink
        self.delegationPairing = delegationPairing
        self.device = device
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
        if delegationOnly, !Self.isDelegationOnlyRequest(message.request) {
            await enqueue(.response(id: message.id, result: .failure(error: .invalidRequest(
                reason: Self.delegationOnlyRefusal))))
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
        next.delegationPeerServerId = delegationDevice.flatMap { PeerDelegationGate.allows(.outbox, device: $0) ? $0.peerServerId : nil }
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
            if delegationOnly { return .snapshot(snapshot: host.cursorOnlySnapshot()) }
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
        case .removeProject(let projectID):
            try await host.projects.remove(projectID: projectID, caller: caller)
            return .done
        case .setProjectGGMode(let projectID, let mode):
            guard host.servedCapabilities.contains(HostProtocolCapability.projectsGGModeV1) else {
                throw HostError.invalidRequest(reason: "This host doesn't set gg modes.")
            }
            try host.projects.setGGMode(projectID: projectID, mode: mode, caller: caller)
            return .done
        case .createWorktree(let projectID, let base, let branch, let destination):
            var request = WorktreeCreateRequest(
                projectID: projectID, base: base, branch: branch, destination: URL(fileURLWithPath: destination)
            )
            request.asksAboutRepoHooks = promptsForRepoHooks
            return .worktree(worktree: try await host.worktrees.create(request, caller: caller))
        case .deleteWorktree(let ref, let lineageID, let branch, let force, let deleteBranchIfMerged, let discardUnsavedEdits):
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
            do {
                try await host.worktrees.delete(
                    listed, force: force, deleteBranchIfMerged: deleteBranchIfMerged,
                    discardUnsavedEdits: discardUnsavedEdits ?? false, caller: caller
                )
            } catch {
                throw Self.lifecycleRefusal(error, typed: discardUnsavedEdits != nil)
            }
            return .done
        case .archiveWorktree(let ref, let lineageID, let branch, let discardUnsavedEdits):
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
            do {
                try await host.worktrees.archive(
                    listed, verifiesCheckout: true, discardUnsavedEdits: discardUnsavedEdits ?? false, caller: caller
                )
            } catch {
                throw Self.lifecycleRefusal(error, typed: discardUnsavedEdits != nil)
            }
            return .done
        case .unarchiveWorktree(let ref):
            try host.worktrees.unarchive(path: try worktree(ref).path, projectID: ref.projectID, caller: caller)
            return .done
        case .renameBranch(let ref, let from, let branch):
            // Only a listed worktree: an archived one is refused as an unknown one is.
            let listed = try visibleWorktree(ref)
            // The branch the client saw is checked under the project's gate.
            try await host.worktrees.renameBranch(listed, from: from, to: branch, caller: caller)
            return .done
        case .listWorkspaceCheckouts:
            return .workspaceCheckouts(checkouts: try await host.workspaces.list())
        case .workspaceCheckout(let id):
            return .workspaceCheckout(checkout: try await host.workspaces.checkout(id: id))
        case .startRun(let scriptKey, let ref):
            guard let script = try await runnableScript(scriptKey, in: ref) else { return Self.archivedRunStart }
            // The console follows the script and never takes the active tab.
            // A paired peer is not at this Mac, so an unapproved repository
            // hook is skipped rather than asked about; a local user is asked.
            return .runStart(start: host.runs.start(
                script, in: try worktree(ref), isHidden: script.console == .hidden, activatesConsole: false,
                promptsForRepoHooks: promptsForRepoHooks, caller: caller
            ))
        case .restartRun(let scriptKey, let ref):
            guard let script = try await runnableScript(scriptKey, in: ref) else { return Self.archivedRunStart }
            let worktree = try worktree(ref)
            // The open console's visibility wins over the script's, as for a
            // local restart.
            let isHidden = host.core.startingRunIsHidden(scriptKey: script.key, worktreeID: worktree.id)
                ?? host.core.environment.runConsoleIsHidden(scriptKey: script.key, worktreeID: worktree.id)
                ?? (script.console == .hidden)
            return .runStart(start: host.runs.restart(
                script, in: worktree, isHidden: isHidden, activatesConsole: false,
                promptsForRepoHooks: promptsForRepoHooks, caller: caller
            ))
        case .listRunScripts(let ref):
            // Only a listed worktree, as for `readWorktree`: an archived one
            // is refused as an unknown one is.
            let listed = try visibleWorktree(ref)
            let projectHost = host.core.projects.projects.first { $0.id == ref.projectID }?.host
            return .runScripts(scripts: await discoverScripts(listed.path, projectHost).map {
                HostRunScript($0, target: host.core.runExecutionTarget(for: $0, in: listed))
            })
        case .stopRun(let scriptKey, let ref):
            host.runs.stop(scriptKey: scriptKey, in: try worktree(ref), caller: caller)
            return .done
        case .createSession(let target, let agentID, let modelID, let autoRun):
            return .session(session: try await sessions.create(target, agentID: agentID, modelID: modelID, autoRun: autoRun, caller: caller))
        case .sendPrompt(let id, let prompt):
            try await sessions.send(id, prompt: prompt, caller: caller)
        case .stopSession(let id):
            try await sessions.stop(id, caller: caller)
        case .shepherdSession(let id, let action):
            try await sessions.shepherd(id, action: action, caller: caller)
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
        case .followFile(let ref, let path):
            let listed = try fileWorktree(ref)
            _ = try subscribed()
            // The paths a Mac may edit, and no others: a follow watches the file.
            _ = try await host.core.writableURL(path, in: listed)
            try await subscribed().followFile(listed, path: RemoteWorktreeFileAccess.normalizedRelativePath(path) ?? path)
        case .unfollowFile(let ref, let path):
            try subscribed().unfollowFile(
                // A worktree no longer listed was unfollowed with its removal.
                worktreeID: (try? worktree(ref))?.id ?? Worktree.makeId(path: URL(fileURLWithPath: ref.path)),
                path: RemoteWorktreeFileAccess.normalizedRelativePath(path) ?? path
            )
        case .capabilities:
            return .capabilities(capabilities: host.servedCapabilities)
        case .runOutput(let runID, let projectID):
            return .runOutput(output: await host.runs.output(of: runID, projectID: projectID))
        case .remotePairingCode:
            // A code admits a new device, so only the local user mints one:
            // never a paired device over Remote's own host channel.
            guard case .localUser = caller, let pairing = remotePairing() else {
                throw HostError.failed(message: "This host does not mint Remote pairing codes.")
            }
            let code = pairing.beginPairing()
            return .remotePairingCode(
                code: code, expiresAt: Date().addingTimeInterval(RemotePairingService.codeTTL), link: remotePairingLink()?(code)
            )
        case .listPeers:
            return .peers(peers: try localPeers().summaries)
        case .addPeer(let link):
            let peers = try localPeers()
            guard remotePairing() != nil else { throw HostError.failed(message: Self.remoteOffRefusal) }
            if let error = await peers.addPeer(link: link) { throw HostError.failed(message: Self.describe(error)) }
            return .done
        case .forgetPeer(let peerID):
            let peers = try localPeers()
            guard peers.peers.contains(where: { $0.id == peerID }) else { throw HostError.notFound(what: "peer \(peerID)") }
            peers.forget(peerId: peerID)
            return .done
        case .setPeerAgentAccess(let peerID, let access):
            let peers = try localPeers()
            guard peers.peers.contains(where: { $0.id == peerID }) else { throw HostError.notFound(what: "peer \(peerID)") }
            guard peers.setAgentAccess(access, peerId: peerID) else {
                throw HostError.failed(message: "That peer never proved its identity here. Pair it again to allow this.")
            }
            return .done
        case .updateHost:
            // A person's request: a paired Mac or the local user, not an agent.
            switch caller {
            case .remotePeer, .localUser: break
            default: throw HostError.failed(message: "Only a paired Mac updates this host.")
            }
            guard let update = host.selfUpdate else {
                throw HostError.failed(message: "This host can't update itself; it wasn't installed with Homebrew.")
            }
            try await update()
            return .done
        case .readWorktree(let ref, let read):
            // Needs no lease, as for a session: seeing a worktree is enough
            // to read its code. Only a listed worktree is read: an archived
            // one is refused as an unknown one is.
            let listed = try visibleWorktree(ref)
            return .worktreeRead(reply: await host.core.remoteRead(read, in: listed, replyingAs: listed.id))
        case .mutateWorktree(let ref, let branch, let change):
            // The branch the client saw is checked under the project's gate.
            let listed = try gitWorktree(ref)
            if let capability = change.capability { _ = try servedWorktree(ref, capability: capability) }
            return try await host.worktrees.mutate(listed, branch: branch, change: change, caller: caller)
        case .commitMessageInput(let ref):
            let listed = try gitWorktree(ref)
            let ticketTitle = host.core.projects.issueAttachment(projectId: listed.projectId, worktreeId: listed.id)?.title
            return .commitMessageInput(input: try await CommitMessageSuggestionInput.load(
                worktreePath: listed.path, ticketTitle: ticketTitle
            ))
        case .reviewStatus(let ref):
            let listed = try gitWorktree(ref)
            await host.core.refreshFollowedReviewStatus(listed.id)
            return .reviewStatus(snapshot: host.reviews.status(of: listed.id))
        case .ggStack(let ref, let refresh):
            let listed = try servedWorktree(ref, capability: HostProtocolCapability.worktreesGGStackV1)
            return .ggStack(read: await host.core.ggStackRead(of: listed, refresh: refresh))
        case .ggStackAction(let ref, let stackName, let action):
            let listed = try servedWorktree(ref, capability: HostProtocolCapability.worktreesGGStackActionsV1)
            caller.log("worktrees.ggStackAction", "\(listed.id) \(action.rawValue)")
            try await host.core.runGGStackAction(action, stackName: stackName, in: listed)
            return .done
        case .ggStackLand(let ref, let stackName, let through, let scope):
            let listed = try servedWorktree(ref, capability: HostProtocolCapability.worktreesGGStackLandV1)
            caller.log("worktrees.ggStackLand", "\(listed.id) through \(through)")
            try await host.core.runCheckedGGStackMutation(.land(target: through), stackName: stackName, in: listed) { stack in
                AlasCoreContext.ggLandScope(through: through, in: stack) == scope
            }
            return .done
        case .ggStackReorder(let ref, let stackName, let order):
            let listed = try servedWorktree(ref, capability: HostProtocolCapability.worktreesGGStackLandV1)
            caller.log("worktrees.ggStackReorder", "\(listed.id)")
            try await host.core.runCheckedGGStackMutation(.reorder(order: order), stackName: stackName, in: listed)
            return .done
        case .listReviews(let ref):
            return .reviews(reviews: try host.reviews.list(in: try reviewWorktree(ref)))
        case .readReview(let ref, let sessionID):
            return .review(review: try host.reviews.read(sessionID, in: try reviewWorktree(ref)))
        case .mutateReview(let ref, let sessionID, let mutation):
            try await host.reviews.mutate(mutation, sessionID: sessionID, in: try reviewWorktree(ref), caller: caller)
        case .readProviderReview(let ref, let sessionID, let withDiff):
            return .providerReview(review: try await host.reviews.providerReview(
                sessionID, in: try providerReviewWorktree(ref), withDiff: withDiff
            ))
        case .openProviderReview(let ref, let number):
            return .review(review: try await host.reviews.openProviderReview(
                number: number, in: try providerReviewWorktree(ref), caller: caller
            ))
        case .mutateReviewThread(let ref, let sessionID, let threadID, let kind, let body):
            return .reviewThreadMutated(result: try await host.reviews.mutateThread(
                threadID, kind: kind, body: body, sessionID: sessionID, in: try providerReviewWorktree(ref), caller: caller
            ))
        case .publishReview(let ref, let sessionID, let publish):
            return .reviewPublished(result: try await host.reviews.publish(
                publish, sessionID: sessionID, in: try providerReviewWorktree(ref), caller: caller
            ))
        case .listStashes(let ref):
            // Reads, outside the gate as `readWorktree` is.
            return .stashes(stashes: try await host.core.stashes(in: try servedWorktree(ref, capability: HostProtocolCapability.worktreesStashV1)))
        case .stashFiles(let ref, let stash):
            return .stashFiles(files: try await host.core.stashFiles(
                stash, in: try servedWorktree(ref, capability: HostProtocolCapability.worktreesStashV1)
            ))
        case .stashDiff(let ref, let stash, let path):
            return .diff(diff: try await host.core.stashDiff(
                stash, path: path, in: try servedWorktree(ref, capability: HostProtocolCapability.worktreesStashV1)
            ))
        case .commitDetails(let ref, let sha):
            return .commitDetails(details: try await host.core.commitDetails(
                sha, in: try servedWorktree(ref, capability: HostProtocolCapability.worktreesCommitEditV1)
            ))
        case .listCheckpoints(let ref):
            return try await host.core.checkpointCatalog(in: try checkpointWorktree(ref))
        case .checkpointManifest(let ref, let id):
            return .checkpointManifest(manifest: try await host.core.checkpointManifest(id, in: try checkpointWorktree(ref)))
        case .checkpointDiff(let ref, let id, let path):
            return .diff(diff: try await host.core.checkpointDiff(id, path: path, in: try checkpointWorktree(ref)))
        case .checkpointRestorePreview(let ref, let id, let groupIDs):
            return .checkpointRestorePreview(preview: try await host.core.checkpointRestorePreview(
                id, groupIDs: groupIDs, in: try checkpointWorktree(ref)
            ))
        case .writeFile(let ref, let path, let text, let expected):
            let listed = try fileWorktree(ref)
            caller.log("worktrees.files", path)
            return .fileWritten(version: try await host.core.writeListedFile(path, text: text, expected: expected, in: listed))
        case .createFolder(let ref, let path):
            let listed = try fileWorktree(ref)
            caller.log("worktrees.files", path)
            try await host.core.createListedFolder(path, in: listed)
        case .delegation(let request):
            return try await host.delegation.serve(request, device: delegationDevice, caller: caller)
        }
        return .done
    }

    private var sessions: SessionsAPI { host.sessions }

    /// The paired device this connection's transport authenticated; nil for
    /// any other caller.
    private var delegationDevice: RemoteDevice? {
        if let device { return device() }
        guard case .remotePeer(let deviceID) = caller else { return nil }
        return delegationPairing()?.device(id: deviceID)
    }

    /// Someone at this Mac may be asked about a repository hook; a paired
    /// peer may not.
    private var promptsForRepoHooks: Bool {
        if case .remotePeer = caller { return false }
        return true
    }

    /// Forgetting a peer revokes its token and listing shows where it is
    /// reached, so only the local user may, as with pairing codes.
    private func localPeers() throws -> RemotePeerManager {
        guard case .localUser = caller, let peers = remotePeers() else {
            throw HostError.failed(message: "This host does not serve Mac peers.")
        }
        return peers
    }

    nonisolated static let remoteOffRefusal = "Remote is off on this host. Set host.reachability to lan or tailscale, restart the host, and try again."
    nonisolated static let noAddressRefusal = "This host has no address the Mac could reach it at, and the Mac must pair back. Set host.reachability to lan or tailscale; with tailscale, tailscale serve must be running."

    private static func describe(_ error: RemotePeerManager.AddError) -> String {
        switch error {
        case .invalidLink: "That is not a pairing link."
        case .expiredCode: "That pairing code is not valid any more. Make a new one on the Mac."
        case .originRejected: "That Mac doesn't accept peers. Turn on Remote peers in its Advanced settings."
        case .approvalExpired, .approvalDisabled: "That Mac refused the pairing request."
        case .unreachable: "Couldn't reach that Mac at any of its addresses. It must be reachable from this host, for example over Tailscale."
        case .noLocalAddress: noAddressRefusal
        case .reciprocalPairingFailed: "That Mac couldn't pair back. Check it can reach this host at the addresses alas-host pair prints."
        case .cancelled: "Cancelled: that peer was forgotten while pairing was in progress."
        case .identityUnproven: "That Mac answered with a key it couldn't prove it holds. Nothing was paired."
        case .identityRebindRefused: "This host is already paired with that Mac under a different key. If the Mac was reinstalled, run alas-host peers remove first, then pair again."
        case .scopeUnsupported: "That Mac's Alas can't limit this host to delegated work. Update Alas there, then pair again."
        }
    }

    static let delegationOnlyRefusal = "This pairing only allows delegated work. Pair again from the app for more."

    /// What a delegation-only client may ask: enough to subscribe for
    /// outbox changes and to delegate. Anything added to `HostRequest` later
    /// is refused until someone decides otherwise.
    static func isDelegationOnlyRequest(_ request: HostRequest) -> Bool {
        switch request {
        case .snapshot, .subscribe, .subscribeAccepting, .unsubscribe, .delegation: true
        default: false
        }
    }

    /// Only the news that delegated work waits there, and the resync that
    /// tells it to subscribe again.
    static func reachesDelegationOnlyClient(_ event: HostEvent) -> Bool {
        switch event {
        case .delegationOutboxChanged, .resync: true
        default: false
        }
    }

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
                let sent = events.filter { event in
                    guard event.optInKind.map(accepting.contains) ?? true else { return false }
                    return !delegationOnly || Self.reachesDelegationOnlyClient(event)
                }
                guard !sent.isEmpty else { continue }
                await enqueue(.events(events: sent, cursor: next.cursor), from: next)
            }
        }
    }

    /// Archiving stopped everything in a worktree; nothing starts there
    /// again until it is unarchived.
    private func isArchived(_ ref: WorktreeRef) throws -> Bool {
        host.core.projects.isWorktreeHidden(projectId: ref.projectID, path: try worktree(ref).path)
    }

    private static let archivedRunStart = HostResponse.runStart(
        start: .refused(title: "Worktree archived", message: "Unarchive the worktree to run scripts in it.")
    )

    /// The discovered script `scriptKey` names, or nil when the worktree is archived.
    private func runnableScript(_ scriptKey: String, in ref: WorktreeRef) async throws -> RunScript? {
        let projectHost = host.core.projects.projects.first { $0.id == ref.projectID }?.host
        if try isArchived(ref) { return nil }
        let scripts = await discoverScripts(try worktree(ref).path, projectHost)
        guard let script = scripts.first(where: { $0.key == scriptKey }) else {
            throw HostError.notFound(what: "script \(scriptKey)")
        }
        // Discovery can take a while on a remote host: the worktree may
        // have been archived or removed meanwhile.
        if try isArchived(ref) { return nil }
        return script
    }

    /// The listed, unarchived or archived, worktree a reference names.
    private func worktree(_ ref: WorktreeRef) throws -> Worktree {
        let path = URL(fileURLWithPath: ref.path).standardizedFileURL.path
        guard let worktree = host.core.projects.worktrees(projectId: ref.projectID)
            .first(where: { $0.path.standardizedFileURL.path == path })
        else { throw HostError.notFound(what: "worktree \(ref.path) in project \(ref.projectID)") }
        return worktree
    }

    /// A listed worktree that is not archived: an archived one is refused as
    /// an unknown one is.
    private func visibleWorktree(_ ref: WorktreeRef) throws -> Worktree {
        let listed = try worktree(ref)
        guard !host.core.projects.isWorktreeHidden(projectId: listed.projectId, path: listed.path) else {
            throw HostError.notFound(what: "worktree \(ref.path) in project \(ref.projectID)")
        }
        return listed
    }

    /// A visible worktree, on a host that serves git actions.
    private func gitWorktree(_ ref: WorktreeRef) throws -> Worktree {
        guard host.servedCapabilities.contains(HostProtocolCapability.worktreesGitV1) else {
            throw HostError.invalidRequest(reason: "This host does not serve git actions.")
        }
        return try visibleWorktree(ref)
    }

    /// A visible worktree, on a host that serves `capability`.
    private func servedWorktree(_ ref: WorktreeRef, capability: String) throws -> Worktree {
        guard host.servedCapabilities.contains(capability) else {
            throw HostError.invalidRequest(reason: "This host does not serve this git action.")
        }
        return try visibleWorktree(ref)
    }

    /// A visible worktree whose files this host edits, under the project's gate. Never a remote project's.
    private func fileWorktree(_ ref: WorktreeRef) throws -> Worktree {
        guard host.servedCapabilities.contains(HostProtocolCapability.worktreesFilesV1) else {
            throw HostError.invalidRequest(reason: "This host does not serve file editing.")
        }
        let listed = try visibleWorktree(ref)
        guard !listed.path.isRemoteAlasPath else {
            throw HostError.invalidRequest(reason: "The host does not edit files of remote projects.")
        }
        return listed
    }

    /// A visible worktree whose checkpoints this host serves. Reads, outside the gate as `readWorktree` is.
    private func checkpointWorktree(_ ref: WorktreeRef) throws -> Worktree {
        try servedWorktree(ref, capability: HostProtocolCapability.worktreesCheckpointsV1)
    }

    /// A visible worktree, on a host that serves reviews.
    private func reviewWorktree(_ ref: WorktreeRef) throws -> Worktree {
        guard host.servedCapabilities.contains(HostProtocolCapability.reviewsV1) else {
            throw HostError.invalidRequest(reason: "This host does not serve reviews.")
        }
        return try visibleWorktree(ref)
    }

    /// A visible worktree, on a host that serves pull request reviews.
    private func providerReviewWorktree(_ ref: WorktreeRef) throws -> Worktree {
        guard host.servedCapabilities.contains(HostProtocolCapability.reviewsProviderV1) else {
            throw HostError.invalidRequest(reason: "This host does not serve pull request reviews.")
        }
        return try visibleWorktree(ref)
    }

    /// The refusals `host.worktrees.lifecycle.v1` added, as a message for a
    /// client that did not send `discardUnsavedEdits` and cannot decode them.
    static func lifecycleRefusal(_ error: any Error, typed: Bool) -> any Error {
        guard !typed else { return error }
        switch error {
        case WorktreeDeletionRefusal.unsavedEdits, WorktreeDeletionRefusal.ownedByWorkspaceCheckout,
             WorktreeArchiveRefusal.unsavedEdits:
            return HostError.failed(message: error.localizedDescription)
        default:
            return error
        }
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
