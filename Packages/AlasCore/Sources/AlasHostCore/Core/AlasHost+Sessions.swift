import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasACP
import AlasSessions

/// Where a new session runs.
public enum SessionTarget: Codable, Hashable, Sendable {
    case worktree(WorktreeRef)
    case workspaceCheckout(id: UUID)
}

/// Why the host did not act on a session.
/// A change to a session's prompt queue, naming items by id.
public enum SessionQueueEdit: Codable, Equatable, Sendable {
    /// Sends the item now, interrupting the running turn.
    case forceSend(UUID)
    case remove(UUID)
    /// Sends a failed item again.
    case retry(UUID)
    /// Takes the item out to edit its text.
    case edit(UUID)
    case clear
    /// Moves the item into `target`'s slot.
    case move(UUID, target: UUID)
    /// Moves the item to the front without interrupting the running turn.
    case promote(UUID)
}

public enum SessionRefusal: Error, Codable, Equatable, Sendable {
    /// No loaded session has this id.
    case notFound
    /// Another instance or device drives the session.
    case notWriter
    /// The worktree or Workspace checkout cannot host sessions now.
    case ownerUnavailable(reason: String)
    /// The agent is not enabled, or cannot run where the session would.
    case agentUnavailable
    /// The request was answered or replaced since the client saw it.
    case notPending
    /// The answer does not fit the request: an option it does not offer, a
    /// question left unanswered, a form that does not validate.
    case invalidAnswer
    /// The session did not take the prompt (it needs sign-in, or is shutting down).
    case promptRejected
    /// The session offers no such setting, or the value does not fit it.
    case invalidSetting
}

extension SessionsAPI {
    /// Creates a session for `agentID` and starts connecting it to the agent.
    /// The summary is ready at once; the session streams once it connects.
    public func create(
        _ target: SessionTarget,
        agentID: String,
        modelID: String? = nil,
        effortID: String? = nil,
        autoRun: Bool = false,
        caller: HostCaller
    ) async throws -> HostSessionSummary {
        caller.log("sessions.create", agentID)
        let manager: ACPSessionManager
        var worktreeOwner: Worktree?
        // Where the agent runs, for admitting it again once nothing suspends.
        var agentHost: String?
        switch target {
        case .worktree(let ref):
            let path = URL(fileURLWithPath: ref.path).standardizedFileURL.path
            guard let worktree = core.projects.worktrees(projectId: ref.projectID).first(where: { $0.path.standardizedFileURL.path == path })
            else { throw SessionRefusal.ownerUnavailable(reason: "The worktree is not listed, or is archived.") }
            (manager, agentHost) = try worktreeManager(worktree, agentID: agentID)
            worktreeOwner = worktree
        case .workspaceCheckout(let id):
            let checkout = try await idleCheckout(id)
            agentHost = checkout.executionLocation.sshHost
            guard core.environment.admitsAgent(agentID, remoteHost: checkout.executionLocation.sshHost) else {
                throw SessionRefusal.agentUnavailable
            }
            guard await !core.environment.checkpointRecoveryBlocksSessions(owner: .workspaceCheckout(checkout.id, checkout.executionLocation), in: core) else {
                throw SessionRefusal.ownerUnavailable(reason: Self.checkpointRecoveryReason)
            }
            manager = try await core.environment.sessionManager(forCheckout: checkout, in: core)
        }
        if case .workspaceCheckout(let id) = target { _ = try await idleCheckout(id) }
        try await admit(agentID, in: manager, worktree: worktreeOwner, agentHost: agentHost)
        let session = manager.createSession(agentId: agentID, autoRunDefault: autoRun)
        // Picked up by `attach`, so the first turn already runs on it.
        if let modelID { manager.pendingModel[session.id] = modelID }
        // Applied by `attach` after the model; a level the agent no longer
        // offers is skipped there. Without remembered levels there is no
        // option to set, so the effort is dropped rather than failing.
        if let effortID, let effort = core.environment.modelCatalog?.efforts(for: agentID) {
            manager.queueInitialConfigOption(for: session.id, configId: effort.configId, value: .string(effortID))
        }
        if let schedule = core.sessionAttachScheduler {
            schedule(manager, session.id)
        } else {
            Task { @MainActor [weak manager] in
                await manager?.attach(to: session.id, freshlyCreated: true)
            }
        }
        guard let row = manager.sessionRows.first(where: { $0.id == session.id }) else { throw SessionRefusal.notFound }
        return Self.summary(of: row, in: manager, parent: core.delegatedSessionParents[row.id])
    }

