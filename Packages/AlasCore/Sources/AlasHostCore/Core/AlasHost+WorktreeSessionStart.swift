import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasIntegrations
import AlasACP
import AlasSessions

extension SessionsAPI {
    /// Why a session cannot start while a checkpoint restore awaits recovery.
    public static let checkpointRecoveryBlocksStartMessage = "An interrupted checkpoint restore needs recovery before an agent session can start."

    /// Starts session `sessionID` for `agentID` in `worktree`: a stored one
    /// is read back, a new one created, `prompt` queued as its first turn,
    /// and the session connected to its agent. Throws why it could not.
    public func start(
        _ sessionID: ACPSession.ID,
        agentID: String,
        in worktree: Worktree,
        promptID: UUID,
        prompt: String?,
        promptCard: ACPPromptCard? = nil,
        caller: HostCaller
    ) async throws -> ACPSession.ID {
        caller.log("sessions.start", sessionID)
        guard await !core.environment.checkpointRecoveryBlocksSessions(owner: .worktree(worktree.id), in: core) else {
            throw ACPWorktreeSessionBootstrapError(message: Self.checkpointRecoveryBlocksStartMessage)
        }
        // Every await below can cross a delete claim, so admission is
        // rechecked right before a session is created or attached.
        let operationInProgress = "Wait for the current worktree operation to finish before starting sessions."
        guard core.projects.admitsNewWork(in: worktree) else {
            throw ACPWorktreeSessionBootstrapError(message: operationInProgress)
        }
        guard let manager = core.orchestrationManager(for: worktree) else {
            throw ACPWorktreeSessionBootstrapError(message: "Could not create ACP session manager.")
        }
        let bootstrapper = ACPWorktreeSessionBootstrapper(environment: .init(
            sessionExists: { _, id in
                await manager.persistedSessionRow(id: id) != nil
            },
            prepareSession: { _, id, agentId in
                if manager.liveSession(for: id) != nil {
                    await manager.hydrateIfNeeded(id: id)
                    return
                }
                if await manager.persistedSessionRow(id: id) != nil,
                   manager.placeholderSession(id: id) != nil {
                    await manager.hydrateIfNeeded(id: id)
                    return
                }
                guard core.projects.admitsNewWork(in: worktree) else {
                    throw ACPWorktreeSessionBootstrapError(message: operationInProgress)
                }
                _ = manager.createSession(
                    id: id,
                    agentId: agentId,
                    autoRunDefault: core.environment.configuration().harness.acpAutoRunByDefault
                )
            },
            enqueuePrompt: { _, id, promptID, text in
                // Queuing into an attached session would start its turn.
                guard core.projects.admitsNewWork(in: worktree) else { return false }
                return await manager.enqueuePrompt(id: promptID, text: text, card: promptCard, into: id)
            },
            attach: { _, id, freshlyCreated in
                guard await !core.environment.checkpointRecoveryBlocksSessions(owner: .worktree(worktree.id), in: core) else {
                    manager.liveSession(for: id)?.lastError = Self.checkpointRecoveryBlocksStartMessage
                    return
                }
                guard core.projects.admitsNewWork(in: worktree) else {
                    manager.liveSession(for: id)?.lastError = operationInProgress
                    return
                }
                await manager.attach(to: id, freshlyCreated: freshlyCreated)
            },
            readyState: { _, id in
                Self.bootstrapReadyState(for: manager.liveSession(for: id))
            }
        ))
        return try await bootstrapper.start(.init(
            worktreeId: worktree.id,
            sessionID: sessionID,
            agentId: agentID,
            promptID: promptID,
            prompt: prompt
        ))
    }

    /// Creates the prepared session `preparedPrompt.sessionID` for `agentID`
    /// in `worktree`, with its model and its prompt queued or kept as a
    /// draft, and starts it. `opened` runs once the session exists and before
    /// it connects, so the app can show it. Nothing is created when the
    /// worktree does not admit sessions now or the caller was cancelled.
    public func startPrepared(
        _ preparedPrompt: PreparedWorktreeACPPrompt,
        agentID: String,
        in worktree: Worktree,
        caller: HostCaller,
        opened: (ACPSession) -> Void = { _ in }
    ) async {
        guard await !core.environment.checkpointRecoveryBlocksSessions(owner: .worktree(worktree.id), in: core) else { return }
        guard core.projects.admitsNewWork(in: worktree) else { return }
        guard let manager = core.orchestrationManager(for: worktree) else { return }
        // The schedule that asked for this session can be removed while the
        // admission checks above were suspended. Unlike the terminal path
        // (whose PTY only receives a scheduled prompt after its own
        // `Task.isCancelled` guards in `deliverScheduledPrompt`), the ACP
        // route would otherwise create the session, persist a composer
        // draft, enqueue the prompt, and attach the agent regardless,
        // continuing to act on a worktree the user just deleted. Checked
        // before any of that state is touched, not just before attach.
        guard !Task.isCancelled else { return }
        let session = manager.createSession(
            id: preparedPrompt.sessionID,
            agentId: agentID,
            autoRunDefault: core.environment.configuration().harness.acpAutoRunByDefault
        )
        // Picked up by `attach` before the queued prompt goes out, so the
        // first message already runs on the requested model.
        if let modelID = preparedPrompt.modelID {
            manager.pendingModel[session.id] = modelID
        }
        let queuedPrompt: String?
        if preparedPrompt.text.isEmpty {
            queuedPrompt = nil
        } else if preparedPrompt.sendsAutomatically {
            queuedPrompt = preparedPrompt.text
        } else {
            queuedPrompt = nil
            manager.persistComposerDraft(ACPComposerDraft(segments: [.text(preparedPrompt.text)]), for: session)
        }
        opened(session)
        do {
            _ = try await start(
                preparedPrompt.sessionID, agentID: agentID, in: worktree,
                promptID: preparedPrompt.promptID, prompt: queuedPrompt, promptCard: preparedPrompt.card, caller: caller
            )
        } catch {
            manager.liveSession(for: preparedPrompt.sessionID)?.lastError = error.localizedDescription
        }
        await manager.flushPersistence()
    }

    static func bootstrapReadyState(for session: ACPSession?) -> ACPBootstrapReadyState {
        guard let session else { return .failed("Could not start ACP session.") }
        switch session.setupState {
        case .needsSetup(let reason), .setupError(let reason):
            return .needsSetup(reason)
        case .needsAuth(_, let reason):
            return .needsAuthentication(reason ?? "ACP session needs authentication.")
        case .checking, .ready:
            break
        }
        if case .ready = session.agentState {
            return .ready
        }
        if case .failed(let reason) = session.agentState {
            return .failed(reason)
        }
        return .failed("Could not start ACP session.")
    }
}