    /// Why a session for `agentID` cannot start in `worktree` now, as
    /// `create` checks it; nil when it can.
    func refusal(toStart agentID: String, in worktree: Worktree) async -> SessionRefusal? {
        // As listed now, which the manager lookup also uses: the worktree
        // can move to another project while a child waits to start.
        guard let worktree = core.projectAndWorktree(withWorktreeId: worktree.id)?.worktree else {
            return .ownerUnavailable(reason: "The worktree is not listed, or is archived.")
        }
        do {
            let (manager, agentHost) = try worktreeManager(worktree, agentID: agentID)
            try await admit(agentID, in: manager, worktree: worktree, agentHost: agentHost)
            return nil
        } catch let refusal as SessionRefusal {
            return refusal
        } catch {
            return .ownerUnavailable(reason: "The worktree cannot host sessions now.")
        }
    }

    /// The manager of a listed, unarchived worktree that admits `agentID`,
    /// and the host the agent runs on.
    private func worktreeManager(_ worktree: Worktree, agentID: String) throws -> (ACPSessionManager, agentHost: String?) {
        guard !core.projects.isWorktreeHidden(projectId: worktree.projectId, path: worktree.path) else {
            throw SessionRefusal.ownerUnavailable(reason: "The worktree is not listed, or is archived.")
        }
        let remoteHost = core.projects.projects.first { $0.id == worktree.projectId }?.host
        guard core.environment.admitsAgent(agentID, remoteHost: remoteHost) else { throw SessionRefusal.agentUnavailable }
        do {
            return (try core.environment.sessionManager(for: worktree, in: core), remoteHost)
        } catch is AlasCoreContext.WorktreeOperationInProgress {
            throw SessionRefusal.ownerUnavailable(reason: "Another operation holds the worktree.")
        }
    }

    static let stoppingReason = "The host is stopping."

    /// The checks a new session passes last, once nothing suspends after them.
    private func admit(_ agentID: String, in manager: ACPSessionManager, worktree: Worktree?, agentHost: String?) async throws {
        // A checkpoint restore being recovered keeps agents out of the owner.
        // This is the last suspension before the session exists; what follows
        // checks synchronously what may have changed while it waited: a
        // checkout being archived or removed disposes its manager, and a
        // worktree's claim stops it admitting work.
        guard await !core.environment.checkpointRecoveryBlocksSessions(owner: manager.owner, in: core) else {
            throw SessionRefusal.ownerUnavailable(reason: Self.checkpointRecoveryReason)
        }
        if let worktree {
            // Still its project's: it can have moved to another one, with
            // another host and agents, while the recovery check waited.
            guard core.projects.worktrees(projectId: worktree.projectId).contains(where: { $0.id == worktree.id }) else {
                throw SessionRefusal.ownerUnavailable(reason: "The worktree is not listed, or is archived.")
            }
            guard core.projects.admitsNewWork(in: worktree),
                  !core.projects.isWorktreeHidden(projectId: worktree.projectId, path: worktree.path)
            else { throw SessionRefusal.ownerUnavailable(reason: "Another operation holds the worktree.") }
        }
        guard !core.isStopping else { throw SessionRefusal.ownerUnavailable(reason: Self.stoppingReason) }
        guard core.sessionManagers[manager.owner] === manager,
              core.environment.admitsSessionCreation(owner: manager.owner, in: core)
        else { throw SessionRefusal.ownerUnavailable(reason: "The session's owner was closed or claimed meanwhile.") }
        guard core.environment.admitsAgent(agentID, remoteHost: agentHost) else { throw SessionRefusal.agentUnavailable }
    }

    /// Sends a prompt as the session's next user turn and waits for that
    /// turn to end. Only the session's writer can.
    public func send(
        _ sessionID: String,
        prompt: String,
        attachments: [ACPMessage.Attachment] = [],
        owner: SessionOwnerID? = nil,
        caller: HostCaller
    ) async throws {
        guard try await submit(sessionID, prompt: prompt, attachments: attachments, owner: owner, caller: caller).value else {
            throw SessionRefusal.promptRejected
        }
    }

    /// Sends a prompt, or queues it behind the running turn, and returns once
    /// it is: the task reports whether it was delivered, when its turn ends.
    /// Refused with `promptRejected` before the prompt is recorded, so its
    /// attachments are the caller's to clean up. `steer` stops the running
    /// turn and sends this prompt at once, keeping the queue. With `owner`,
    /// only that owner's session: ids are not unique across owners.
    public func submit(
        _ sessionID: String,
        prompt: String,
        attachments: [ACPMessage.Attachment] = [],
        steer: Bool = false,
        owner: SessionOwnerID? = nil,
        caller: HostCaller
    ) async throws -> Task<Bool, Never> {
        caller.log(steer ? "sessions.steer" : "sessions.send", sessionID)
        guard !core.isStopping else { throw SessionRefusal.ownerUnavailable(reason: Self.stoppingReason) }
        let manager = try writerManager(for: sessionID, owner: owner)
        let (outcome, report) = AsyncStream<Bool>.makeStream()
        let submission = PromptSubmission()
        let onResult: @MainActor (Bool) -> Void = { delivered in
            if !delivered, submission.isSubmitting { submission.refusedAtOnce = true }
            report.yield(delivered)
            report.finish()
        }
        if steer {
            await manager.steerPrompt(for: sessionID, text: prompt, attachments: attachments, onResult: onResult)
        } else {
            await manager.sendPrompt(for: sessionID, text: prompt, attachments: attachments, onResult: onResult)
        }
        submission.isSubmitting = false
        if submission.refusedAtOnce { throw SessionRefusal.promptRejected }
        return Task {
            for await delivered in outcome { return delivered }
            return false
        }
    }

    /// Loads a listed session so it can be followed: a stored one is read
    /// back from its store, the latest messages first, and refused when that
    /// read fails. Loading takes no lease; following or driving it is a
    /// separate step.
    public func load(_ sessionID: String) async throws {
        guard let manager = rowManager(for: sessionID) else { throw SessionRefusal.notFound }
        _ = manager.placeholderSession(id: sessionID)
        await manager.hydrateIfNeeded(id: sessionID)
        // A transcript that could not be read back is not loaded, whatever
        // placeholder stands in for it.
        guard let session = manager.liveSession(for: sessionID), session.hydrationState == .ready else {
            throw SessionRefusal.notFound
        }
    }

    /// A tool call's full output, which a loaded transcript keeps only for
    /// its newest messages.
    public func fullToolCallContent(_ sessionID: String, toolCallID: String) async -> String? {
        guard let manager = try? liveManager(for: sessionID) else { return nil }
        return await manager.reloadFullToolCallContent(sessionId: sessionID, toolCallId: toolCallID)
    }

    /// Adds `visual` to the transcript of session `sessionID`, which this
    /// instance must drive.
    public func showVisualAid(_ visual: ACPVisualAid, in sessionID: String, caller: HostCaller) async throws {
        caller.log("sessions.showVisualAid", sessionID)
        guard try await writerManager(for: sessionID).showVisualAid(visual, in: sessionID) else { throw SessionRefusal.notWriter }
    }

    /// The visual aid `visualID` in the loaded session's transcript.
    public func visualAid(_ sessionID: String, id visualID: UUID) -> ACPVisualAid? {
        (try? liveManager(for: sessionID))?.liveSession(for: sessionID)?.transcript.visualAid(id: visualID)
    }

    /// Up to `limit` messages before `index` in the loaded session's
    /// transcript, oldest first, at the revision they were read.
    public func transcriptPage(_ sessionID: String, before index: Int, limit: Int) throws -> HostTranscriptPage {
        guard let transcript = try liveManager(for: sessionID).liveSession(for: sessionID)?.transcript else {
            throw SessionRefusal.notFound
        }
        let messages = transcript.messages
        let upper = min(max(index, 0), messages.count)
        let lower = max(0, upper - max(limit, 0))
        return HostTranscriptPage(
            revision: TranscriptRevision(epoch: transcript.changeLog.epoch, version: transcript.changeLog.latestVersion),
            messages: (lower ..< upper).compactMap { HostTranscriptMessage(messages[$0], at: $0) },
            messageCount: messages.count
        )
    }

    /// Whether this instance drives the loaded session `sessionID`.
    public func isWriter(_ sessionID: String) -> Bool {
        (try? writerManager(for: sessionID)) != nil
    }

    /// Why the live session's agent cannot run, or the error it last hit.
    public func agentIssue(_ sessionID: String) -> RemoteAgentIssue? {
        (try? liveManager(for: sessionID))?.liveSession(for: sessionID).flatMap(RemoteSessionConfigProjection.agentIssue(session:))
    }

    /// Takes the session over from the instance that drives it.
    public func takeOver(_ sessionID: String, caller: HostCaller) async throws {
        caller.log("sessions.takeOver", sessionID)
        guard try await liveManager(for: sessionID).takeOver(sessionId: sessionID) else { throw SessionRefusal.notWriter }
    }

    public func setAutoRun(_ sessionID: String, enabled: Bool, caller: HostCaller) async throws {
        caller.log("sessions.setAutoRun", sessionID)
        let manager = try writerManager(for: sessionID)
        await manager.setAutoRun(for: sessionID, enabled: enabled)
        try confirmStillWriter(manager, sessionID)
    }

    /// Changes the session's prompt queue. Editing an item takes it out of
    /// the queue and returns its text; nil when the item is gone or already
    /// being sent.
    @discardableResult
    public func editQueue(_ sessionID: String, _ edit: SessionQueueEdit, caller: HostCaller) async throws -> String? {
        caller.log("sessions.editQueue", sessionID)
        let manager = try writerManager(for: sessionID)
        switch edit {
        case .forceSend(let item): await manager.queueForceSend(for: sessionID, itemId: item)
        case .remove(let item): await manager.queueRemove(for: sessionID, itemId: item)
        case .retry(let item): await manager.queueRetry(for: sessionID, itemId: item)
        case .edit(let item): return await manager.queueEdit(for: sessionID, itemId: item)
        case .clear: await manager.queueClear(for: sessionID)
        case .move(let item, let target): await manager.queueMove(for: sessionID, itemId: item, targetItemId: target)
        case .promote(let item): await manager.queuePromote(for: sessionID, itemId: item)
        }
        return nil
    }

    /// Answers the question a visual aid asks, sending the answer to the agent.
    public func answerVisualAid(_ sessionID: String, visualID: UUID, answer: ACPVisualAid.Answer, caller: HostCaller) async throws {
        caller.log("sessions.answerVisualAid", sessionID)
        let manager = try writerManager(for: sessionID)
        guard await manager.answerVisualAid(id: visualID, answer: answer, in: sessionID) else { throw SessionRefusal.notPending }
    }

    /// Stores an image for a prompt to the session, returning where.
    public func storeImage(_ data: Data, mimeType: String, for sessionID: String) throws -> URL {
        guard let session = try liveManager(for: sessionID).liveSession(for: sessionID) else { throw SessionRefusal.notFound }
        let directory = Paths.acpAttachmentsDir(forWorktreeId: session.worktreeId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = mimeType == "image/png" ? "png" : (mimeType == "image/jpeg" ? "jpg" : "img")
        let url = directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    /// Stops the session's running turn. Like the app's stop button, any
    /// client may: it is the brake, not a way to drive the session.
    public func stop(_ sessionID: String, caller: HostCaller) async throws {
        caller.log("sessions.stop", sessionID)
        try await liveManager(for: sessionID).interruptBypassingLease(for: sessionID)
    }

    /// Renames the session's row, as the app does from its tab.
    public func rename(_ sessionID: String, title: String, caller: HostCaller) throws {
        caller.log("sessions.rename", sessionID)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SessionRefusal.invalidAnswer }
        guard let manager = rowManager(for: sessionID),
              manager.renameSessionCosmetic(id: sessionID, title: trimmed, source: .manual)
        else { throw SessionRefusal.notFound }
    }

    /// Stops the session, closing it with the agent, and hides it from the
    /// list. A session another live instance drives is refused.
    public func archive(_ sessionID: String, caller: HostCaller) async throws {
        caller.log("sessions.archive", sessionID)
        guard let manager = rowManager(for: sessionID) else { throw SessionRefusal.notFound }
        guard try await manager.archiveUnlessDrivenElsewhere(id: sessionID) else { throw SessionRefusal.notWriter }
    }

    public func setModel(_ sessionID: String, modelID: String, caller: HostCaller) async throws {
        caller.log("sessions.setModel", sessionID)
        let manager = try writerManager(for: sessionID)
        if let advertised = manager.liveSession(for: sessionID)?.availableModels, !advertised.isEmpty,
           !advertised.contains(where: { $0.id == modelID }) {
            throw SessionRefusal.invalidSetting
        }
        await manager.setModel(for: sessionID, modelId: modelID)
        try confirmStillWriter(manager, sessionID)
    }

    public func setMode(_ sessionID: String, modeID: String, caller: HostCaller) async throws {
        caller.log("sessions.setMode", sessionID)
        let manager = try writerManager(for: sessionID)
        if let advertised = manager.liveSession(for: sessionID)?.availableModes, !advertised.isEmpty,
           !advertised.contains(where: { $0.id == modeID }) {
            throw SessionRefusal.invalidSetting
        }
        await manager.setMode(for: sessionID, modeId: modeID)
        try confirmStillWriter(manager, sessionID)
    }

    public func setConfigOption(_ sessionID: String, configID: String, value: ACPConfigValue, caller: HostCaller) async throws {
        caller.log("sessions.setConfigOption", sessionID)
        let manager = try writerManager(for: sessionID)
        guard let option = manager.liveSession(for: sessionID)?.availableConfigOptions.first(where: { $0.id == configID }),
              option.acceptsPersistedValue(value)
        else { throw SessionRefusal.invalidSetting }
        // Nil from here means applied later, once the session finishes attaching.
        await manager.setConfigOption(for: sessionID, configId: configID, value: value)?.value
        try confirmStillWriter(manager, sessionID)
    }

    /// Answers the session's pending permission request `requestID`.
    public func answerPermission(
        _ sessionID: String,
        requestID: JSONRPCID,
        optionID: String,
        scope: ACPRequestAnswers.PermissionScope = .optionDefault,
        caller: HostCaller
    ) async throws {
        caller.log("sessions.answerPermission", sessionID)
        let manager = try await answeringManager(for: sessionID)
        // The agent's own request id: the transcript shows every permission
        // under one placeholder id, so it cannot tell one request from the next.
        guard let pending = manager.liveSession(for: sessionID)?.transcript.pendingPermission,
              let policy = manager.permissionPolicy(for: sessionID),
              policy.pendingPermissionRequestID == requestID
        else { throw SessionRefusal.notPending }
        guard let answer = ACPRequestAnswers.permission(pending, optionId: optionID, scope: scope) else {
            throw SessionRefusal.invalidAnswer
        }
        // The request was checked above with nothing awaited since, so a
        // refusal here is the lease, confirmed again right before the agent
        // resumes: recording the decision awaits.
        guard await policy.userDecided(
            scopeKey: answer.scopeKey, optionId: answer.optionId, decision: answer.decision, persistScope: answer.persistScope,
            stillAuthorized: { await manager.confirmsWriterLease(for: sessionID) }
        ) else { throw SessionRefusal.notWriter }
    }

    /// Answers the session's pending question `requestID`.
    public func answerQuestion(_ sessionID: String, requestID: JSONRPCID, answers: [ACPQuestionAnswer], caller: HostCaller) async throws {
        caller.log("sessions.answerQuestion", sessionID)
        let manager = try await answeringManager(for: sessionID)
        guard let session = manager.liveSession(for: sessionID),
              let pending = ACPRequestAnswers.pendingQuestion(in: session), pending.id == requestID
        else { throw SessionRefusal.notPending }
        guard let response = ACPRequestAnswers.question(pending, answers: answers) else { throw SessionRefusal.invalidAnswer }
        guard manager.answerQuestion(for: sessionID, requestId: requestID, response) else { throw SessionRefusal.notPending }
    }

    /// Answers the session's pending plan `requestID`.
    public func respondToPlan(_ sessionID: String, requestID: JSONRPCID, action: ACPRequestAnswers.PlanAction, caller: HostCaller) async throws {
        caller.log("sessions.respondToPlan", sessionID)
        let manager = try await answeringManager(for: sessionID)
        guard let pending = manager.liveSession(for: sessionID)?.transcript.pendingPlan, pending.id == requestID else {
            throw SessionRefusal.notPending
        }
        guard let response = ACPRequestAnswers.plan(pending, action: action) else { throw SessionRefusal.invalidAnswer }
        guard manager.respondToPlan(for: sessionID, requestId: requestID, response) else { throw SessionRefusal.notPending }
    }

    /// Answers the session's pending form or URL request `requestID`.
    public func respondToUserInput(
        _ sessionID: String,
        requestID: UUID,
        answer: ACPRequestAnswers.UserInputAnswer,
        caller: HostCaller
    ) async throws {
        caller.log("sessions.respondToUserInput", sessionID)
        let manager = try await answeringManager(for: sessionID)
        guard let pending = manager.liveSession(for: sessionID)?.transcript.pendingUserInputs.first,
              pending.id == requestID, case .elicitation = pending.source
        else { throw SessionRefusal.notPending }
        guard let action = ACPRequestAnswers.userInput(pending, answer: answer) else { throw SessionRefusal.invalidAnswer }
        guard manager.respondToUserInput(for: sessionID, token: requestID, action: action) else { throw SessionRefusal.notPending }
    }

    static let checkpointRecoveryReason = "An interrupted checkpoint restore must be recovered first."

    /// The Workspace checkout `id`, when it is not archived and nothing is
    /// changing it.
    private func idleCheckout(_ id: UUID) async throws -> WorkspaceCheckout {
        let checkout: WorkspaceCheckout
        do {
            checkout = try await WorkspaceAutomationService(store: core.workspaceStore).checkout(id: id)
        } catch let error as WorkspaceAutomationError {
            throw SessionRefusal.ownerUnavailable(reason: error.message)
        }
        guard checkout.operation == .idle, checkout.archivedAt == nil else {
            throw SessionRefusal.ownerUnavailable(reason: "The Workspace checkout is busy.")
        }
        return checkout
    }

    /// The manager whose live session is `sessionID`.
    /// The managers of `owner`, or every one without it.
    func managers(of owner: SessionOwnerID?) -> [ACPSessionManager] {
        guard let owner else { return Array(core.sessionManagers.values) }
        return core.sessionManagers[owner].map { [$0] } ?? []
    }

    private func liveManager(for sessionID: String, owner: SessionOwnerID? = nil) throws -> ACPSessionManager {
        guard let manager = managers(of: owner).first(where: { $0.liveSession(for: sessionID) != nil }) else {
            throw SessionRefusal.notFound
        }
        return manager
    }

    /// The live session's manager, once the store confirms this instance
    /// still drives it: an answer resumes the agent, which must not act
    /// beside a writer that took the session over.
    private func answeringManager(for sessionID: String) async throws -> ACPSessionManager {
        let manager = try liveManager(for: sessionID)
        guard await manager.confirmsWriterLease(for: sessionID) else { throw SessionRefusal.notWriter }
        return manager
    }

    /// The live session's manager, when this instance drives the session.
    private func writerManager(for sessionID: String, owner: SessionOwnerID? = nil) throws -> ACPSessionManager {
        let manager = try liveManager(for: sessionID, owner: owner)
        guard manager.isWriter(for: sessionID) else { throw SessionRefusal.notWriter }
        return manager
    }

    /// A setting is applied only once the manager confirms the lease; one it
    /// lost meanwhile drops the setting, which the caller must hear about.
    private func confirmStillWriter(_ manager: ACPSessionManager, _ sessionID: String) throws {
        guard manager.isWriter(for: sessionID) else { throw SessionRefusal.notWriter }
    }

    /// The manager that lists `sessionID`, live or not.
    private func rowManager(for sessionID: String) -> ACPSessionManager? {
        core.sessionManagers.values.first { manager in
            manager.liveSession(for: sessionID) != nil || manager.sessionRows.contains { $0.id == sessionID }
        }
    }
}

/// Whether a prompt was refused while it was being submitted, before the
/// session recorded it.
@MainActor
private final class PromptSubmission {
    var isSubmitting = true
    var refusedAtOnce = false
}
