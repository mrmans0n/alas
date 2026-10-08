import Foundation
import os

#if DEBUG
typealias ACPRemoteFileWriteForTesting = @MainActor (
    _ path: String,
    _ content: String,
    _ beforeRemoteWrite: @MainActor @Sendable () async throws -> Void
) async throws -> ACPFileWriter.Result
#endif

private struct QueueDispatchProvenancePersistenceError: LocalizedError {
    var errorDescription: String? {
        "Could not save queued message dispatch state."
    }
}

private final class QueueDispatchHandoffTracker: @unchecked Sendable {
    private enum State: Equatable {
        case provenancePending
        case handedOff
        case cancelled
    }

    private let lock = NSLock()
    private var states: [UUID: State] = [:]

    func markProvenancePending(_ itemId: UUID) {
        lock.lock()
        states[itemId] = .provenancePending
        lock.unlock()
    }

    func markHandedOff(_ itemId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch states[itemId] {
        case .provenancePending:
            states[itemId] = .handedOff
            return true
        case .cancelled:
            return false
        case .handedOff, nil:
            return true
        }
    }

    func takeUnhandedItemIDs() -> Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        let unhanded = Set(states.compactMap { itemId, state in
            state == .provenancePending ? itemId : nil
        })
        for itemId in unhanded {
            states[itemId] = .cancelled
        }
        return unhanded
    }

    func finish(_ itemId: UUID) {
        lock.lock()
        states[itemId] = nil
        lock.unlock()
    }
}

/// Prompts whose request crossed the transport handoff, marked from the transport's own callback, which may run off
/// the main actor and before the prompt's continuation does.
private final class PromptHandoffs: @unchecked Sendable {
    private let lock = NSLock()
    private var promptIDs: Set<Int> = []

    func mark(_ promptID: Int) {
        lock.lock()
        promptIDs.insert(promptID)
        lock.unlock()
    }

    func contains(_ promptID: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return promptIDs.contains(promptID)
    }

    func forget(below promptID: Int) {
        lock.lock()
        promptIDs = promptIDs.filter { $0 >= promptID }
        lock.unlock()
    }
}

@MainActor
final class ACPSessionRunner {
    let session: ACPSession
    let connection: ACPConnection
    let persistence: ACPSessionPersistence
    /// LOCAL session id — our UUID assigned by `ACPSessionManager.createSession`,
    /// used as the persistence key in `ACPSessionStore`. The protocol-side
    /// (remote) session id lives on `session.remoteSessionId` and is what
    /// we pass to every `session/*` JSON-RPC call.
    let sessionId: String
    /// Absolute filesystem path of the worktree this session is anchored
    /// to. Distinct from `session.worktreeId`, which is a stable opaque
    /// identifier used for persistence. Every agent file request is
    /// validated against this path before being honoured.
    let worktreePath: String
    let remoteHost: String?
    let usesRemoteHostRegistry: Bool
    /// Single policy instance shared between the runner (where the agent's
    /// `requestPermission` resumes a continuation) and the UI (where the
    /// user's click resolves it). Storing it here is the single source of
    /// truth that previously caused the "tool calls stuck on pending"
    /// bug — the UI was creating its own copy with no continuation.
    let policy: ACPPermissionPolicy
    /// Key of the permission this session is parked on, or nil. Read by the
    /// manager when deciding whether a blocked child is still blocked on the
    /// same request.
    var blockedPermissionRequestKey: String? {
        policy.pendingPermissionRequestID.map(ACPChildBlocker.requestKey)
    }
    /// Optional hook called before each agent file-write to check whether the
    /// target path has a live, dirty editor buffer. When it returns `true` a
    /// `systemNotice` is appended to the session so the user is aware the
    /// write landed on top of unsaved changes. `nil` disables the check.
    private let onDirtyCheck: ((String) -> Bool)?
    /// Optional hook used by the read handler to pull in-memory editor
    /// contents for an open dirty buffer, falling back to disk when the
    /// closure returns `nil`. Lets the agent see what the user sees.
    private let onLiveBufferRead: ((String) -> String?)?
    private let onUserCancel: (() -> Void)?
    /// Called when the runner forces transcript tail-follow before recording
    /// a user prompt, so manager-owned scroll memory stays in sync with the
    /// runtime session state.
    private let onResumeTranscriptTail: (() -> Void)?
    /// The sanitized + extras-merged env the agent process itself was
    /// launched with. Used to seed the terminal host so agent-spawned
    /// commands inherit exactly the same view — including the stripped
    /// CLAUDECODE/CLAUDE_SESSION_ID markers that would otherwise leak
    /// back in via a re-augment from `ProcessInfo`.
    private let agentEnv: [String: String]
    private let ownerInstanceId: String?
    private let canWrite: () -> Bool
    private let validateLease: () async -> Bool
    private let leaseFenceProvider: () -> ACPSessionLeaseFence?
    private let onAuthRequired: ((ACPSessionRunner, String) async -> Void)?
    private let onPersist: (() -> Void)?
    /// Fires only when a message row was actually written (a normal
    /// `persistIndices`/`persistFromIndex` commit, or a takeover-salvaged
    /// insert) — unlike `onPersist`, which also fires unconditionally on
    /// `stop()` for cross-process/lease notification even when nothing was
    /// written. Callers that track "last activity" want this one.
    private let onMessageActivity: (() -> Void)?
    private let onPromptWorkChanged: (() -> Void)?
    private let onSuccessfulTurn: @MainActor (NextPromptCompletedTurn) -> Void
    /// Fires on the main actor once per `sendNow` prompt whose RPC settled
    /// while it was still the active prompt. Recovery-context prompts and
    /// superseded prompts do not fire.
    private let onTurnCompleted: ((ACPTurnCompletion) -> Void)?
    /// Every turn that reached the agent, for usage history: each completed one, and one a steer superseded once its
    /// result arrives, which `onTurnCompleted` never reports.
    private let onTurnUsage: ((ACPTurnCompletion) -> Void)?
    /// Fires when this session's permission policy parks for a human. Only
    /// meaningful for a delegated child, whose parent is told; the manager
    /// decides that, not the runner.
    private let onPermissionBlocked: ((ACPChildBlocker) -> Void)?
    private var activePromptStartedAt: Int64?
    /// The client's `yieldedUpdateCount` when the active prompt started: updates past it belong to the turn.
    private var activePromptStreamStart = 0
    /// See `nextSentAt`.
    private var lastSentAt: Int64 = 0
    /// Where each recent prompt went out on the stream, by prompt id. Kept apart from `unreportedPrompts`, so a later
    /// prompt still bounds an earlier one's cost after it was reported or dropped.
    private var sentStreamStarts: [Int: Int] = [:]
    /// Prompts sent to the agent whose usage is not reported yet, by prompt id.
    private var unreportedPrompts: [Int: (startedAt: Int64, sentAt: Int64, streamStart: Int, model: String?, recovery: Bool)] = [:]
    /// Which of them reached the transport; see `takeUnreportedUsage`.
    private let promptHandoffs = PromptHandoffs()
    /// Finished prompts' usage, by prompt id, held until every prompt sent before them has reported: a session's
    /// turns are recorded in the order they were sent, each turn's cost being measured from the one before.
    private var heldUsage: [Int: ACPTurnCompletion] = [:]
    /// Updates `updatesTask` took off the stream; compared with the client's `yieldedUpdateCount`.
    private var dequeuedUpdateCount = 0
    /// Recent cost-bearing `usage_update`s by their position on the stream, so a turn's cost takes only those sent
    /// between its prompt and its result.
    private var costLog: [(index: Int, cost: ACPUsageInfo.Cost)] = []
    private var activePromptDelegatedSource: ACPDelegatedPromptSource?
    /// Transcript message count when this turn's prompt was recorded. Bounds
    /// `emitTurnCompleted`'s search for the turn's own last agent message, so
    /// a turn whose output hasn't drained yet reports no text rather than the
    /// previous turn's.
    private var activePromptTranscriptFloor: Int?
    private let onQueuedPromptDispatchRegistration: (@MainActor (UUID) -> (@Sendable () -> Void)?)?
    private let onSessionTitleUpdated: ((String) -> Void)?
    private let localTitlesEnabled: @MainActor () -> Bool
    private let autoResumeAfterUsageLimit: @MainActor () -> Bool
    private let localTitleGenerator: @Sendable (String) async -> String?
    private var providerTitleRevision = 0
    private var localTitleAttempted = false
    private var localTitleTask: Task<Void, Never>?
    /// Fires whenever a live update may change what the agent has advertised
    /// as its models or thinking levels — an `availableModelsUpdate`, or a
    /// `sessionConfigOptionsUpdate` — with the normalized chip state. The
    /// initial `session/new`/`session/load` result is reported separately by
    /// whoever calls `attach`; this covers changes reported later on the
    /// same connection.
    private let onChipsObserved: ((_ agentId: String, _ chips: ACPChipState) -> Void)?
    private let onPersistedConfigOptionValues: (@MainActor ([String: ACPConfigValue]) -> Void)?
    private let onCheckpointCapture: (@MainActor (_ prompt: String, _ hasAttachments: Bool) async -> CheckpointID?)?
    /// Text plugins add to each prompt (API 7 context providers): wire-only, never in the transcript.
    private let pluginContext: (@MainActor (_ sessionID: String) async -> [String])?
    /// Context sent in place of an attached session's link (see
    /// `ACPSessionReference`), or nil when that session is unavailable.
    private let sessionReferenceContext: (@MainActor (_ referencedSessionId: String) async -> String?)?
    private let isConnectionCurrent: () -> Bool
#if DEBUG
    var remoteFileWriteForTesting: ACPRemoteFileWriteForTesting?
    var queueDispatchProvenancePersistedForTesting: (@MainActor @Sendable (UUID) async -> Void)?
    var beforePersistenceForTesting: (@MainActor () async -> Void)?
    var onPersistenceFlushForTesting: (@MainActor () -> Void)?
    var activePromptIDForTesting: Int? { activePromptID }
    func visualAidFirstWriteWaiterCountForTesting(id: UUID) -> Int { unconfirmedVisualAids[id]?.count ?? 0 }
#endif
    private var updatesTask: Task<Void, Never>?
    private var permissionsTask: Task<Void, Never>?
    private var cancelRequestsTask: Task<Void, Never>?
    private var filesTask: Task<Void, Never>?
    private var terminalsTask: Task<Void, Never>?
    /// `$/cancel_request` ids (OpenCode v2) that haven't yet matched a
    /// dequeued permission or file request. A cancellation can arrive
    /// before the request it targets — buffered broker replay, or both
    /// delivered in one transport batch racing `permissionsTask`/`filesTask`
    /// — so each consumer checks and drains this set before starting work
    /// on a freshly dequeued id, instead of the id being silently dropped.
    private var pendingCancelledRequestIDs: Set<JSONRPCID> = []
    private var authStatusTask: Task<Void, Never>?
    private var seq: Int64 = 0
    private var scheduledQueueWakeTask: Task<Void, Never>?
    private let queueDispatchHandoffTracker = QueueDispatchHandoffTracker()
    /// Monotonic prompt counter + active/cancelled bookkeeping (inherited
    /// from main / PR #338). Reused by the queue's sendNow path:
    /// `activePromptID` identifies the task that currently owns
    /// `streamingState`; `cancelledPromptIDs` carries explicit
    /// invalidations (steer, userCancel) so a slow `session/cancel`
    /// can't let a stale completion clobber the successor task.
    private var activePromptID: Int?
    private var cancelledPromptIDs: Set<Int> = []
    /// Retains the most recently dispatched prompt RPC so steering can wait
    /// for its response after sending the cancellation notification.
    private var latestPromptTask: Task<Void, Never>?
    private var appliedUpdateCount = 0
    private var persistedMessageCount: Int
    /// Callers awaiting the outcome of one specific row write, and the ones
    /// among them a confirmed write actually stored. An awaiter names the row
    /// id AND the exact payload it expects: another write of the same row id
    /// (an earlier one still in flight when the caller mutated the row) must
    /// not confirm it. Populated only while an `awaitingWrite` call is in
    /// flight, so the fire-and-forget persistence path pays nothing.
    private struct AwaitedWrite {
        let rowID: String
        let payload: Data
    }
    private var awaitedWrites: [UUID: AwaitedWrite] = [:]
    private var confirmedAwaitedWrites: Set<UUID> = []
    /// Visual aids whose first write is unresolved, with the answers waiting on it.
    private var unconfirmedVisualAids: [UUID: [CheckedContinuation<Bool, Never>]] = [:]
    /// Visual aids whose first write failed for good. One of these may still be in the transcript (a
    /// ghost kept so the rows behind it do not shift) although the agent was told the visual failed
    /// and may show it again, so it never takes an answer for the rest of the session.
    private var failedFirstWriteVisualAidIDs: Set<UUID> = []
    private var persistenceTail: Task<Void, Never>?
    private var persistenceGeneration = 0
    /// Outcome of the most recently COMPLETED write queued via
    /// `persistIndices` or `persistSubagentIndices` that has not yet
    /// reached an acknowledgement boundary, regardless of whether that
    /// write itself carried a durable acknowledgement.
    ///
    /// Consulted (and reset) by `acknowledgeAfterQueuedPersistence`'s
    /// barrier and by the two `persistIndices`/`persistSubagentIndices`
    /// completions themselves. A barrier's own fence re-check only proves
    /// the writer lease is STILL valid right now — it says nothing about
    /// whether an earlier queued write (the synthetic spawn's row,
    /// typically, in the SAME batch) actually succeeded on its own terms.
    /// A transient failure unrelated to the lease (a SQLite `step` error,
    /// say) would otherwise slip past the fence check alone, and the
    /// barrier would acknowledge a row that was never stored.
    ///
    /// Set unconditionally inside each write's own completion — not the
    /// caller-supplied one, which is nil whenever that particular update
    /// carries no ack of its own (the spawn half of an OpenCode-normalized
    /// batch, always) — so it reflects every real write, acked or not.
    ///
    /// Reset to `true` the moment a write DOES carry the caller's own
    /// completion — i.e. the moment a batch reaches its acknowledgement
    /// boundary — rather than left to linger. Without the reset, one
    /// transient failure anywhere would AND itself into every later
    /// `succeeded` check forever, permanently withholding every subsequent
    /// acknowledgement for the rest of this runner's lifetime — far worse
    /// than the narrow, single-batch hazard this flag exists to close.
    private var lastQueuedPersistenceSucceeded = true
    private var pendingQueueForceSendsAfterPersistence: [UUID] = []
    private var stopped = false
    private var pendingCompletedOutputBoundary: (updateCount: Int, successfulTurn: NextPromptCompletedTurn?)?
    private var turnPublicationGeneration = 0
#if DEBUG
    /// Awaited before `updatesTask` takes each update off the stream.
    var beforeDequeueForTesting: (@MainActor () async -> Void)?
    var onPromptResponseProcessedForTesting: ((Int) -> Void)?
    // Tests opt in with an empty dictionary; ordinary Debug runners retain no handles.
    var turnPublicationTasksForTesting: [Int: Task<Void, Never>]?

    func waitForTurnPublicationForTesting(promptID: Int) async {
        await turnPublicationTasksForTesting?[promptID]?.value
        turnPublicationTasksForTesting?[promptID] = nil
    }
#endif
    private var pendingStreamingPersistIndices: Set<Int> = []
    /// Revisions distinguish a new streamed chunk from the payload currently
    /// being written. A successful write may only clear the revision it saw.
    private var pendingStreamingPersistRevisions: [Int: Int] = [:]
    private var streamingPersistInFlightIndices: Set<Int> = []
    private var pendingStreamingPersistSnapshots: [Int: StreamingPersistSnapshot] = [:]
    private var pendingStreamingPersistAcknowledgements: [ACPDurableConsumptionAcknowledgement] = []
    /// The exact payload bytes this runner last wrote for each message row.
    /// Used as the compare-and-swap base when a takeover forces a stand-down
    /// flush, so the CAS never reads the (potentially growing) payload blob
    /// from SQLite on the streaming path.
    private var lastPersistedPayloads: [Int: Data] = [:]
    private var capturingPersistedBaseIndices: Set<Int> = []
    /// Set once a cross-process takeover is detected mid-stream. While true,
    /// streamed chunks are no longer buffered for persistence and the
    /// stand-down flush writes the frozen snapshots via compare-and-swap
    /// instead of the (now-diverging) live transcript.
    private var streamingLeaseLost = false
    private var streamingPersistTask: Task<Void, Never>?
    private let streamingPersistDebounceNanos: UInt64
    private struct PendingIncomingUpdate {
        let params: ACPSessionUpdateParams
        let receivedWhileHoldingLease: Bool
    }

    private var pendingIncomingUpdates: [PendingIncomingUpdate] = []
    private var incomingUpdateFlushTask: Task<Void, Never>?
    private let incomingUpdateCoalesceNanos: UInt64
    /// How long a cancelled turn's usage waits for its prompt's result, which carries its tokens.
    static let cancelledUsageWait: Duration = .seconds(10)
    private let usageWaitSleep: @Sendable (Duration) async -> Void
    private var suppressingLoadReplay: Bool
    private var loadReplaySuppressionTarget: Int?
    private var observedUpdateCount = 0
    /// Set while `steer` is between `userCancel` and the redirect's
    /// `sendNow`. `flushQueueIfIdle` no-ops while this is true so a queue
    /// mutation racing the cancel round-trip can't drain a pending item
    /// ahead of the steer's replacement prompt. Once the redirect is in
    /// flight, normal drain semantics resume.
    private var steerInProgress: Bool = false
    private var queueSaveGeneration = 0
    private var deferredQueueAcknowledgements: [(generation: Int, acknowledgement: ACPDurableConsumptionAcknowledgement?)] = []
    private var nativeSteeringGeneration = 0
    private var nativeSteeringInProgress = false
    private var nativeSteeringQueueItemID: UUID?
    private var steeringRowPersistencePending = false
    private var detachedSteeringTurn = false
    private var lastSteeringThreadStatus: String?
    private var steeringSawIdle = false
    private var steeringSawActive = false
    private var steeringSawActiveAfterIdle = false
    private var pendingForceSendQueuedItemID: UUID?
    /// Holds an idle source session at its persisted remote head while
    /// `session/fork` is in flight. New prompts remain queued until the
    /// target adapter has created the branch.
    private var nativeForkBarrierActive = false
    var onUnexpectedDisconnect: (() -> Void)?

    /// How many trailing rows to retain in `lastPersistedPayloads`. Only the
    /// actively-streamed tail is ever re-persisted, so older rows can be
    /// dropped; a pruned row that is somehow touched again falls back to a
    /// one-time SQLite read in `freezeStreamingPersistSnapshots`.
    private static let lastPersistedPayloadsWindow = 256

    private struct StreamingPersistSnapshot {
        let kind: String
        let payload: Data
        let basePayload: Data?
    }

    init(session: ACPSession, connection: ACPConnection, store: ACPSessionStore? = nil,
         sessionId: String, worktreePath: String,
         agentEnv: [String: String] = ProcessInfo.processInfo.environment,
         remoteHost: String? = nil,
         usesRemoteHostRegistry: Bool = true,
         suppressingLoadReplay: Bool = false,
         onDirtyCheck: ((String) -> Bool)? = nil,
         onLiveBufferRead: ((String) -> String?)? = nil,
         onUserCancel: (() -> Void)? = nil,
         onAuthRequired: ((ACPSessionRunner, String) async -> Void)? = nil,
         onPersist: (() -> Void)? = nil,
         onMessageActivity: (() -> Void)? = nil,
         onPromptWorkChanged: (() -> Void)? = nil,
         onSuccessfulTurn: @escaping @MainActor (NextPromptCompletedTurn) -> Void = { _ in },
         onTurnCompleted: ((ACPTurnCompletion) -> Void)? = nil,
         onTurnUsage: ((ACPTurnCompletion) -> Void)? = nil,
         onPermissionBlocked: ((ACPChildBlocker) -> Void)? = nil,
         onQueuedPromptDispatchRegistration: (@MainActor (UUID) -> (@Sendable () -> Void)?)? = nil,
         onSessionTitleUpdated: ((String) -> Void)? = nil,
         localTitlesEnabled: @escaping @MainActor () -> Bool = { false },
         autoResumeAfterUsageLimit: @escaping @MainActor () -> Bool = { true },
         localTitleGenerator: @escaping @Sendable (String) async -> String? = { await ACPLocalTitleGenerator.generate(from: $0, fallback: nil) },
         onChipsObserved: ((_ agentId: String, _ chips: ACPChipState) -> Void)? = nil,
         onPersistedConfigOptionValues: (@MainActor ([String: ACPConfigValue]) -> Void)? = nil,
         onResumeTranscriptTail: (() -> Void)? = nil,
         onCheckpointCapture: (@MainActor (_ prompt: String, _ hasAttachments: Bool) async -> CheckpointID?)? = nil,
         pluginContext: (@MainActor (_ sessionID: String) async -> [String])? = nil,
         sessionReferenceContext: (@MainActor (_ referencedSessionId: String) async -> String?)? = nil,
         isConnectionCurrent: @escaping () -> Bool = { true },
         streamingPersistDebounceNanos: UInt64 = 250_000_000,
         incomingUpdateCoalesceNanos: UInt64 = 16_000_000,
         usageWaitSleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         ownerInstanceId: String? = nil,
         persistence: ACPSessionPersistence? = nil,
         persistedMessageCount: Int? = nil,
         canWrite: (() -> Bool)? = nil,
         validateLease: (() async -> Bool)? = nil,
         leaseFenceProvider: (() -> ACPSessionLeaseFence?)? = nil)
    {
        precondition(store != nil || persistence != nil, "ACPSessionRunner requires persistence")
        let resolvedPersistence = persistence ?? ACPSessionPersistence(path: store!.path)
        self.session = session
        self.onSuccessfulTurn = onSuccessfulTurn
        self.connection = connection
        self.persistence = resolvedPersistence
        self.sessionId = sessionId
        self.worktreePath = worktreePath
        self.remoteHost = remoteHost
        self.usesRemoteHostRegistry = usesRemoteHostRegistry
        self.agentEnv = agentEnv
        self.ownerInstanceId = ownerInstanceId
        self.onAuthRequired = onAuthRequired
        self.onPersist = onPersist
        self.onMessageActivity = onMessageActivity
        self.onPromptWorkChanged = onPromptWorkChanged
        self.onTurnCompleted = onTurnCompleted
        self.onTurnUsage = onTurnUsage
        self.onPermissionBlocked = onPermissionBlocked
        self.onQueuedPromptDispatchRegistration = onQueuedPromptDispatchRegistration
        self.onSessionTitleUpdated = onSessionTitleUpdated
        self.localTitlesEnabled = localTitlesEnabled
        self.autoResumeAfterUsageLimit = autoResumeAfterUsageLimit
        self.localTitleGenerator = localTitleGenerator
        self.onChipsObserved = onChipsObserved
        self.onPersistedConfigOptionValues = onPersistedConfigOptionValues
        self.streamingPersistDebounceNanos = streamingPersistDebounceNanos
        self.incomingUpdateCoalesceNanos = incomingUpdateCoalesceNanos
        self.usageWaitSleep = usageWaitSleep
        self.suppressingLoadReplay = suppressingLoadReplay
        if suppressingLoadReplay {
            session.beginSuppressedReplaySideEffects()
        }
        self.onDirtyCheck = onDirtyCheck
        self.onLiveBufferRead = onLiveBufferRead
        self.onUserCancel = onUserCancel
        self.onResumeTranscriptTail = onResumeTranscriptTail
        self.onCheckpointCapture = onCheckpointCapture
        self.pluginContext = pluginContext
        self.sessionReferenceContext = sessionReferenceContext
        self.isConnectionCurrent = isConnectionCurrent
        let initialPersistedMessageCount = persistedMessageCount
            ?? store.flatMap { try? $0.messageCount(sessionId: sessionId) }
            ?? 0
        self.persistedMessageCount = initialPersistedMessageCount
        self.seq = Int64(initialPersistedMessageCount)
        // Capture the three values holdsLeaseForWrite() reads so the closure
        // can be formed before `self` is fully initialised (policy is the
        // last stored property). The logic is identical to holdsLeaseForWrite.
        let _sessionId = sessionId
        let _ownerInstanceId = ownerInstanceId
        let defaultCanWrite = {
            guard let id = _ownerInstanceId else { return true }
            guard let store else { return false }
            return (try? store.loadLease(sessionId: _sessionId))?.ownerInstance == id
        }
        self.canWrite = canWrite ?? defaultCanWrite
        self.validateLease = validateLease ?? { canWrite?() ?? defaultCanWrite() }
        let initialLease = ownerInstanceId.flatMap { owner in
            guard let lease = try? store?.loadLease(sessionId: sessionId),
                  lease.ownerInstance == owner else { return nil as ACPSessionLeaseFence? }
            return ACPSessionLeaseFence(
                sessionId: sessionId,
                ownerInstance: owner,
                token: lease.token
            )
        }
        self.leaseFenceProvider = leaseFenceProvider ?? { initialLease }
        let permissionBlocked = onPermissionBlocked
        let policySessionId = sessionId
        self.policy = ACPPermissionPolicy(
            session: session,
            log: ACPPermissionDecisionLog(
                persistence: resolvedPersistence,
                canWrite: canWrite ?? defaultCanWrite,
                leaseFence: leaseFenceProvider
            ),
            onBlocked: { requestID, params in
                permissionBlocked?(ACPChildBlocker(
                    sessionId: policySessionId,
                    requestKey: ACPChildBlocker.requestKey(requestID),
                    kind: .permission,
                    summary: params.toolCall.title
                        ?? params.toolCall.name
                        ?? "a tool call"
                ))
            }
        )
    }

    private func enqueuePersistence(
        _ operation: @escaping @Sendable (ACPSessionPersistence) async throws -> Void
    ) {
        let previous = persistenceTail
        let persistence = persistence
#if DEBUG
        let beforePersistence = beforePersistenceForTesting
#endif
        persistenceGeneration += 1
        persistenceTail = Task { @MainActor in
#if DEBUG
            await beforePersistence?()
#endif
            await previous?.value
            guard !Task.isCancelled else { return }
            try? await operation(persistence)
        }
    }

    private func enqueuePersistence<Result: Sendable>(
        _ operation: @escaping @Sendable (ACPSessionPersistence) async throws -> Result,
        completion: @escaping @MainActor (Result?) async -> Void
    ) {
        let previous = persistenceTail
        let persistence = persistence
#if DEBUG
        let beforePersistence = beforePersistenceForTesting
#endif
        persistenceGeneration += 1
        let task = Task { @MainActor in
#if DEBUG
            await beforePersistence?()
#endif
            await previous?.value
            guard !Task.isCancelled else { return }
            await completion(try? await operation(persistence))
        }
        persistenceTail = Task { await task.value }
    }

    func flushPersistence() async {
#if DEBUG
        onPersistenceFlushForTesting?()
#endif
        while let tail = persistenceTail {
            let generation = persistenceGeneration
            await tail.value
            if persistenceGeneration == generation { return }
        }
    }

    private var observedBackgroundTaskIds: Set<String> = []
    private var backgroundStopRequests: Set<String> = []
    private var backgroundWakeConfirmations: [UUID: Int] = [:]
    private var backgroundWakeAcknowledgements: [UUID: [ACPDurableConsumptionAcknowledgement]] = [:]
    private var backgroundCancellationInProgress = false

    func start() {
        session.clearRetryStatus()
        updatesTask = Task { [weak self] in
            guard let self else { return }
            for await u in self.connection.client.incomingUpdates {
#if DEBUG
                await self.beforeDequeueForTesting?()
#endif
                self.dequeuedUpdateCount += 1
                guard self.isConnectionCurrent() else { continue }
                if case .usageUpdate(let info) = u.update, let cost = info.cost {
                    self.costLog.append((self.dequeuedUpdateCount, cost))
                    if self.costLog.count > 32 { self.compactCostLog() }
                }
                self.enqueueIncomingUpdate(u)
            }
            // The for-await also exits when the task gets cancelled —
            // that's the intentional detach path (tab close, worktree
            // teardown). Don't pollute the persisted transcript with
            // an "Agent disconnected" notice in that case; only flag
            // the unexpected stream-end.
            if Task.isCancelled || !self.isConnectionCurrent() { return }
            self.turnPublicationGeneration += 1
            self.discardPendingSuccessfulTurn("start: connection ended unexpectedly")
            self.flushPendingIncomingUpdates(flushQueueWhenBoundaryReady: false)
            await MainActor.run {
                self.session.clearRetryStatus()
                let startedRecovery = self.session.beginConnectionRecovery()
                self.session.agentState = .disconnected
                self.session.transcript.streamingState = .idle
                // A child session cannot outlive the connection that
                // carried it; stop its row spinning.
                self.persistIndices(self.session.markSubagentsDisconnected())
                // No flushQueueIfIdle() here: the connection is dead, so
                // the next prompt would just fail. The queue stays put
                // and drains naturally on the next successful reattach.
                if startedRecovery {
                    self.appendAndPersistSystemNotice("Agent disconnected.")
                }
                self.onUnexpectedDisconnect?()
            }
        }

        permissionsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await (id, params) in self.connection.client.permissionRequests {
                guard self.isConnectionCurrent() else { continue }
                self.flushPendingIncomingUpdates()
                if self.pendingCancelledRequestIDs.remove(id) != nil {
                    let response = ACPPermissionResponse(outcome: .cancelled)
                    self.connection.client.respondToPermission(id: id, response: response)
                    // Matches the below: a metadata-bearing request cancelled
                    // before evaluate() even starts must still get the same
                    // treatment as one cancelled afterward, or its
                    // presentation is silently lost.
                    await self.persistPermissionDecision(params: params, response: response)
                    continue
                }
                let scopeKey = "tool:\(params.toolCall.title ?? params.toolCall.toolCallId)"
                let response = await self.policy.evaluate(
                    scopeKey: scopeKey, options: params.options, params: params, requestID: id)
                guard self.isConnectionCurrent() else { continue }
                self.connection.client.respondToPermission(id: id, response: response)
                await self.persistPermissionDecision(params: params, response: response)
            }
        }

        cancelRequestsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await id in self.connection.client.cancelRequests {
                guard self.isConnectionCurrent() else { continue }
                if self.policy.cancelRequest(id: id) { continue }
                self.pendingCancelledRequestIDs.insert(id)
            }
        }

        startAuthStatusListening()

        // Agent-spawned terminals must see the exact env the agent
        // itself was launched with — same augmented PATH (npm / cargo
        // resolve under launchd's minimal PATH) and same scrubbed
        // CLAUDECODE/CLAUDE_SESSION_ID markers (otherwise a Claude-
        // aware CLI run from the terminal refuses to start).
        session.terminalHost.updateContext(sessionCwd: worktreePath,
                                           sessionEnv: agentEnv,
                                           sessionRemoteHost: effectiveRemoteHost())

        filesTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let writer = ACPFileWriter(
                worktreeRoot: URL(fileURLWithPath: self.worktreePath)
            )
            let remoteServer = self.effectiveRemoteHost().map {
                ACPRemoteFileServer(host: $0, worktreeRoot: self.worktreePath)
            }
            for await req in self.connection.client.fileRequests {
                guard self.isConnectionCurrent() else { continue }
                self.flushPendingIncomingUpdates()
                switch req {
                case .read(let id, let params):
                    if self.pendingCancelledRequestIDs.remove(id) != nil {
                        self.connection.client.respondToFileRequest(
                            id: id,
                            result: .failure(.init(code: -32800, message: "cancelled", data: nil)))
                        continue
                    }
                    do {
                        if let remoteServer {
                            let target = try remoteServer.lexicallyResolveInsideWorktree(path: params.path)
                            let live = self.onLiveBufferRead?(target)
                            let full = try await remoteServer.read(path: params.path, liveBuffer: live)
                            // Weaker than the local guard, and deliberately
                            // so: the remote read fetches the whole file
                            // regardless of range, so by the time its size is
                            // known it has already crossed the network.
                            // Sizing it first would add an `fs/stat` round
                            // trip to every remote read to catch a rare one.
                            // Refusing here still spares the JSON encode — a
                            // second copy — and the undeliverable response
                            // that would otherwise strand the adapter.
                            let sliced = Self.sliceLines(full, line: params.line, limit: params.limit)
                            if let refusal = Self.readRefusal(
                                name: (target as NSString).lastPathComponent,
                                bytes: sliced.utf8.count
                            ) {
                                self.connection.client.respondToFileRequest(
                                    id: id,
                                    result: .failure(.init(code: -32000, message: refusal, data: nil))
                                )
                                continue
                            }
                            let body = try JSONEncoder().encode(ACPFsReadResult(content: sliced))
                            self.connection.client.respondToFileRequest(id: id, result: .success(body))
                            continue
                        }
                        // Same containment check as the write path —
                        // without this an adapter could request any
                        // absolute path (e.g. `~/.ssh/config`) and
                        // exfiltrate it without a permission prompt.
                        // Cheap pure string work, safe on-main.
                        let target = try writer.resolveInsideWorktree(path: params.path)
                        let diskTarget = try writer.managedDiskURLInsideWorktree(path: params.path)
                        // Prefer the live editor buffer when the file
                        // is open and dirty so the agent sees what the
                        // user sees (avoids "agent reads stale disk,
                        // then writes a replacement that clobbers
                        // unsaved edits"). This lookup reads editor
                        // state, so it MUST stay on the main actor; only
                        // the resulting snapshot crosses the hop below.
                        let live = self.onLiveBufferRead?(target.path)
                        // Disk read + slice + encode run off-main.
                        let outcome = await Self.serveRead(
                            target: diskTarget, liveBuffer: live,
                            line: params.line, limit: params.limit
                        )
                        // A detach/takeover can cancel this task during the
                        // off-main read. `return` (not `break`) so we exit the
                        // whole `filesTask` loop — a bare `break` only leaves
                        // the `switch` and would let a buffered next request
                        // (e.g. an outside-worktree read that persists a notice)
                        // run on a runner that no longer owns the session.
                        if Task.isCancelled { return }
                        switch outcome {
                        case .success(let body):
                            self.connection.client.respondToFileRequest(id: id, result: .success(body))
                        case .failure(let message):
                            self.connection.client.respondToFileRequest(
                                id: id,
                                result: .failure(.init(code: -32000, message: message, data: nil))
                            )
                        }
                    } catch ACPFileWriter.Error.outsideWorktree(let p) {
                        self.appendAndPersistSystemNotice("Blocked read outside worktree: \(p)")
                        self.connection.client.respondToFileRequest(
                            id: id,
                            result: .failure(.init(code: -32001, message: "path outside worktree", data: nil))
                        )
                    } catch ACPRemoteFileServer.ServerError.outsideWorktree(let p) {
                        self.appendAndPersistSystemNotice("Blocked read outside worktree: \(p)")
                        self.connection.client.respondToFileRequest(
                            id: id,
                            result: .failure(.init(code: -32001, message: "path outside worktree", data: nil))
                        )
                    } catch {
                        self.connection.client.respondToFileRequest(
                            id: id,
                            result: .failure(.init(code: -32000, message: error.localizedDescription, data: nil))
                        )
                    }
                case .write(let id, let params):
                    if self.pendingCancelledRequestIDs.remove(id) != nil {
                        self.connection.client.respondToFileRequest(
                            id: id,
                            result: .failure(.init(code: -32800, message: "cancelled", data: nil)))
                        break
                    }
                    // Agents may write without asking first, so the read-only
                    // permission gate alone can't stop a side session.
                    if self.session.readOnlyRestricted {
                        self.session.recordReadOnlyBlock("write \(params.path)")
                        self.connection.client.respondToFileRequest(
                            id: id,
                            result: .failure(.init(code: -32002, message: "read-only side session", data: nil)))
                        break
                    }
                    // Guard the actual disk write: if this runner has lost
                    // the session lease (takeover), deny the request rather
                    // than modifying the working tree on behalf of a session
                    // another instance now owns.
                    // Terminal side effects also revalidate ownership after
                    // their lease await, so a superseded request cannot resume
                    // and execute after stop()'s killAll().
                    //
                    // Unlike the read path, the write stays fully on the main
                    // actor. An in-app editor save also runs on the main actor,
                    // so a synchronous write here cannot run in parallel with —
                    // and silently clobber — a concurrent save of the same file,
                    // and the lease check / dirty gate stay atomic with the
                    // replacement. Hopping the write off-main safely requires
                    // serializing agent writes against editor saves; that is
                    // deferred to a follow-up. The unbounded-read hot path
                    // (`serveRead`) carries the bulk of the main-thread win.
                    guard await self.hasConfirmedLeaseForSideEffect() else {
                        self.connection.client.respondToFileRequest(
                            id: id,
                            result: .failure(.init(code: -32003, message: "lease lost to another instance", data: nil)))
                        break
                    }
                    guard !Task.isCancelled, self.isConnectionCurrent() else {
                        self.connection.client.respondToFileRequest(
                            id: id,
                            result: .failure(.init(code: -32800, message: "cancelled", data: nil)))
                        continue
                    }
                    let editorHasUnsavedChanges = self.onDirtyCheck?(params.path) == true
                    do {
                        let res: ACPFileWriter.Result
                        if let remoteServer {
                            let beforeRemoteWrite: @MainActor @Sendable () async throws -> Void = {
                                guard !Task.isCancelled, self.isConnectionCurrent() else {
                                    throw CancellationError()
                                }
                                guard await self.hasConfirmedLeaseForSideEffect() else {
                                    throw ACPRemoteFileServer.ServerError.leaseLost
                                }
                                guard !Task.isCancelled, self.isConnectionCurrent() else {
                                    throw CancellationError()
                                }
                            }
#if DEBUG
                            if let remoteFileWriteForTesting {
                                res = try await remoteFileWriteForTesting(
                                    params.path,
                                    params.content,
                                    beforeRemoteWrite
                                )
                            } else {
                                res = try await remoteServer.write(
                                    path: params.path,
                                    content: params.content,
                                    beforeRemoteWrite: beforeRemoteWrite
                                )
                            }
#else
                            res = try await remoteServer.write(
                                path: params.path,
                                content: params.content,
                                beforeRemoteWrite: beforeRemoteWrite
                            )
#endif
                            guard await self.hasConfirmedLeaseForSideEffect() else {
                                self.connection.client.respondToFileRequest(
                                    id: id,
                                    result: .failure(.init(
                                        code: -32003,
                                        message: "lease lost to another instance",
                                        data: nil
                                    ))
                                )
                                continue
                            }
                        } else {
                            res = try writer.write(path: params.path, content: params.content)
                        }
                        guard !Task.isCancelled, self.isConnectionCurrent() else {
                            self.connection.client.respondToFileRequest(
                                id: id,
                                result: .failure(.init(code: -32800, message: "cancelled", data: nil)))
                            continue
                        }
                        if editorHasUnsavedChanges {
                            self.appendAndPersistSystemNotice("Agent wrote to \(URL(fileURLWithPath: params.path).lastPathComponent) — you have unsaved changes in this file.")
                        }
                        // Persist the worktree-relative path so the
                        // "Open diff" button can pass it straight to
                        // `git.diff(file:)` (which keys by relative
                        // path). Storing the absolute path silently
                        // produced empty diffs.
                        let storedPath = self.relativeToWorktree(params.path) ?? params.path
                        self.appendAndPersistFileEdit(.init(path: storedPath, added: res.added, removed: res.removed, oldText: res.oldText, newText: res.newText))
                        // ACP `fs/write_text_file` is defined as
                        // returning `result: null`. Encoding an empty
                        // Swift struct produced `{}`, which spec-strict
                        // SDKs reject as a protocol error even though
                        // the write succeeded.
                        let body = Data("null".utf8)
                        self.connection.client.respondToFileRequest(id: id, result: .success(body))
                    } catch is CancellationError {
                        self.connection.client.respondToFileRequest(
                            id: id,
                            result: .failure(.init(code: -32800, message: "cancelled", data: nil)))
                    } catch ACPFileWriter.Error.outsideWorktree(let p) {
                        guard !Task.isCancelled, self.isConnectionCurrent() else { continue }
                        self.appendAndPersistSystemNotice("Blocked write outside worktree: \(p)")
                        self.connection.client.respondToFileRequest(
                            id: id,
                            result: .failure(.init(code: -32001, message: "path outside worktree", data: nil)))
                    } catch ACPRemoteFileServer.ServerError.outsideWorktree(let p) {
                        guard !Task.isCancelled, self.isConnectionCurrent() else { continue }
                        self.appendAndPersistSystemNotice("Blocked write outside worktree: \(p)")
                        self.connection.client.respondToFileRequest(
                            id: id,
                            result: .failure(.init(code: -32001, message: "path outside worktree", data: nil)))
                    } catch ACPRemoteFileServer.ServerError.leaseLost {
                        self.connection.client.respondToFileRequest(
                            id: id,
                            result: .failure(.init(code: -32003, message: "lease lost to another instance", data: nil)))
                    } catch {
                        self.connection.client.respondToFileRequest(
                            id: id,
                            result: .failure(.init(code: -32000, message: error.localizedDescription, data: nil)))
                    }
                }
            }
        }

        terminalsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await req in self.connection.client.terminalRequests {
                guard self.isConnectionCurrent() else { continue }
                await self.handleTerminalRequest(req)
            }
        }
    }

    /// Starts the `_auth/status_update` listener on its own, ahead of the
    /// rest of `start()`.
    ///
    /// `ACPSessionManager.performAttach` calls this as soon as the runner
    /// exists — before the fallible `session/new`/`session/load`/
    /// `session/resume` call — so the agent's fresh status lands regardless of
    /// how that call ends. Deferring it to `start()` meant a session-creation
    /// failure unrelated to auth (network drop, timeout) left the notification
    /// buffered in the client forever, so a restored signed-out banner stayed
    /// up even though the live adapter had already reported being signed in.
    ///
    /// Idempotent, because `start()` calls it too and `authStatusUpdates` has
    /// a single consumer: a second iteration would split the events between
    /// two loops rather than replace the first.
    func startAuthStatusListening() {
        guard authStatusTask == nil else { return }
        authStatusTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.connection.client.authStatusUpdates {
                guard self.isConnectionCurrent() else { continue }
                self.applyAuthStatus(
                    event.status,
                    acknowledging: event.durableConsumptionAcknowledgement
                )
            }
        }
    }

    /// Tears down a listener started by `startAuthStatusListening()` on an
    /// attach that never committed this runner. The task retains the runner
    /// while suspended on the stream, so an abandoned attach has to cancel it
    /// explicitly. `stop()` is the wrong tool here: it also kills terminals
    /// and marks subagents disconnected, side effects a runner that never
    /// started owns nothing of.
    ///
    /// Awaits the task rather than just requesting cancellation: `.cancel()`
    /// only sets a flag, so a `for await` iteration already past its
    /// suspension point (an event was yielded and the loop body is running
    /// `applyAuthStatus`, which synchronously enqueues the fenced
    /// persistence write) keeps running to completion regardless. A caller
    /// that flushes persistence right after `.cancel()` without waiting can
    /// observe no pending write yet and flush too early, letting that write
    /// land — or the status be dropped entirely by the loop exiting — after
    /// the flush already returned.
    func cancelAuthStatusListening() async {
        let task = authStatusTask
        authStatusTask = nil
        task?.cancel()
        await task?.value
    }

    /// Persists an `available_commands_update` list (slash commands and
    /// skills) so their pills and chips survive an app restart and appear in
    /// mirror sessions. Fenced like every other runner-owned mutation; only
    /// a non-empty list is written, so an agent that later retracts the list
    /// never erases the stored one — a replayed pill beats a guaranteed
    /// absence.
    private func persistPromptSuggestions(_ suggestions: [ACPPromptSuggestion]) {
        guard !suggestions.isEmpty else { return }
        guard holdsLeaseForWrite() else { return }
        let fence = leaseFenceProvider()
        let sessionId = sessionId
        enqueuePersistence { persistence in
            _ = try await persistence.setPromptSuggestions(
                sessionId: sessionId, suggestions: suggestions, fence: fence
            )
        }
    }

    /// Ack variant of `persistPromptSuggestions`: the broker's replay cursor
    /// only advances once the catalog write is durable, mirroring how
    /// `persistSessionRow` gates the config-options ack on its own write.
    /// A failure leaves the cursor where it is, so the broker replays the
    /// update (and its acknowledgement) on the next attach.
    ///
    /// An EMPTY catalog is intentionally not persisted (a retracted list
    /// never erases the stored one), but the update itself was delivered and
    /// applied to the live session — leaving it unacknowledged would starve
    /// every later durable acknowledgement (`ack(cursor:)` defers anything
    /// behind an unresolved cursor) and replay the same empty update on
    /// every reconnect. It acknowledges through
    /// `acknowledgeAfterQueuedPersistence`, whose empty write still
    /// re-validates the lease fence behind this cursor.
    private func persistPromptSuggestionsAndAcknowledge(
        _ suggestions: [ACPPromptSuggestion],
        acknowledging acknowledgement: ACPDurableConsumptionAcknowledgement?
    ) {
        guard let acknowledgement else {
            persistPromptSuggestions(suggestions)
            return
        }
        if suggestions.isEmpty {
            acknowledgeAfterQueuedPersistence(acknowledgement)
            return
        }
        guard holdsLeaseForWrite() else { return }
        let fence = leaseFenceProvider()
        let sessionId = sessionId
        enqueuePersistence({ persistence in
            try await persistence.setPromptSuggestionsAndReport(
                sessionId: sessionId, suggestions: suggestions, fence: fence
            )
        }, completion: { persisted in
            if persisted == true {
                acknowledgement()
            }
        })
    }

    /// Applies a `_auth/status_update` notification. Unlike a failed-prompt
    /// `authRequired`, the connection here is healthy — the agent is simply
    /// reporting it has no signed-in credentials yet — so this shows the
    /// existing sign-in banner without tearing the runner/connection down.
    /// A later update reporting a signed-in kind clears the banner again.
    private func applyAuthStatus(
        _ status: ACPAuthStatus,
        acknowledging acknowledgement: ACPDurableConsumptionAcknowledgement? = nil
    ) {
        guard isConnectionCurrent() else { return }
        session.authStatus = status
        if status.kind == .none {
            session.setupState = .needsAuth(methods: session.authMethods, reason: nil)
        } else if case .needsAuth = session.setupState {
            session.setupState = .ready
        }
        // Persisted so an app restart can restore it before any attach
        // happens: a broker-adopted reattach serves a cached `initialize`
        // and never re-emits this notification for that attach.
        //
        // Fenced like every other runner-owned mutation: during a
        // cross-window takeover this runner can still be draining a
        // buffered status after its lease was replaced. Without the fence,
        // that stale write could land after the new owner already
        // persisted a newer status and silently overwrite it.
        guard holdsLeaseForWrite() else { return }
        let fence = leaseFenceProvider()
        let sessionId = sessionId
        if let acknowledgement {
            // Hold the broker's replay cursor back — via `acknowledgement`,
            // called only once this write actually lands — until the
            // status is durable, so a crash between delivery and
            // persistence doesn't cause the next process's replay to skip
            // this notification and restore a stale or nil status.
            enqueuePersistence({ persistence in
                try await persistence.setAuthStatus(sessionId: sessionId, status: status, fence: fence)
            }, completion: { persisted in
                if persisted == true {
                    acknowledgement()
                }
            })
        } else {
            enqueuePersistence { persistence in
                _ = try await persistence.setAuthStatus(sessionId: sessionId, status: status, fence: fence)
            }
        }
    }

    /// Folds the decoded `_meta.permission` presentation and the outcome
    /// (auto-run, remembered decision, or user click — `evaluate` already
    /// resolved all three the same way) into the matching persisted tool
    /// call, so a later hydration of this transcript still shows the same
    /// title/reason/chosen-option context. Materializes the row from the
    /// permission request's own toolCall snapshot when it hasn't landed
    /// yet. A no-op only when there is nothing worth persisting at all.
    ///
    /// Gated on `holdsLeaseForWrite()`, matching `applyAuthStatus` and every
    /// other runner-owned mutation: `stop()` cancelling a parked
    /// `policy.evaluate` (via `userCancelled()`) resumes this same loop
    /// iteration, which keeps running past the cancellation to reach this
    /// call — without the guard, a detached/superseded runner could still
    /// mutate (and even materialize a new row into) the shared session
    /// transcript after losing write ownership during a takeover.
    private func persistPermissionDecision(params: ACPPermissionRequestParams, response: ACPPermissionResponse) async {
        guard holdsLeaseForWrite() else { return }
        // `session/update` and `session/request_permission` arrive on two
        // independent async streams (ACPStdioClient). A fast decision
        // (auto-run, or an early $/cancel_request) can reach here with no
        // suspension of its own, while an update already yielded into the
        // other stream hasn't been dequeued by updatesTask yet —
        // flushPendingIncomingUpdates() only drains what updatesTask has
        // already dequeued into its own buffer, so it can't see that
        // update either. Drain to the exact watermark already yielded
        // (yieldedUpdateCount/appliedUpdateCount, the same pair
        // deferCompletedOutputBoundaryUntilUpdatesDrain() uses) rather
        // than guessing an attempt count, so a materialized/merged tool
        // call row never jumps ahead of a preceding agent/thought message
        // regardless of how many updates are queued. Bounded only by
        // cancellation (stop() cancels updatesTask too, so nothing more
        // would ever apply past that point).
        let updateWatermark = connection.client.yieldedUpdateCount
        while appliedUpdateCount < updateWatermark, !Task.isCancelled {
            await Task.yield()
            flushPendingIncomingUpdates()
        }
        guard !Task.isCancelled else { return }
        // Re-check: holdsLeaseForWrite() above can no longer speak for
        // "now" after the suspensions just above — a cross-window takeover
        // could have seized the lease in the interim. persistIndices below
        // still gates the actual disk write, but mergePermissionDecision
        // itself mutates the shared in-memory transcript synchronously, so
        // that mutation needs its own fresh check.
        guard holdsLeaseForWrite() else { return }
        let chosenOption: ACPPermissionOption?
        let wasCancelled: Bool
        switch response.outcome {
        case .selected(let optionId):
            chosenOption = params.options.first { $0.optionId == optionId }
            wasCancelled = false
        case .cancelled:
            chosenOption = nil
            wasCancelled = true
        }
        // A permission request can name a registered child's own session,
        // not the root — its resulting row belongs in that child's own
        // transcript. See `ACPSession.mergePermissionDecision`.
        let subagentSessionId = session.subagentRun(params.sessionId) != nil ? params.sessionId : nil
        guard let index = session.mergePermissionDecision(
            toolCall: params.toolCall,
            presentation: ACPPermissionPresentation(metadata: params.metadata),
            chosenOption: chosenOption,
            mcpServerName: params.toolCall.mcpServerName,
            wasCancelled: wasCancelled,
            subagentSessionId: subagentSessionId
        ) else { return }
        if let subagentSessionId {
            // Not part of any OpenCode dual-write lifecycle batch — a
            // transient failure here must not withhold a LATER, unrelated
            // child update's own durable acknowledgement.
            persistSubagentIndices(
                [index], subagentSessionId: subagentSessionId, participatesInLifecycleBatch: false)
        } else {
            persistIndices([index], requiresLease: true)
        }
    }

    private func enqueueIncomingUpdate(_ update: ACPSessionUpdateParams) {
        guard isConnectionCurrent() else { return }
        let receivedWhileHoldingLease = holdsLeaseForWrite()
        // A child session's update never touches a parent row, so it must
        // not capture a compare-and-swap base for one (its tool-call ids
        // live in the child's own transcript).
        if receivedWhileHoldingLease, !isSubagentUpdate(update) {
            capturePersistedBasesForIncomingUpdate(update.update)
        }
        pendingIncomingUpdates.append(.init(
            params: update,
            receivedWhileHoldingLease: receivedWhileHoldingLease
        ))
        guard incomingUpdateFlushTask == nil else { return }
        incomingUpdateFlushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.incomingUpdateCoalesceNanos)
            guard !Task.isCancelled else { return }
            guard self.isConnectionCurrent() else { return }
            self.flushPendingIncomingUpdates()
        }
    }

    private func capturePersistedBasesForIncomingUpdate(_ update: ACPSessionUpdate) {
        for index in persistedCandidateIndices(for: update) {
            capturePersistedBaseIfNeeded(at: index)
        }
    }

    private func persistedCandidateIndices(for update: ACPSessionUpdate) -> Set<Int> {
        let messages = session.transcript.messages
        switch update {
        case .agentMessageChunk(let chunk):
            if let messageId = chunk.messageId,
               let index = session.transcript.messageIndex(messageId: messageId, kind: .agent) {
                return [index]
            }
            return messages.indices.reversed().first { index in
                if case .agent = messages[index] {
                    return true
                }
                return false
            }.map { [$0] } ?? []
        case .agentThoughtChunk(let chunk):
            if let messageId = chunk.messageId,
               let index = session.transcript.messageIndex(messageId: messageId, kind: .thought) {
                return [index]
            }
            return messages.indices.reversed().first { index in
                if case .thought = messages[index] {
                    return true
                }
                return false
            }.map { [$0] } ?? []
        case .toolCallUpdate(let update):
            return session.transcript.toolCallIndex(toolCallId: update.toolCallId).map { [$0] } ?? []
        case .compactionSummaryChunk(let chunk):
            return session.transcript.toolCallIndex(
                toolCallId: ACPSession.contextCompactionToolCallId(chunk.compactionId)
            ).map { [$0] } ?? []
        case .toolCall, .compactionUpdate,
             .userMessageChunk, .plan, .availableModelsUpdate,
             .currentModeUpdate, .currentModelUpdate, .sessionInfoUpdate,
             .sessionConfigOptionsUpdate, .availableCommandsUpdate,
             .usageUpdate, .notice, .subagentSpawned, .subagentStateUpdate, .asyncTask, .unknown:
            return []
        }
    }

    private func flushPendingIncomingUpdates(
        flushQueueWhenBoundaryReady: Bool = true,
        treatBufferedUpdatesAsPromptOwned: Bool = false
    ) {
        incomingUpdateFlushTask?.cancel()
        incomingUpdateFlushTask = nil
        guard isConnectionCurrent() else {
            pendingIncomingUpdates.removeAll()
            return
        }
        guard !steeringRowPersistencePending, !pendingIncomingUpdates.isEmpty else { return }
        let updates = pendingIncomingUpdates
        pendingIncomingUpdates.removeAll(keepingCapacity: true)
        for update in updates {
            applyIncomingUpdate(
                update.params,
                bufferedUpdateReceivedWhileHoldingLease: update.receivedWhileHoldingLease,
                flushQueueWhenBoundaryReady: flushQueueWhenBoundaryReady,
                treatBufferedUpdatesAsPromptOwned: treatBufferedUpdatesAsPromptOwned
            )
        }
    }

    private func applyIncomingUpdate(
        _ params: ACPSessionUpdateParams,
        bufferedUpdateReceivedWhileHoldingLease: Bool = true,
        flushQueueWhenBoundaryReady: Bool = true,
        treatBufferedUpdatesAsPromptOwned: Bool = false
    ) {
        if steeringRowPersistencePending {
            pendingIncomingUpdates.append(.init(params: params, receivedWhileHoldingLease: bufferedUpdateReceivedWhileHoldingLease))
            return
        }

        guard isConnectionCurrent() else { return }
        let durableConsumptionAcknowledgement = params.durableConsumptionAcknowledgement
        observedUpdateCount += 1
        appliedUpdateCount += 1
        if case .asyncTask(let update) = params.update {
            let root = session.remoteSessionId ?? sessionId
            if params.sessionId == root || session.subagentRun(params.sessionId) != nil {
                var dirty = session.applyBackgroundTask(update, ownerSessionId: params.sessionId)
                let identity = ACPBackgroundTask(ownerSessionId: params.sessionId,
                    asyncTaskId: update.asyncTaskId, name: update.asyncTaskId).id
                // An identical replay can match a mutation whose earlier write
                // failed. Save its current row before consuming the broker event.
                if let index = session.transcript.toolCallIndex(toolCallId: identity) { dirty.insert(index) }
                observedBackgroundTaskIds.insert(identity)
                let wakeId = session.backgroundTasks.first(where: { $0.id == identity })?.wakeId
                if dirty.isEmpty {
                    acknowledgeAfterQueuedPersistence(durableConsumptionAcknowledgement)
                } else {
                    flushStreamingPersist()
                    persistIndices(dirty, completion: { [weak self] persisted in
                        guard persisted else { return }
                        self?.enqueuePendingBackgroundWakes(persistedWakeIds: Set(wakeId.map { [$0] } ?? []))
                        durableConsumptionAcknowledgement?()
                    })
                }
            } else {
                acknowledgeAfterQueuedPersistence(durableConsumptionAcknowledgement)
            }
            if suppressingLoadReplay, let target = loadReplaySuppressionTarget,
               observedUpdateCount >= target {
                finishLoadReplaySuppression()
            }
            applyPendingCompletedOutputBoundaryIfReady(flushQueueWhenReady: flushQueueWhenBoundaryReady)
            return
        }
        if isSubagentUpdate(params) {
            applySubagentUpdate(
                params,
                durableConsumptionAcknowledgement: durableConsumptionAcknowledgement)
            // A child update still advances `appliedUpdateCount`, so it can
            // be the one that satisfies a boundary deferred until the
            // buffered updates drain. Skipping the check here would leave
            // the boundary pending — and the queue unflushed — whenever a
            // turn's last buffered notification is child-scoped.
            applyPendingCompletedOutputBoundaryIfReady(flushQueueWhenReady: flushQueueWhenBoundaryReady)
            return
        }
        let preAppliedSessionInfoDirty: Set<Int>?
        if case .sessionInfoUpdate(let info) = params.update {
            flushStreamingPersist()
            preAppliedSessionInfoDirty = session.apply(
                params.update,
                tracksRetryStatus: !suppressingLoadReplay,
                worktreeRoot: worktreePath
            )
            applySessionInfoTitle(info)
        } else {
            preAppliedSessionInfoDirty = nil
        }
        if suppressingLoadReplay {
            if let dirty = preAppliedSessionInfoDirty {
                persistIndices(
                    dirty,
                    completion: persistenceCompletion(acknowledging: durableConsumptionAcknowledgement)
                )
            } else {
                // `.toolCall`/`.toolCallUpdate` reconciliation (pre-existing)
                // and root-level subagent lifecycle reconciliation both
                // return dirty parent-row indices now — persist them and
                // acknowledge only after that succeeds, exactly like the
                // nested (child-addressed) lifecycle branch below already
                // does. Discarding the result and acking unconditionally
                // let a broker-backed reattach advance its cursor without
                // ever storing the row replay just recovered.
                let dirty = session.applySuppressedReplaySideEffects(params.update)
                if dirty.isEmpty {
                    // This specific update produced nothing to persist, but
                    // an EARLIER one in the same replayed batch (the
                    // recovered spawn, typically, for an OpenCode status
                    // frame) can still have a write queued and not yet
                    // complete. Acking immediately here — as a plain,
                    // unconditional call — could advance the broker cursor
                    // before that write lands, or after it fails, either of
                    // which loses the row replay just recovered. Route
                    // through the same queued + fence-revalidating barrier
                    // the nested (child-addressed) branch already uses.
                    acknowledgeAfterQueuedPersistence(durableConsumptionAcknowledgement)
                } else {
                    // This call site is shared by ordinary `.toolCall`/
                    // `.toolCallUpdate` reconciliation and root-level
                    // subagent lifecycle reconciliation — only the latter
                    // is genuinely part of the OpenCode dual-write batch.
                    let isSubagentLifecycleUpdate: Bool
                    switch params.update {
                    case .subagentSpawned, .subagentStateUpdate: isSubagentLifecycleUpdate = true
                    default: isSubagentLifecycleUpdate = false
                    }
                    persistIndices(
                        dirty,
                        participatesInLifecycleBatch: isSubagentLifecycleUpdate,
                        completion: persistenceCompletion(acknowledging: durableConsumptionAcknowledgement)
                    )
                }
            }
            if let target = loadReplaySuppressionTarget,
               observedUpdateCount >= target {
                finishLoadReplaySuppression()
            }
            return
        }
        if let dirty = preAppliedSessionInfoDirty {
            persistIndices(
                dirty,
                completion: persistenceCompletion(acknowledging: durableConsumptionAcknowledgement)
            )
        } else {
            let isPromptCompletionDrainUpdate = pendingCompletedOutputBoundary
                .map { appliedUpdateCount <= $0.updateCount } ?? false
            let isPromptOwnedBufferedUpdate = bufferedUpdateReceivedWhileHoldingLease
                && (activePromptID != nil || isPromptCompletionDrainUpdate || treatBufferedUpdatesAsPromptOwned)
            let shouldBatchStreamingPersist = shouldBatchStreamingPersist(
                for: params.update,
                isPromptOwnedBufferedUpdate: isPromptOwnedBufferedUpdate,
                hasUnderLeaseBufferedStreamingWrites: !pendingStreamingPersistIndices.isEmpty
            )
            if shouldBatchStreamingPersist {
                // Detect a cross-process takeover BEFORE this chunk mutates
                // the transcript. If the lease has moved, freeze the buffered
                // rows' pre-chunk state so stand-down persists that snapshot,
                // not chunks that belong to the new session owner. Buffered
                // chunks received while the lease was still held are different:
                // they remain owned by this stream even if the coalesced apply
                // happens after activePromptID cleared.
                let holdsLease = holdsLeaseForWrite()
                if !isPromptOwnedBufferedUpdate, !streamingLeaseLost, !holdsLease {
                    freezeStreamingPersistSnapshots()
                    streamingLeaseLost = true
                }
                let dirty = session.apply(params.update, worktreeRoot: worktreePath)
                if !streamingLeaseLost {
                    scheduleStreamingPersist(
                        dirty,
                        mayCapturePersistedBases: holdsLease,
                        durableConsumptionAcknowledgement: durableConsumptionAcknowledgement
                    )
                }
            } else {
                let dirty = session.apply(params.update, worktreeRoot: worktreePath)
                flushStreamingPersist()
                var suggestionsHandled: Bool = false
                if case .availableCommandsUpdate(let suggestions) = params.update {
                    if durableConsumptionAcknowledgement != nil {
                        // The catalog write must land before the broker's replay
                        // cursor advances, or a crash/failed write in between
                        // loses the pills on the next hydration. Route the
                        // acknowledgement through the suggestion write itself —
                        // same ordering `persistSessionRow` gives config options.
                        persistPromptSuggestionsAndAcknowledge(
                            suggestions,
                            acknowledging: durableConsumptionAcknowledgement
                        )
                        suggestionsHandled = true
                    } else {
                        persistPromptSuggestions(suggestions)
                    }
                }
                // A suggestions update with a durable ack already routed the
                // acknowledgement through its own catalog write; skip the
                // paths below, none of which carry anything to persist for
                // this kind (`dirty` is always empty) and all of which would
                // otherwise ack immediately without waiting for that write.
                // The tail below (models observation, boundary check) still
                // runs either way.
                let isSubagentLifecycleUpdate: Bool
                switch params.update {
                case .subagentSpawned, .subagentStateUpdate: isSubagentLifecycleUpdate = true
                default: isSubagentLifecycleUpdate = false
                }
                if suggestionsHandled {
                    // fall through to the tail only
                } else if case .sessionConfigOptionsUpdate = params.update {
                    persistIndices(dirty)
                    persistSessionRow { persisted in
                        if persisted {
                            durableConsumptionAcknowledgement?()
                        }
                    }
                } else if isSubagentLifecycleUpdate, dirty.isEmpty {
                    // A ROOT-addressed subagent lifecycle update — the
                    // shape both OpenCode-normalized updates take — can be
                    // the trailing half of a batch sharing one wire frame's
                    // ack with an earlier update whose real write (the
                    // synthetic spawn, typically) is still queued.
                    // `persistIndices`' empty-indices fast path below acks
                    // synchronously without waiting for that write or
                    // re-checking the fence; this barrier does both.
                    acknowledgeAfterQueuedPersistence(durableConsumptionAcknowledgement)
                } else {
                    // This IS genuinely part of the OpenCode dual-write
                    // lifecycle batch when the update is spawn/state — every
                    // other kind (plan, toolCall, etc.) is ordinary content
                    // unrelated to any batch and must not couple with one.
                    persistIndices(
                        dirty,
                        participatesInLifecycleBatch: isSubagentLifecycleUpdate,
                        completion: persistenceCompletion(acknowledging: durableConsumptionAcknowledgement)
                    )
                }
            }
        }
        switch params.update {
        case .availableModelsUpdate, .sessionConfigOptionsUpdate:
            onChipsObserved?(session.agentId, session.chipState)
        case .sessionInfoUpdate(let info):
            observeSteeringThreadStatus(info)
        default:
            break
        }
        applyPendingCompletedOutputBoundaryIfReady(flushQueueWhenReady: flushQueueWhenBoundaryReady)
    }

    /// Whether an incoming update belongs to a native subagent rather than
    /// to this session.
    ///
    /// An ALLOWLIST on purpose: only a session id Alas has already seen
    /// announced by `subagent_spawned` counts as a child. The runner has
    /// never filtered on `sessionId`, and agents that ignore the subagent
    /// capability must keep behaving exactly as before, so anything
    /// unrecognized still flows into the parent transcript.
    private func isSubagentUpdate(_ params: ACPSessionUpdateParams) -> Bool {
        session.subagentRun(params.sessionId) != nil
    }

    /// Applies a child-scoped update to its own transcript. Child rows are
    /// deliberately kept out of the parent's streaming-persist machinery:
    /// they have their own table, their own row ids, and they can never be
    /// the row a prompt's completion boundary is waiting on.
    private func applySubagentUpdate(
        _ params: ACPSessionUpdateParams,
        durableConsumptionAcknowledgement: ACPDurableConsumptionAcknowledgement?
    ) {
        defer {
            if suppressingLoadReplay,
               let target = loadReplaySuppressionTarget,
               observedUpdateCount >= target {
                finishLoadReplaySuppression()
            }
        }
        switch params.update {
        case .subagentSpawned, .subagentStateUpdate:
            // A nested collaborator is announced on ITS parent's session,
            // which is a child of ours. Register it flat on the root rather
            // than dropping it: otherwise its own session id never enters
            // the allowlist and its output would be applied to the root
            // transcript as ordinary parent output. This is the same shape
            // the OpenCode variant already produces, where every
            // descendant is reported against the root regardless of depth.
            //
            // Lifecycle updates are reconciled even while replay is
            // suppressed — they are idempotent and keyed by child session
            // id, and the replay may carry the only copy of a terminal
            // state the previous process never committed. Root-level
            // spawns already take that path via
            // `applySuppressedReplaySideEffects`; a nested one must not
            // behave differently just because it is addressed one level
            // down.
            let dirty = suppressingLoadReplay
                ? session.applySuppressedReplaySideEffects(params.update)
                : session.apply(params.update)
            if dirty.isEmpty {
                acknowledgeAfterQueuedPersistence(durableConsumptionAcknowledgement)
            } else {
                // This IS genuinely part of the OpenCode dual-write
                // lifecycle batch — a nested spawn/state update sharing an
                // ack with a sibling write in the same normalized pair.
                persistIndices(
                    dirty,
                    participatesInLifecycleBatch: true,
                    completion: persistenceCompletion(acknowledging: durableConsumptionAcknowledgement))
            }
        default:
            // The child transcript was restored from SQLite at hydration,
            // so a `session/load` replay of its content is USUALLY a pure
            // duplicate — but persistence is asynchronous, and a chunk the
            // agent already sent (and therefore resends during replay) can
            // be missing from SQLite if the app quit before its queued
            // write landed. `applySubagentReplayedUpdate` resets a row on
            // its first replayed touch and rebuilds it from what replay
            // actually sends, so an already-complete row is unaffected and
            // a partially- or fully-lost one is recovered.
            let dirty = suppressingLoadReplay
                ? session.applySubagentReplayedUpdate(
                    params.update, subagentSessionId: params.sessionId)
                : session.applySubagentUpdate(
                    params.update, subagentSessionId: params.sessionId)
            if dirty.isEmpty {
                acknowledgeAfterQueuedPersistence(durableConsumptionAcknowledgement)
            } else {
                persistSubagentIndices(
                    dirty,
                    subagentSessionId: params.sessionId,
                    completion: persistenceCompletion(acknowledging: durableConsumptionAcknowledgement))
            }
        }
    }

    /// Acknowledges a durable subagent lifecycle update that wrote nothing
    /// itself, but only once everything already queued has been written
    /// AND the writer lease still checks out at that point.
    ///
    /// Both call sites are batch tails: a root-addressed spawn/state update
    /// (OpenCode's `ACPOpenCodeChildUpdate.normalized` puts the ack on the
    /// LAST of several updates sharing one wire frame) and a nested
    /// lifecycle update reconciled during suppressed replay. In both cases
    /// an earlier update's real write (the synthetic spawn row, typically)
    /// can still be queued. Persistence operations are serialized through
    /// `enqueuePersistence`, so waiting behind the queue orders this
    /// correctly against that write — but ordering alone doesn't prove the
    /// write succeeded: if a takeover invalidated the fence in that same
    /// window, the earlier write stored nothing, and acknowledging anyway
    /// would tell the broker we consumed a row that was never persisted.
    ///
    /// So this re-validates the SAME fence with an empty write of its own,
    /// exactly like `persistSubagentIndices`' real writes do — an empty
    /// array is a no-op for `upsertSubagentMessages`, but `withLeaseFence`
    /// still checks the fence against the live lease row before running it,
    /// so the round trip is a genuine, current answer rather than the
    /// cached `canWrite()` snapshot this method also uses as a fast bail.
    ///
    /// That alone still isn't the whole story: the fence only proves the
    /// LEASE is fine, not that the preceding write itself succeeded — a
    /// transient failure unrelated to the lease (a SQLite `step` error,
    /// say) would pass this barrier's own fence check while the earlier
    /// write stored nothing. So the completion also folds in
    /// `lastQueuedPersistenceSucceeded`, which every real write updates
    /// unconditionally regardless of whether IT carried a durable ack.
    private func acknowledgeAfterQueuedPersistence(
        _ acknowledgement: ACPDurableConsumptionAcknowledgement?
    ) {
        guard let acknowledgement else { return }
        guard holdsLeaseForWrite() else { return }
        let fence = leaseFenceProvider()
        enqueuePersistence({ persistence in
            try await persistence.persistSubagentMessages([], fence: fence)
        }, completion: { [weak self] persisted in
            guard let self else { return }
            // Combine with the PRECEDING queued write's outcome (read
            // before this line overwrites it) rather than just this
            // barrier's own fence check: a batch's real write can fail for
            // a reason unrelated to the lease, which this barrier's own
            // empty write — valid fence, nothing to actually store — would
            // not surface on its own.
            let succeeded = persisted == true && self.lastQueuedPersistenceSucceeded
            // This call always carries a real acknowledgement (the guard
            // above returns otherwise), so it is ALWAYS the acknowledgement
            // boundary of its batch — reset unconditionally, regardless of
            // outcome, so a failure here can't block a later, unrelated one.
            self.lastQueuedPersistenceSucceeded = true
            if succeeded {
                acknowledgement()
            }
        })
    }

    /// Persists the named rows of a child transcript.
    @discardableResult
    func persistSubagentIndices(
        _ indices: Set<Int>,
        subagentSessionId: String,
        participatesInLifecycleBatch: Bool = true,
        completion: ((Bool) -> Void)? = nil
    ) -> Bool {
        guard holdsLeaseForWrite() else { return false }
        guard let run = session.subagentRun(subagentSessionId), !indices.isEmpty else {
            completion?(true)
            return true
        }
        let messages = run.messages
        var rows: [ACPStoredSubagentMessage] = []
        for index in indices.sorted() {
            guard index >= 0, index < messages.count else { continue }
            let message = messages[index]
            guard let payload = try? ACPMessageCodec.encode(message) else { continue }
            // The row's SQL seq, NOT its array index: persistence can leave
            // gaps, and using the index here would let a row recovered by
            // replay — appended at whatever position it lands in the
            // compacted in-memory array — overwrite an unrelated row still
            // holding that index's old seq. See `ACPSubagentRun.restore`.
            let seq = run.seq(at: index)
            rows.append(ACPStoredSubagentMessage(
                id: ACPStoredSubagentMessage.rowId(
                    sessionId: sessionId,
                    subagentSessionId: subagentSessionId,
                    seq: seq),
                sessionId: sessionId,
                subagentSessionId: subagentSessionId,
                kind: message.kind,
                seq: seq,
                payload: payload,
                createdAt: Int64(run.createdAt(at: index).timeIntervalSince1970)))
        }
        guard !rows.isEmpty else {
            completion?(true)
            return true
        }
        let fence = leaseFenceProvider()
        let subagentRows = rows
        enqueuePersistence({ persistence in
            // Return the fence's verdict rather than discarding it: a write
            // rejected because ownership moved mid-flight stores nothing and
            // must NOT acknowledge the durable update, or the child's output
            // is dropped instead of being replayed to the new writer.
            try await persistence.persistSubagentMessages(subagentRows, fence: fence)
        }, completion: { [weak self] persisted in
            guard let self else { return }
            // Mirrors learn about new rows through this notifier — gated on
            // THIS write's own outcome alone, not the batch-combined
            // `succeeded` below. A child that streams without touching its
            // synthetic parent row would otherwise stay invisible to
            // another instance until the next parent-row write (its
            // terminal state, at the earliest).
            //
            // Deliberately NOT `onMessageActivity`: that moves the recents
            // ordering by bumping `updatedAt` in memory, while
            // `upsertSubagentMessages` — unlike `upsertMessages` — does not
            // bump it in SQLite, so the two would disagree. The spawn and
            // the terminal state both write parent rows, so a subagent run
            // still registers as activity at both ends.
            if persisted == true {
                self.onPersist?()
            }
            guard participatesInLifecycleBatch else {
                completion?(persisted == true)
                return
            }
            // Combine with the PRECEDING queued write's outcome (read
            // before this overwrites it) rather than record only this
            // write's own result: an OpenCode batch's spawn write can fail
            // for a reason this write's own success says nothing about, and
            // this write's own completion — unlike the barrier's — is what
            // acknowledges the batch's shared cursor when it carries the ack.
            let succeeded = persisted == true && self.lastQueuedPersistenceSucceeded
            // `completion` (the caller's, not this closure) is non-nil
            // exactly when THIS write carries the batch's real acknowledgement
            // — i.e. this is the batch's boundary — so only reset there.
            // A nil `completion` means more of the same batch is still
            // coming (the spawn half of an OpenCode pair, typically), and
            // this write's outcome must propagate forward to it rather
            // than being cleared here.
            self.lastQueuedPersistenceSucceeded = completion == nil ? succeeded : true
            completion?(succeeded)
        })
        return true
    }

    private func persistenceCompletion(
        acknowledging acknowledgement: ACPDurableConsumptionAcknowledgement?
    ) -> ((Bool) -> Void)? {
        guard let acknowledgement else { return nil }
        return { succeeded in
            if succeeded {
                acknowledgement()
            }
        }
    }

    #if DEBUG
    var pendingIncomingUpdateCountForTesting: Int { pendingIncomingUpdates.count }

    func applyIncomingUpdateForTesting(_ params: ACPSessionUpdateParams) {
        applyIncomingUpdate(params)
    }
    #endif

    func suppressLoadReplay(throughYieldedUpdateCount target: Int) {
        guard target > observedUpdateCount else { return }
        if !suppressingLoadReplay {
            suppressingLoadReplay = true
            session.beginSuppressedReplaySideEffects()
        }
        loadReplaySuppressionTarget = max(loadReplaySuppressionTarget ?? 0, target)
    }

    func finishSuppressingLoadReplay(throughYieldedUpdateCount target: Int) {
        guard suppressingLoadReplay else { return }
        loadReplaySuppressionTarget = target
        flushPendingIncomingUpdates()
        if observedUpdateCount >= target {
            finishLoadReplaySuppression()
        }
    }

    private func finishLoadReplaySuppression() {
        suppressingLoadReplay = false
        session.endSuppressedReplaySideEffects()
        // Keep late replay behind the boundary unless this runner owns a
        // new prompt. Live steering bindings resolve per chunk independently.
        if activePromptID == nil {
            session.allowsStreamingBoundaryCrossing = false
        }
    }

    func stop() {
        stopped = true
        session.pendingQueuePersistenceCount -= deferredQueueAcknowledgements.count
        deferredQueueAcknowledgements.removeAll()
        invalidateNativeSteering()
        turnPublicationGeneration += 1
        discardPendingSuccessfulTurn("stop")
        localTitleTask?.cancel()
        localTitleTask = nil
        flushPendingIncomingUpdates(
            flushQueueWhenBoundaryReady: false,
            treatBufferedUpdatesAsPromptOwned: true
        )
        session.clearRetryStatus()
        flushStreamingPersistOnStop()
        // Teardown always shuts this runner's connection down (see
        // `tearDownSession`: the `detach()` path has no runner), so every
        // child dies with it. Marking them here — after the streaming
        // flush, so it cannot cancel that write's debounce — is what stops
        // a reopened session from showing a subagent spinning forever.
        // `persistIndices` requires the writer lease, so an instance that
        // lost it in a takeover records nothing.
        persistIndices(session.markSubagentsDisconnected())
        scheduledQueueWakeTask?.cancel()
        scheduledQueueWakeTask = nil
        incomingUpdateFlushTask?.cancel()
        incomingUpdateFlushTask = nil
        updatesTask?.cancel()
        permissionsTask?.cancel()
        cancelRequestsTask?.cancel()
        filesTask?.cancel()
        terminalsTask?.cancel()
        authStatusTask?.cancel()
        // A detach/takeover can land while a permission prompt is parked.
        // userCancel() already resolves it; stop() must too, or the policy's
        // continuation is stranded when we tear the connection down.
        policy.userCancelled()
        // Kill agent-spawned subprocesses now. ACPSessionManager keeps
        // the ACPSession cached after detach, so the session's deinit-
        // time killAll() won't fire on tab close — without this an
        // active `npm test`/`sleep`/server outlives the agent.
        session.terminalHost.killAll()
        onPersist?()
    }

    private func handleTerminalRequest(_ req: ACPTerminalRequest) async {
        let host = self.session.terminalHost
        switch req {
        case .create(let id, let p):
            // Same as file writes: never rely on a permission request alone.
            if session.readOnlyRestricted {
                session.recordReadOnlyBlock("run \(p.command)")
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32002, message: "read-only side session", data: nil)))
                break
            }
            // Gate terminal creation on the lease: a runner that has lost
            // the writer lease must not start new terminal side effects in
            // the brief window before stand-down tears it down. This is
            // defense-in-depth alongside the heartbeat/stand-down path
            // (which calls stop() → terminalHost.killAll() within ~100ms
            // of a takeover ping). Matches the existing file-write gate.
            guard await hasConfirmedLeaseForSideEffect() else {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32003, message: "lease lost to another instance", data: nil)))
                break
            }
            guard !Task.isCancelled, isConnectionCurrent() else {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32800, message: "cancelled", data: nil)))
                break
            }
            do {
                let res = try host.create(p)
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .success(try JSONEncoder().encode(res)))
            } catch ACPTerminalHostError.tooManyTerminals {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32000, message: "too many terminals", data: nil)))
            } catch ACPTerminalHostError.spawnFailed(let msg) {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32000, message: msg, data: nil)))
            } catch {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32000, message: error.localizedDescription, data: nil)))
            }
        case .output(let id, let p):
            do {
                let res = try host.output(p)
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .success(try JSONEncoder().encode(res)))
            } catch ACPTerminalHostError.notFound {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32602, message: "terminal not found", data: nil)))
            } catch {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32000, message: error.localizedDescription, data: nil)))
            }
        case .waitForExit(let id, let p):
            // Capture only the host + client so a long-running waitForExit
            // doesn't pin the runner (and its session) in memory if the
            // session is torn down before the agent's underlying process
            // exits. ACPTerminalHost has no back-reference to ACPSession,
            // so this lets the session deinit (and its killAll()) run
            // while the wait task is still parked on the host.
            let client = self.connection.client
            Task { @MainActor in
                do {
                    let res = try await host.waitForExit(p)
                    client.respondToTerminalRequest(
                        id: id, result: .success(try JSONEncoder().encode(res)))
                } catch ACPTerminalHostError.notFound {
                    client.respondToTerminalRequest(
                        id: id, result: .failure(.init(code: -32602, message: "terminal not found", data: nil)))
                } catch {
                    client.respondToTerminalRequest(
                        id: id, result: .failure(.init(code: -32000, message: error.localizedDescription, data: nil)))
                }
            }
        case .kill(let id, let p):
            // Gate terminal kill on the lease: a former writer that lost
            // the session lease must not mutate terminals for a session
            // another instance now owns. Note: runner.stop() calls
            // terminalHost.killAll() directly (NOT through this handler),
            // so teardown is unaffected by this gate.
            guard await hasConfirmedLeaseForSideEffect() else {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32003, message: "lease lost to another instance", data: nil)))
                break
            }
            guard !Task.isCancelled, isConnectionCurrent() else {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32800, message: "cancelled", data: nil)))
                break
            }
            do {
                try host.kill(p)
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .success(Data("null".utf8)))
            } catch ACPTerminalHostError.notFound {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32602, message: "terminal not found", data: nil)))
            } catch {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32000, message: error.localizedDescription, data: nil)))
            }
        case .release(let id, let p):
            // Gate terminal release on the lease: a former writer that lost
            // the session lease must not mutate terminals for a session
            // another instance now owns. Note: runner.stop() calls
            // terminalHost.killAll() directly (NOT through this handler),
            // so teardown is unaffected by this gate.
            guard await hasConfirmedLeaseForSideEffect() else {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32003, message: "lease lost to another instance", data: nil)))
                break
            }
            guard !Task.isCancelled, isConnectionCurrent() else {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32800, message: "cancelled", data: nil)))
                break
            }
            do {
                try host.release(p)
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .success(Data("null".utf8)))
            } catch ACPTerminalHostError.notFound {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32602, message: "terminal not found", data: nil)))
            } catch {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32000, message: error.localizedDescription, data: nil)))
            }
        }
    }

    /// Cancel ownership of any in-flight prompt RPC. The unstructured
    /// `sendNow` task survives `stop()` (it isn't a child task); calling
    /// this marks its `activePromptID` as cancelled so when the RPC
    /// eventually fails (because `connection.shutdown()` killed it) the
    /// catch path treats it as a deliberate cancel — skipping
    /// `setQueueHeadError`. Without this, detach during a queued flush
    /// would persist a `lastError` on the queue head, and the next
    /// attach's `flushQueueIfIdle` would skip it (guard requires
    /// `lastError == nil`), forcing the user to click Retry.
    func invalidateActivePrompt() {
        invalidateNativeSteering()
        turnPublicationGeneration += 1
        discardPendingSuccessfulTurn("invalidateActivePrompt")
        if let promptID = activePromptID {
            cancelledPromptIDs.insert(promptID)
            activePromptID = nil
            activePromptStartedAt = nil
            activePromptDelegatedSource = nil
            activePromptTranscriptFloor = nil
        }
    }

    /// Snapshot the finished turn, record whether it failed, and hand it to
    /// `onTurnCompleted`. Must be called on the main actor inside the
    /// `isActivePrompt` branch so a superseded prompt never reports.
    /// `usageAwaitsResult`: the prompt's result has not arrived yet (a user cancel), so a sent prompt's usage waits
    /// for it, which carries its tokens, for at most `cancelledUsageWait`; `onTurnCompleted` does not.
    private func emitTurnCompleted(
        _ result: ACPTurnCompletion.Result, promptID: Int, quota: ACPPromptQuota? = nil, usageAwaitsResult: Bool = false
    ) {
        // Whatever ended, no directly sent turn is left running.
        setDirectTurnInFlight(false)
        if case .failed(let message) = result {
            session.turnFailure = message
        } else {
            session.turnFailure = nil
        }
        guard let startedAt = activePromptStartedAt else {
            // A recovery prompt is no turn, but a stopped one's usage still waits for its result only so long.
            if usageAwaitsResult { reportUsageWithoutResult(promptID) }
            return
        }
        // Only consider agent messages this turn actually produced: scanning
        // the whole transcript would quote an EARLIER turn's text whenever
        // this turn's final `agentMessageChunk` is still sitting in the
        // incoming-update coalescing buffer, which is strictly worse than
        // saying nothing (the wake copy has a no-text path for exactly this).
        // `activePromptTranscriptFloor` is the message count captured when
        // this turn's prompt was recorded, so anything at or after it belongs
        // to this turn.
        //
        // This deliberately does NOT wait for the buffer to drain, so a turn
        // whose tail chunk lands late still reports no text rather than
        // partial text. Draining here was tried and reverted: by this point
        // `activePromptID` is already cleared, and forcing the flush collides
        // with the queued-successor dispatch this same completion is in the
        // middle of, deadlocking
        // `userCancelDoesNotCancelQueuedSuccessorStartedByPendingBoundaryFlush`.
        // Guaranteeing the final text needs the completion deferred into
        // `applyPendingCompletedOutputBoundaryIfReady`, the way
        // `NextPromptCompletedTurn` is — tracked as follow-up.
        let lastAgentText = currentTurnLastAgentText()
        let completion = ACPTurnCompletion(
            sessionId: sessionId,
            startedAt: startedAt,
            result: result,
            delegatedSource: activePromptDelegatedSource,
            lastAgentText: lastAgentText,
            quota: quota,
            cost: turnCost(streamStart: activePromptStreamStart),
            sentAt: unreportedPrompts[promptID]?.sentAt,
            endedAt: Self.now(),
            model: unreportedPrompts[promptID]?.model
        )
        activePromptStartedAt = nil
        activePromptDelegatedSource = nil
        activePromptTranscriptFloor = nil
        onTurnCompleted?(completion)
        // A prompt stopped or failed before it reached the agent is no turn: there is no usage to record.
        guard unreportedPrompts[promptID] != nil else { return }
        guard usageAwaitsResult else {
            unreportedPrompts[promptID] = nil
            reportUsageInOrder(promptID, completion)
            return
        }
        reportUsageWithoutResult(promptID)
    }

    /// When a prompt goes out, in epoch milliseconds, later than any before it: usage history orders turns by it, so
    /// two prompts sent within one millisecond still get their order.
    private func nextSentAt() -> Int64 {
        lastSentAt = max(Self.now(), lastSentAt + 1)
        return lastSentAt
    }

    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// Reports a prompt's usage once every prompt sent before it has reported, and with it any later ones it held.
    private func reportUsageInOrder(_ promptID: Int, _ completion: ACPTurnCompletion) {
        heldUsage[promptID] = completion
        reportHeldUsage()
    }

    private func reportHeldUsage() {
        let waitingFor = unreportedPrompts.keys.min() ?? .max
        for promptID in heldUsage.keys.sorted() where promptID < waitingFor {
            if let completion = heldUsage.removeValue(forKey: promptID) { onTurnUsage?(completion) }
        }
    }

    /// The connection is being replaced, and with it this runner: the results its prompts still wait for will not
    /// come. Returns every turn not reported yet, in the order sent; one without its result is a cancelled turn
    /// without tokens. The caller records them, since this runner's reports no longer count once it is replaced.
    /// A prompt that never crossed the transport handoff is no turn: the agent never got it.
    func takeUnreportedUsage() -> [ACPTurnCompletion] {
        for promptID in unreportedPrompts.keys {
            if promptHandoffs.contains(promptID) {
                heldUsage[promptID] = supersededTurnUsage(promptID, quota: nil, result: .cancelled)
            } else {
                unreportedPrompts[promptID] = nil
            }
        }
        defer { heldUsage = [:] }
        return heldUsage.sorted { $0.key < $1.key }.map(\.value)
    }

    /// A turn's cost is the newest entry before the next prompt went out, so of the entries between two sends only
    /// the newest is ever read: the rest go, which keeps the log as short as the sends tracked.
    private func compactCostLog() {
        let sends = sentStreamStarts.values
        costLog = costLog.indices.filter { i in
            i == costLog.count - 1 || sends.contains { costLog[i].index <= $0 && $0 < costLog[i + 1].index }
        }.map { costLog[$0] }
    }

    private func noteSent(_ promptID: Int, streamStart: Int) {
        sentStreamStarts[promptID] = streamStart
        // ponytail: only the newest bound anything, the few prompts still waiting being older than them.
        if sentStreamStarts.count > 16, let oldest = sentStreamStarts.keys.min() { sentStreamStarts[oldest] = nil }
        // Only prompts not reported yet are ever asked about.
        promptHandoffs.forget(below: unreportedPrompts.keys.min() ?? promptID)
    }

    /// Only an error the agent answered with shows it got the prompt. Any other failure is a prompt that never left
    /// (a closed transport) or a turn lost with the connection, and is not recorded.
    private func forgetUsageUnlessAgentAnswered(_ promptID: Int, _ error: any Error) {
        if case ACPClientError.jsonrpc = error { return }
        unreportedPrompts[promptID] = nil
        reportHeldUsage()
    }

    /// Reported once: by the result when it arrives (see `reportSupersededTurnUsage`), or after
    /// `cancelledUsageWait` without tokens.
    private func reportUsageWithoutResult(_ promptID: Int) {
        let sleep = usageWaitSleep
        Task { @MainActor [weak self] in
            await sleep(Self.cancelledUsageWait)
            self?.reportSupersededTurnUsage(promptID, quota: nil)
        }
    }

    /// A prompt a steer superseded, or the user stopped, got its result: its usage is reported as a cancelled turn,
    /// with its own tokens and the cost sent before the next prompt started. A steered one is not a turn completion:
    /// `onTurnCompleted` never hears of it.
    private func reportSupersededTurnUsage(
        _ promptID: Int, quota: ACPPromptQuota?, result: ACPTurnCompletion.Result = .cancelled
    ) {
        guard let completion = supersededTurnUsage(promptID, quota: quota, result: result) else { return }
        reportUsageInOrder(promptID, completion)
    }

    private func supersededTurnUsage(
        _ promptID: Int, quota: ACPPromptQuota?, result: ACPTurnCompletion.Result
    ) -> ACPTurnCompletion? {
        guard let prompt = unreportedPrompts.removeValue(forKey: promptID) else { return nil }
        return ACPTurnCompletion(
            sessionId: sessionId, startedAt: prompt.startedAt, result: result, delegatedSource: nil, lastAgentText: nil,
            quota: quota,
            // Capped where the first later prompt was sent; one still preparing has not started its usage.
            cost: turnCost(
                streamStart: prompt.streamStart, end: sentStreamStarts.filter { $0.key > promptID }.map(\.value).min()),
            sentAt: prompt.sentAt, endedAt: Self.now(), model: prompt.model, recovery: prompt.recovery)
    }

    /// The active turn's cost: the newest cost-bearing `usage_update` sent on the stream after the prompt started
    /// and before its result, applied or still buffered alike. The last may not be off the stream yet, so it is read
    /// again once it is. Only reads; never flushes the coalescing buffer (see above).
    /// `end` caps the stream position, for a turn whose successor already started.
    private func turnCost(streamStart start: Int, end: Int? = nil) -> ACPTurnCost {
        let watermark = min(connection.client.yieldedUpdateCount, end ?? .max)
        let logged: @MainActor (ACPSessionRunner?) -> ACPUsageInfo.Cost? = { runner in
            runner?.costLog.last { $0.index > start && $0.index <= watermark }?.cost
        }
        let known = logged(self)
        guard dequeuedUpdateCount < watermark else { return ACPTurnCost(known: known) }
        return ACPTurnCost(known: known, later: .init(
            settled: { [weak self] in (self?.dequeuedUpdateCount ?? 0) >= watermark },
            live: { [weak self] in self.map { $0.updatesTask?.isCancelled == false && $0.isConnectionCurrent() } ?? false },
            sentBeforeResult: { [weak self] in logged(self) }))
    }

    /// Tail of the last agent message this turn produced, or nil. Only rows at
    /// or after `activePromptTranscriptFloor` belong to the turn.
    private func currentTurnLastAgentText() -> String? {
        let floor = min(activePromptTranscriptFloor ?? 0, session.transcript.messages.count)
        return session.transcript.messages[floor...].reversed().lazy
            .compactMap { message -> String? in
                guard case .agent(_, _, let text) = message else { return nil }
                let tail = ACPDelegatedOutcomeText.tail(text.value, limit: ACPTurnCompletion.lastAgentTextLimit)
                return tail.isEmpty ? nil : tail
            }
            .first
    }

    /// Agent text still in the incoming-update coalescing buffer, not yet in
    /// the transcript. Read-only on purpose: draining the buffer at turn end
    /// collides with queued-successor dispatch (see `emitTurnCompleted`).
    private func bufferedAgentText() -> String? {
        let text = pendingIncomingUpdates.compactMap { pending -> String? in
            guard !isSubagentUpdate(pending.params),
                  case .agentMessageChunk(let chunk) = pending.params.update,
                  case .text(let value) = chunk.content
            else { return nil }
            return value
        }.joined()
        return text.isEmpty ? nil : text
    }

    private func waitForPromptUpdateDelivery(promptID: Int) async {
        // RPC responses and updates arrive on separate streams. Capture only
        // updates already yielded when the response arrived, without flushing
        // the coalescer or dispatching a queued successor during completion.
        let watermark = connection.client.yieldedUpdateCount
        while dequeuedUpdateCount < watermark {
            guard activePromptID == promptID, !stopped, !Task.isCancelled,
                  updatesTask?.isCancelled == false, isConnectionCurrent(), holdsLeaseForWrite()
            else { return }
            await Task.yield()
        }
    }

    /// A usage limit stopped the active prompt. The prompt itself reached the
    /// agent (it is in the agent's history), so a queued one is consumed like
    /// a success; resuming sends a short continue prompt instead.
    private func applyUsageLimit(_ detected: ACPUsageLimit, failedQueuedItemId: UUID?) {
        var previous = session.usageLimit
        var consumedWake: QueuedPrompt?
        if let failedQueuedItemId, session.queue.first?.id == failedQueuedItemId {
            let consumed = session.queue.first
            if consumed?.backgroundTaskWake != nil {
                consumedWake = consumed
            } else {
                _ = session.popQueueHead()
            }
            previous = previous ?? consumed?.usageLimit
            session.normalQueuedTurnIDs.remove(failedQueuedItemId)
            session.normalQueuedTurnUserMessageIDs.removeValue(forKey: failedQueuedItemId)
        }
        let limit = ACPUsageLimitResumePolicy.merge(previous: previous, detected: detected)
        session.usageLimit = limit
        persistUsageLimit()
        if autoResumeAfterUsageLimit(),
           let resumeAt = ACPUsageLimitResumePolicy.nextResumeAt(limit, now: Date()) {
            session.upsertUsageLimitResume(limit: limit, scheduledAt: resumeAt)
        } else {
            session.removeUsageLimitResume()
        }
        if let consumedWake {
            persistBackgroundWakeAndQueue(
                rows: markBackgroundWakesDelivered(for: consumedWake),
                consuming: consumedWake)
        } else {
            persistQueue()
        }
    }

    /// Re-upsert the session's persistence row to capture changes to
    /// title / model / mode / config options / autoRun that the runner mutated directly.
    /// `ACPSessionManager.persist` does the same thing plus a recent-list refresh;
    /// the runner skips that because it has no manager handle, and the next open
    /// via the manager picks up the new row.
    func persistSessionRow(preserveTitle: Bool = true, completion: ((Bool) -> Void)? = nil) {
        guard holdsLeaseForWrite() else {
            completion?(false)
            return
        }
        let title = session.title
        let titleSource = session.titleSource
        let currentModel = session.currentModel
        let currentMode = session.currentMode
        let configOptionValues: [String: ACPConfigValue]? =
            session.hasReceivedConfigOptions && !session.isRestoringPersistedConfigOptions
                ? session.configOptionValuesForPersistence()
                : nil
        let autoRun = session.autoRunEnabled
        let fence = leaseFenceProvider()
        let sessionId = sessionId
        enqueuePersistence({ persistence in
            try await persistence.updateSessionFromRuntime(
                id: sessionId,
                title: title,
                titleSource: titleSource,
                currentModel: currentModel,
                currentMode: currentMode,
                configOptionValues: configOptionValues,
                autoRun: autoRun,
                preserveTitle: preserveTitle,
                fence: fence
            )
        }, completion: { [weak self] row in
            let persistedRow = row.flatMap { $0 }
            if let persistedRow {
                self?.onPersistedConfigOptionValues?(persistedRow.configOptionValues)
            }
            completion?(persistedRow != nil)
        })
    }

    func persistFallbackTitleIfStoredPlaceholder() {
        guard holdsLeaseForWrite() else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let title = session.title
        let fence = leaseFenceProvider()
        let sessionId = sessionId
        enqueuePersistence({ persistence in
            try await persistence.updateFallbackTitleIfPlaceholder(
                id: sessionId,
                title: title,
                updatedAt: now,
                fence: fence
            )
        }, completion: { [weak self] updated in
            guard let self else { return }
            if updated == true {
                if self.session.titleSource == .fallback, self.session.title == title {
                    self.onSessionTitleUpdated?(title)
                }
                return
            }
            guard let row = try? await self.persistence.loadSession(id: self.sessionId),
                  row.titleSource != .placeholder else { return }
            self.session.title = row.title
            self.session.titleSource = row.titleSource
        })
    }

    private func generateLocalTitle(for text: String) {
        guard !localTitleAttempted, session.titleSource == .fallback,
              let candidate = ACPLocalTitleGenerator.candidate(from: text)
        else { return }
        localTitleAttempted = true
        guard localTitlesEnabled() else { return }
        let revision = providerTitleRevision
        let fallback = session.title
        localTitleTask = Task { [weak self] in
            guard let self else { return }
            defer { self.localTitleTask = nil }
            guard let title = await self.localTitleGenerator(candidate),
                  let title = ACPLocalTitleGenerator.validTitle(title),
                  !Task.isCancelled, !self.stopped, self.holdsLeaseForWrite(),
                  self.localTitlesEnabled(), self.providerTitleRevision == revision,
                  self.session.titleSource == .fallback, self.session.title == fallback
            else { return }
            let now = Int64(Date().timeIntervalSince1970)
            let fence = self.leaseFenceProvider()
            let sessionId = self.sessionId
            self.enqueuePersistence({ persistence in
                try await persistence.updateLocalTitleIfFallback(
                    id: sessionId, title: title, updatedAt: now, fence: fence
                )
            }, completion: { [weak self] updated in
                guard let self, !self.stopped, self.holdsLeaseForWrite() else { return }
                if updated == true {
                    guard self.providerTitleRevision == revision,
                          self.session.titleSource == .fallback,
                          self.session.title == fallback else { return }
                    self.session.title = title
                    self.session.titleSource = .local
                    self.onSessionTitleUpdated?(title)
                } else if let row = try? await self.persistence.loadSession(id: self.sessionId),
                          row.titleSource == .manual || row.titleSource == .provider {
                    self.session.title = row.title
                    self.session.titleSource = row.titleSource
                    self.onSessionTitleUpdated?(row.title)
                }
            })
        }
    }

    func applySessionInfoTitle(_ info: ACPSessionInfoUpdate) {
        guard holdsLeaseForWrite() else { return }
        switch info.title {
        case .absent:
            return
        case .null:
            providerTitleRevision += 1
            clearSessionInfoTitle()
        case .value(let rawTitle):
            guard !rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            providerTitleRevision += 1
            applySessionInfoTitleValue(rawTitle)
        }
    }

    private func applySessionInfoTitleValue(_ rawTitle: String) {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard session.titleSource != .manual else { return }

        let now = Int64(Date().timeIntervalSince1970)
        session.title = trimmed
        session.titleSource = .provider
        let fence = leaseFenceProvider()
        let sessionId = sessionId
        enqueuePersistence({ persistence in
            try await persistence.updateGeneratedTitleIfNotManual(
                id: sessionId,
                title: trimmed,
                updatedAt: now,
                fence: fence
            )
        }, completion: { [weak self] updated in
            guard let self else { return }
            if updated == true {
                self.onSessionTitleUpdated?(trimmed)
                return
            }
            guard let row = try? await self.persistence.loadSession(id: self.sessionId),
                  row.titleSource == .manual else { return }
            self.session.title = row.title
            self.session.titleSource = row.titleSource
        })
    }

    private func clearSessionInfoTitle() {
        guard session.titleSource != .manual else { return }

        let now = Int64(Date().timeIntervalSince1970)
        session.title = "New session"
        session.titleSource = .placeholder
        onSessionTitleUpdated?("New session")
        let fence = leaseFenceProvider()
        let sessionId = sessionId
        enqueuePersistence({ persistence in
            try await persistence.clearGeneratedTitleIfNotManual(
                id: sessionId,
                updatedAt: now,
                fence: fence
            )
        }, completion: { [weak self] updated in
            guard updated != true, let self else { return }
            guard let row = try? await self.persistence.loadSession(id: self.sessionId),
                  row.titleSource == .manual else { return }
            self.session.title = row.title
            self.session.titleSource = row.titleSource
        })
    }

    /// Returns `absolutePath` relative to the runner's worktree, or
    /// `nil` if the path escapes it. Used by the file-edit card so the
    /// diff opener can hand the value straight to `git.diff(file:)`.
    func relativeToWorktree(_ absolutePath: String) -> String? {
        let root = URL(fileURLWithPath: worktreePath).standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let target = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        guard target.hasPrefix(prefix) else { return nil }
        return String(target.dropFirst(prefix.count))
    }

    /// ACP `fs/read_text_file` accepts optional `line` (1-indexed
    /// start) and `limit` (max lines) parameters. Honouring them lets
    /// agents fetch bounded slices of large files instead of always
    /// receiving the whole content (and avoids dumping huge files into
    /// the agent's context window).
    nonisolated static func sliceLines(_ full: String, line: Int?, limit: Int?) -> String {
        if line == nil, limit == nil { return full }
        let lines = full.split(separator: "\n", omittingEmptySubsequences: false)
        let startLine = max(1, line ?? 1)
        let startIdx = min(startLine - 1, lines.count)
        let endIdx: Int
        if let limit, limit > 0 {
            endIdx = min(startIdx + limit, lines.count)
        } else {
            endIdx = lines.count
        }
        return lines[startIdx ..< endIdx].joined(separator: "\n")
    }

    /// Sendable outcome of an off-main agent `fs/read_text_file`. Kept minimal
    /// (only value types) so it can cross back to the main actor without an
    /// `@unchecked Sendable` escape hatch.
    /// Whether a read result is too large to return, and what to tell the
    /// adapter if so.
    ///
    /// Judged on the bytes actually being returned. An earlier version asked
    /// instead whether a range had been requested, which a caller could
    /// satisfy without bounding anything: `sliceLines` runs to end of file
    /// unless `limit` is present *and positive*, so `line: 1` alone — or
    /// `limit: 0` — asks for the whole file while looking like a range.
    ///
    /// Shared by the local and remote read paths so the two cannot drift into
    /// different answers for the same request.
    nonisolated static func readRefusal(name: String, bytes: Int) -> String? {
        guard bytes > maxWholeFileReadBytes else { return nil }
        return "\(name) is \(bytes) bytes, over the "
            + "\(maxWholeFileReadBytes)-byte limit for a single read. "
            + "Request a smaller range with the line and limit parameters."
    }

    /// Whether a request bounds its own result. Only a positive `limit` does;
    /// see `readRefusal`.
    nonisolated static func requestIsBounded(limit: Int?) -> Bool {
        (limit ?? 0) > 0
    }

    /// Largest file returned in full by `fs/read_text_file`.
    ///
    /// Sized by what a consumer can use rather than by what the machine can
    /// hold: this is already far past any model's context window, so a
    /// response beyond it is waste in both directions. Ranged reads are not
    /// subject to it.
    nonisolated static let maxWholeFileReadBytes = 64 * 1024 * 1024

    enum FileReadOutcome: Sendable {
        case success(Data)
        case failure(message: String)
    }

    /// Reads a file from disk (or uses a caller-supplied live-buffer snapshot),
    /// slices it, and JSON-encodes the `fs/read_text_file` response body.
    ///
    /// `nonisolated async` so the disk read + string slicing + encoding run on
    /// the cooperative pool instead of the main actor — agents read files
    /// constantly and a large lockfile/asset would otherwise block the UI. The
    /// live-buffer lookup itself stays on the main actor at the call site; only
    /// its already-materialized `String` snapshot is passed in here.
    nonisolated static func serveRead(
        target: URL,
        liveBuffer: String?,
        line: Int?,
        limit: Int?
    ) async -> FileReadOutcome {
        do {
            // Cheap first pass: a request that does not bound its own result
            // cannot return less than the source, so an oversized source can
            // be refused without reading it.
            if !Self.requestIsBounded(limit: limit) {
                let sourceBytes = liveBuffer.map { $0.utf8.count }
                    ?? (try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                if let sourceBytes,
                   let refusal = Self.readRefusal(
                       name: target.lastPathComponent, bytes: sourceBytes
                   ) {
                    return .failure(message: refusal)
                }
            }
            let full: String
            if let liveBuffer {
                full = liveBuffer
            } else {
                let data = try Data(contentsOf: target)
                full = String(data: data, encoding: .utf8) ?? ""
            }
            let sliced = sliceLines(full, line: line, limit: limit)
            // Authoritative: whatever was asked for, this is what would be
            // returned, and a generous `limit` can still ask for everything.
            if let refusal = Self.readRefusal(
                name: target.lastPathComponent, bytes: sliced.utf8.count
            ) {
                return .failure(message: refusal)
            }
            let body = try JSONEncoder().encode(ACPFsReadResult(content: sliced))
            return .success(body)
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }

    /// Called from every "user interrupted" code path (Esc, composer Stop
    /// button, toolbar Stop). Sends `session/cancel` over the wire, stops
    /// any pending permission continuation, marks in-flight tool calls as
    /// canceled, posts a system notice, and flips `streamingState` back
    /// to `.idle`. Persists all mutations so they survive a reload.
    /// Returns whether the cancel reached the agent: false when the runner
    /// lost its connection or writer lease before sending it.
    @discardableResult
    func userCancel(confirmingLease: Bool = true) async -> Bool {
        guard isConnectionCurrent() else { return false }
        invalidateNativeSteering()
        flushPendingIncomingUpdates(flushQueueWhenBoundaryReady: false)
        let backgroundIds = session.backgroundTaskStopSupported
            ? session.activeBackgroundTasks.filter(\.canStop).map(\.id) : []
        let childIds = session.orderedSubagents.filter { $0.isRunning && $0.capabilities.supportsCancel }
            .map(\.subagentSessionId)
        let cancellingBackground = activePromptID == nil && session.transcript.streamingState == .idle
            && session.transcript.pendingUserInputs.isEmpty && (!backgroundIds.isEmpty || !childIds.isEmpty)
        if cancellingBackground {
            guard !backgroundCancellationInProgress else { return false }
            backgroundCancellationInProgress = true
        }
        defer {
            if cancellingBackground {
                backgroundCancellationInProgress = false
                flushQueueIfIdle()
            }
        }
        if cancellingBackground {
            var sent = false
            for id in backgroundIds {
                let reachedAgent = await stopBackgroundTask(id: id)
                sent = sent || reachedAgent
            }
            for id in childIds {
                let reachedAgent = await cancelSubagent(subagentSessionId: id)
                sent = sent || reachedAgent
            }
            return sent
        }
        turnPublicationGeneration += 1
        discardPendingSuccessfulTurn("userCancel")
        flushPendingIncomingUpdates(flushQueueWhenBoundaryReady: false)
        session.clearRetryStatus()
        // Capture the prompt + queue head the user INTENDED to stop
        // BEFORE awaiting `connection.cancel`. Without this snapshot, a
        // natural completion of the in-flight prompt during the cancel
        // round-trip would let the success path drain a queue item, and
        // `activePromptID` after the await would point at the freshly-
        // flushed queued send — so Stop would cancel + pop a prompt the
        // user only queued, not the one they pressed Stop on.
        // Snapshot the intended target AND insert it into
        // `cancelledPromptIDs` BEFORE awaiting `connection.cancel`. The
        // cancel notification can make the in-flight `session/prompt`
        // RPC throw before we resume; if `cancelledPromptIDs` isn't
        // populated by then, the prompt task's catch path reads
        // `wasCancelled == false`, calls `setQueueHeadError`, and
        // flips the queue head back to `.pending` with a lastError.
        // The post-await block below then can't pop it (status no
        // longer `.sending`), leaving the cancelled prompt stuck at
        // the front of the queue. Pre-registering the cancellation
        // makes the catch path skip the error path entirely.
        let intended: (promptID: Int?, queueHeadID: UUID?) = await MainActor.run {
            let snapshot: (promptID: Int?, queueHeadID: UUID?) = (
                activePromptID,
                session.queue.first.flatMap { $0.status == .sending ? $0.id : nil }
            )
            if let promptID = snapshot.promptID {
                cancelledPromptIDs.insert(promptID)
            }
            return snapshot
        }
        guard isConnectionCurrent() else { return false }
        if confirmingLease {
            // A former writer that lost the lease must not send a cancel RPC to
            // the agent for a session another instance now owns. The local
            // bookkeeping above (cancelledPromptIDs insert) is fine to keep —
            // it only affects this runner's own sendNow catch path and has no
            // cross-instance side effects.
            guard await hasConfirmedLeaseForSideEffect() else { return false }
        }
        guard isConnectionCurrent() else { return false }
        onUserCancel?()
        let remoteId = session.remoteSessionId ?? sessionId
        try? await connection.cancel(sessionId: remoteId)
        guard isConnectionCurrent() else { return true }
        await MainActor.run {
            guard self.isConnectionCurrent() else { return }
            flushStreamingPersist()
            if let promptID = intended.promptID {
                // Only clear activePromptID if it's still ours — a
                // natural completion + queued promotion during the
                // cancel await would have moved it on.
                if activePromptID == promptID {
                    activePromptID = nil
                    // `sendNow`'s own success/catch handlers only emit
                    // inside their `isActivePrompt` guard, which this branch
                    // has just made false for them — so if the RPC settles
                    // after this point, neither of their emit calls fires.
                    // This is the mutually-exclusive counterpart: whichever
                    // of {this block, sendNow's handler} observes
                    // `activePromptID == promptID` first performs the
                    // clear-and-emit; the other sees it already cleared and
                    // no-ops. `activePromptStartedAt` still belongs to this
                    // promptID by the same invariant `sendNow` relies on
                    // (nothing overwrites it without first changing
                    // `activePromptID` away from `promptID`).
                    emitTurnCompleted(.cancelled, promptID: promptID, usageAwaitsResult: true)
                }
            }
            policy.userCancelled()
            let changedIndices = session.cancelInFlightToolCalls()
            session.terminalHost.killAll()
            if holdsLeaseForWrite() {
                _ = persistIndices(Set(changedIndices))
            }
            // Pop the head ONLY if it's the same `.sending` item we
            // were aiming at. If a queued item promoted itself during
            // the await it's a fresh prompt the user hasn't stopped —
            // leave it alone.
            if let stoppedID = intended.queueHeadID,
               let current = session.queue.first,
               current.id == stoppedID,
                current.status == .sending {
                let wakeRows = markBackgroundWakesDelivered(for: current)
                if current.backgroundTaskWake != nil {
                    persistBackgroundWakeAndQueue(rows: wakeRows, consuming: current)
                } else {
                    session.queue.removeFirst()
                    persistQueue()
                }
            }
            appendAndPersistSystemNotice("Interrupted by user.")
            // Only force state to .idle if a successor prompt hasn't
            // already taken ownership. A natural completion of the
            // intended prompt during the cancel await can let
            // flushQueueIfIdle promote a queued head to .sending and
            // dispatch its sendNow; that successor now owns
            // streamingState. Forcing .idle here would make the UI
            // think the agent is free, hide the Stop pill, and let the
            // composer accept another direct send mid-flight.
            let successorOwnsState = activePromptID != nil
                && activePromptID != intended.promptID
            if !successorOwnsState {
                session.transcript.streamingState = .idle
            }
            flushQueueIfIdle()
        }
        return true
    }
}

extension ACPSessionRunner {
    /// Cancels one native subagent. `session/cancel` addressed to the CHILD
    /// session id, so the parent turn keeps running — that is the whole
    /// point of the row's Cancel action.
    ///
    /// The child's terminal state comes back as a `subagent_state_update`;
    /// nothing is assumed locally, because an agent may finish the child
    /// normally in the window before the cancel lands.
    @discardableResult
    func cancelSubagent(subagentSessionId: String) async -> Bool {
        guard isConnectionCurrent() else { return false }
        guard let run = session.subagentRun(subagentSessionId),
              run.capabilities.supportsCancel,
              run.isRunning
        else { return false }
        guard await hasConfirmedLeaseForSideEffect() else { return false }
        guard isConnectionCurrent() else { return false }
        do {
            try await connection.cancel(sessionId: subagentSessionId)
            return true
        } catch {
            return false
        }
    }

    /// Legacy callsite shim: defaults to `.auto` intent (immediate send
    /// when idle, queue when busy).
    func send(text: String, attachments: [ACPMessage.Attachment]) {
        send(text: text, attachments: attachments, intent: .auto, onPromptFinished: nil)
    }

    /// Backwards-compatible shim for callers that supply a completion but
    /// don't care about intent (e.g. existing tests, pre-queue callers).
    func send(
        text: String,
        attachments: [ACPMessage.Attachment],
        onPromptFinished: (@MainActor (_ succeeded: Bool) -> Void)?
    ) {
        send(text: text, attachments: attachments, intent: .auto, onPromptFinished: onPromptFinished)
    }

    func send(
        text: String,
        attachments: [ACPMessage.Attachment],
        intent: ACPSubmitIntent,
        draft: ACPComposerDraft? = nil,
        onPromptFinished: (@MainActor (_ succeeded: Bool) -> Void)? = nil
    ) {
        let blocks = Self.blocks(text: text, attachments: attachments)
        send(blocks: blocks, intent: intent, draft: draft, onPromptFinished: onPromptFinished)
    }
    func sendRegistered(
        text: String,
        attachments: [ACPMessage.Attachment],
        intent: ACPSubmitIntent,
        draft: ACPComposerDraft? = nil,
        normalUserTurn: Bool = true,
        onQueuedPromptEnqueued: (@MainActor (UUID) -> Void)? = nil,
        onDispatchRegistered: @escaping @Sendable () -> Void,
        onPromptFinished: (@MainActor (_ succeeded: Bool) -> Void)? = nil
    ) {
        sendRegistered(
            blocks: Self.blocks(text: text, attachments: attachments),
            intent: intent,
            draft: draft,
            normalUserTurn: normalUserTurn,
            onQueuedPromptEnqueued: onQueuedPromptEnqueued,
            onDispatchRegistered: onDispatchRegistered,
            onPromptFinished: onPromptFinished
        )
    }

    /// Build the canonical `[ACPContentBlock]` array from a composer-shaped
    /// `(text, attachments)` pair: a leading text block followed by one block
    /// per attachment — a DEFERRED `.image` (data: nil, carrying the staged
    /// file uri) for image attachments, a `.resourceLink` for everything else.
    /// Image blocks stay deferred here so SQLite never holds base64; `hydrate`
    /// resolves them at send time. Shared with
    /// `ACPSessionManager.enqueueWhileRecovering` so prompts persisted before
    /// the runner exists look identical on the wire to ones the runner enqueues.
    static func blocks(
        text: String,
        attachments: [ACPMessage.Attachment]
    ) -> [ACPContentBlock] {
        // Omit the leading text block for an image-only prompt so we don't send
        // an empty/whitespace `.text` ahead of the image(s). The composer leaves
        // a trailing space after an image chip, so the image-only text is " ",
        // not "" — trim before deciding.
        var blocks: [ACPContentBlock] = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? []
            : [.text(text)]
        for a in attachments {
            if let mime = a.mimeType, mime.hasPrefix("image/") {
                // Deferred: the staged file is referenced by uri; the inline
                // base64 (or resource-link fallback) is resolved at send time
                // by `hydrate`, so SQLite never stores the base64 payload.
                blocks.append(.image(data: nil, uri: a.uri, mimeType: mime))
            } else {
                blocks.append(.resourceLink(uri: a.uri, name: a.name))
            }
        }
        return blocks
    }

    /// Maximum dimension for an inline base64 image, in pixels.
    nonisolated static let inlineImageMaxDimension: CGFloat = 1568

    /// Resolve deferred attachment blocks just before sending. When the agent
    /// supports inline images, read the staged image file, downscale, and
    /// base64-encode it; otherwise degrade to a `file://` resource link the
    /// agent reads from disk. When the agent supports embedded context,
    /// readable text resource links inside the worktree become ACP `resource`
    /// blocks. Persisted queue state stays lightweight either way.
    ///
    /// `nonisolated async` so the synchronous file reads + downscale/base64
    /// encoding (up to 10 × 20 MB) run off the main actor; awaiting it from the
    /// main-actor send path hops to the cooperative pool instead of freezing
    /// the composer/transcript while a prompt is prepared.
    nonisolated static func hydrate(
        _ blocks: [ACPContentBlock],
        promptCapabilities: ACPInitializeResult.ACPPromptCapabilities,
        worktreePath: String
    ) async -> [ACPContentBlock] {
        blocks.map { block in
            if case .image(let data, let uri, _) = block, data == nil, let uri {
                let name = (URL(string: uri)?.lastPathComponent) ?? "image"
                if promptCapabilities.image,
                   let fileURL = URL(string: uri),
                   let encoded = ACPImageEncoding.inlineBase64(fileURL: fileURL, maxDimension: inlineImageMaxDimension) {
                    return .image(data: encoded.data, uri: nil, mimeType: encoded.mimeType)
                }
                return .resourceLink(uri: uri, name: name)
            }
            if case .resourceLink(let uri, let name) = block,
               promptCapabilities.embeddedContext,
               let embedded = Self.embeddedTextResource(uri: uri, name: name, worktreePath: worktreePath) {
                return embedded
            }
            return block
        }
    }

    nonisolated private static func embeddedTextResource(
        uri: String,
        name: String?,
        worktreePath: String
    ) -> ACPContentBlock? {
        guard let fileURL = URL(string: uri), fileURL.isFileURL else {
            return nil
        }
        let rootURL = URL(fileURLWithPath: worktreePath).resolvingSymlinksInPath()
        let resolvedURL = fileURL.resolvingSymlinksInPath()
        guard Self.isWithinWorktree(resolvedURL, rootURL: rootURL) else {
            return nil
        }
        guard let values = try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else {
            return nil
        }
        if let byteCount = values.fileSize, byteCount > 1_000_000 {
            return nil
        }
        guard let text = try? String(contentsOf: resolvedURL, encoding: .utf8) else {
            return nil
        }
        return .resource(uri: uri, mimeType: Self.textMimeType(for: resolvedURL, fallbackName: name), text: text)
    }

    nonisolated private static func isWithinWorktree(_ url: URL, rootURL: URL) -> Bool {
        let rootPath = rootURL.path
        let path = url.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    nonisolated private static func textMimeType(for url: URL, fallbackName: String?) -> String {
        let ext = (url.pathExtension.isEmpty ? URL(fileURLWithPath: fallbackName ?? "").pathExtension : url.pathExtension)
            .lowercased()
        switch ext {
        case "md", "markdown": return "text/markdown"
        case "json": return "application/json"
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js", "mjs", "cjs": return "text/javascript"
        case "xml": return "application/xml"
        case "yaml", "yml": return "application/yaml"
        default: return "text/plain"
        }
    }

    /// Replaces attached-session links with their context, resolved now so
    /// a queued prompt carries the session as it is when it is sent.
    private func expandingSessionReferences(_ blocks: [ACPContentBlock]) async -> [ACPContentBlock] {
        let ids = ACPSessionReference.sessionIds(in: blocks)
        guard !ids.isEmpty else { return blocks }
        var contexts: [String: String] = [:]
        for id in ids where id != sessionId {
            contexts[id] = await sessionReferenceContext?(id)
        }
        return ACPSessionReference.replacingReferences(in: blocks, contexts: contexts, selfSessionId: sessionId)
    }

    /// Backwards-compatible helper for existing image-only tests.
    nonisolated static func hydrate(_ blocks: [ACPContentBlock], imageInputSupported: Bool) async -> [ACPContentBlock] {
        await hydrate(blocks, promptCapabilities: .init(image: imageInputSupported), worktreePath: "/")
    }

    /// Primary entry. Resolves the routing then dispatches to one of:
    ///   - sendNow  → records the user prompt, awaits prompt RPC
    ///   - enqueue  → appends to queue + persists
    ///   - steer    → cancels in-flight + preserves queue + sends
    ///   - noOp     → empty composer, ignore
    /// `draft` is the structured composer state for lossless edit-restore.
    /// The `enqueue` route persists it onto the queued item for that purpose;
    /// every route also forwards it to `sendNow`, which reads its image
    /// segments' offsets to annotate the recorded attachments' `textOffset`
    /// (see `ACPSessionRunner.attachments(of:draft:)`).
    private func sendRegistered(
        blocks: [ACPContentBlock],
        intent: ACPSubmitIntent,
        draft: ACPComposerDraft? = nil,
        normalUserTurn: Bool = true,
        onQueuedPromptEnqueued: (@MainActor (UUID) -> Void)? = nil,
        onDispatchRegistered: (@Sendable () -> Void)? = nil,
        onPromptFinished: (@MainActor (_ succeeded: Bool) -> Void)? = nil
    ) {
        if case .schedule(let date) = intent {
            guard !blocks.isEmpty else {
                onDispatchRegistered?()
                Task { @MainActor in onPromptFinished?(false) }
                return
            }
            let queuedId = session.enqueueScheduled(blocks: blocks, scheduledAt: date, draft: draft)
            if normalUserTurn { session.normalQueuedTurnIDs.insert(queuedId) }
            onDispatchRegistered?()
            persistQueue(completion: { [weak self] persisted in
                if persisted {
                    self?.flushQueueIfIdle()
                } else {
                    if self?.session.removeFromQueue(id: queuedId) == true {
                        self?.persistQueue()
                    }
                }
                onPromptFinished?(persisted)
            })
            return
        }
        // A native fork barrier, or a delegated child whose requested model
        // is not acknowledged yet, holds every submit in the queue.
        if nativeForkBarrierActive || session.holdsPromptsForDelegatedSelection {
            guard !blocks.isEmpty else {
                onDispatchRegistered?()
                Task { @MainActor in onPromptFinished?(false) }
                return
            }
            let queuedPromptId = UUID()
            session.enqueue(id: queuedPromptId, blocks: blocks, draft: draft)
            if normalUserTurn { session.normalQueuedTurnIDs.insert(queuedPromptId) }
            persistQueue()
            if let onDispatchRegistered {
                if let onQueuedPromptEnqueued {
                    onQueuedPromptEnqueued(queuedPromptId)
                } else {
                    onDispatchRegistered()
                }
            }
            Task { @MainActor in onPromptFinished?(true) }
            return
        }
        let route = ACPSubmitRoute.resolve(
            intent: intent,
            state: session.transcript.streamingState,
            queueEmpty: session.queue.isEmpty,
            blocksEmpty: blocks.isEmpty,
            hasPendingInput: !session.transcript.pendingUserInputs.isEmpty,
            inFlightSteer: steerInProgress,
            hasActivePrompt: activePromptID != nil || detachedSteeringTurn
        )
        switch route {
        case .noOp:
            // Composer guards empty submits before invoking onSubmit, but
            // tell the caller the submit was rejected so its draft state
            // stays consistent.
            onDispatchRegistered?()
            Task { @MainActor in onPromptFinished?(false) }
        case .sendNow:
            sendNow(
                blocks: blocks,
                queuedItemId: nil,
                normalUserTurn: normalUserTurn,
                draft: draft,
                onDispatchRegistered: onDispatchRegistered,
                onPromptFinished: onPromptFinished
            )
        case .enqueue:
            let scheduledWasHead = session.queue.first?.scheduledAt != nil
            let queuedPromptId = UUID()
            session.enqueue(id: queuedPromptId, blocks: blocks, draft: draft)
            if normalUserTurn { session.normalQueuedTurnIDs.insert(queuedPromptId) }
            persistQueue()
            if let onDispatchRegistered {
                if let onQueuedPromptEnqueued {
                    onQueuedPromptEnqueued(queuedPromptId)
                } else {
                    onDispatchRegistered()
                }
            }
            if scheduledWasHead { flushQueueIfIdle() }
            // The user's prompt was accepted into the queue — from the
            // composer's perspective this is a successful submission so
            // the persisted draft can be cleared. The actual RPC fires
            // later when the flusher drains the head.
            Task { @MainActor in onPromptFinished?(true) }
        case .steer:
            steer(
                blocks: blocks,
                normalUserTurn: normalUserTurn,
                draft: draft,
                onDispatchRegistered: onDispatchRegistered,
                onPromptFinished: onPromptFinished
            )
        }
    }
    func send(
        blocks: [ACPContentBlock],
        intent: ACPSubmitIntent,
        draft: ACPComposerDraft? = nil,
        onPromptFinished: (@MainActor (_ succeeded: Bool) -> Void)? = nil
    ) {
        sendRegistered(
            blocks: blocks,
            intent: intent,
            draft: draft,
            onDispatchRegistered: nil,
            onPromptFinished: onPromptFinished
        )
    }

    func queueSnapshotForPersistence(
        consuming consumed: QueuedPrompt? = nil, waitForPendingConfirmations: Bool = false
    ) -> @MainActor @Sendable () async -> [QueuedPrompt] {
        let items = session.queue.filter { item in
            guard let consumed else { return true }
            return item.id != consumed.id || item.brokerOperationAttempt != consumed.brokerOperationAttempt
        }
        let confirmations = backgroundWakeConfirmations
        let confirmationTail = confirmations.isEmpty ? nil : persistenceTail
        return {
            // Manager writes have a separate persistence pipeline. Wait for
            // the confirmation callback before either writer reads its result.
            await confirmationTail?.value
            if waitForPendingConfirmations {
                let pendingTail = self.backgroundWakeConfirmations.isEmpty ? nil : self.persistenceTail
                await pendingTail?.value
            }
            // Preserve its removal or failed-save recovery, without changing
            // unrelated items or a newer retry captured under the same ID.
            // A manager snapshot can precede the confirmation itself.
            return items.compactMap { item in
                guard confirmations[item.id] == item.brokerOperationAttempt
                    || (waitForPendingConfirmations && item.backgroundTaskWake != nil) else { return item }
                return self.session.queue.first { $0.id == item.id && $0.brokerOperationAttempt == item.brokerOperationAttempt }
            }
        }
    }

    /// Persist the current queue snapshot. Called after every mutation:
    /// enqueue, edit, remove, reorder, head-status flip. Fire-and-forget
    /// snapshots swallow write failures, matching transcript persistence.
    /// Callers that gate an external side effect pass a completion and must
    /// honor its result before proceeding.
    func persistQueue(
        acknowledging acknowledgement: ACPDurableConsumptionAcknowledgement? = nil,
        retainOnFailure: Bool = false,
        completion: (@MainActor (_ persisted: Bool) -> Void)? = nil
    ) {
        guard holdsLeaseForWrite() else {
            Task { @MainActor in completion?(false) }
            return
        }
        let queueSnapshot = queueSnapshotForPersistence()
        let fence = leaseFenceProvider()
        let sessionId = sessionId
        queueSaveGeneration += 1
        let generation = queueSaveGeneration
        let counted = acknowledgement != nil || completion != nil || retainOnFailure
        if counted { session.pendingQueuePersistenceCount += 1 }
        enqueuePersistence({ persistence in
            let items = await queueSnapshot()
            return try await persistence.upsertQueue(sessionId: sessionId, items: items, fence: fence)
        }, completion: { persisted in
            let didPersist = persisted == true
            if counted { self.session.pendingQueuePersistenceCount -= 1 }
            if didPersist {
                // A newer committed snapshot durably supersedes failed saves.
                // Release their protected cursors before permitting dispatch.
                let deferred = self.deferredQueueAcknowledgements.filter { $0.generation <= generation }
                self.deferredQueueAcknowledgements.removeAll { $0.generation <= generation }
                self.session.pendingQueuePersistenceCount -= deferred.count
                deferred.forEach { $0.acknowledgement?() }
                acknowledgement?()
                if !deferred.isEmpty, self.session.lastError == "Could not save follow-up delivery confirmation." {
                    self.session.lastError = nil
                }
                if counted || !deferred.isEmpty {
                    if !self.sendPendingQueueForceSendsAfterPersistence(), acknowledgement != nil || !deferred.isEmpty {
                        self.flushQueueIfIdle()
                    }
                }
            } else if retainOnFailure, self.isConnectionCurrent(), !self.stopped {
                self.deferredQueueAcknowledgements.append((generation, acknowledgement))
                self.session.pendingQueuePersistenceCount += 1
            }
            completion?(didPersist)
        })
    }

    /// Persist that the one-time MCP context preamble has been delivered:
    /// clears the pending text and flips `mcpPreambleSent`. Called from
    /// `sendNow` right after the wire prompt that carried the preamble
    /// succeeds — mirrors `persistQueue()`'s fire-and-forget pattern since
    /// losing this write just means the preamble is (harmlessly) resent.
    /// When `holdsLeaseForWrite()` is false this returns early and leaves
    /// the row `pending`: a later hydrate on the writing instance will see
    /// the still-pending row and re-inject the preamble, which is a benign
    /// duplicate delivery — the agent just sees the context text twice.
    private func persistMCPPreambleSent() {
        guard holdsLeaseForWrite() else { return }
        let fence = leaseFenceProvider()
        let sessionId = sessionId
        enqueuePersistence { persistence in
            _ = try await persistence.setMCPPreamble(
                sessionId: sessionId, pendingText: nil, sent: true, fence: fence)
        }
    }

    /// Mirror `session.usageLimit` onto the session row. The resume item is
    /// not enough: a limit with auto-resume off or cancelled has none, and
    /// the reopened session must still hold the pre-limit queue.
    private func persistUsageLimit() {
        guard holdsLeaseForWrite() else { return }
        let fence = leaseFenceProvider()
        let sessionId = sessionId
        let limit = session.usageLimit
        enqueuePersistence { persistence in
            _ = try await persistence.setUsageLimit(sessionId: sessionId, limit: limit, fence: fence)
        }
    }

    /// Mirror `session.directTurnInFlight` onto the session row, on the same
    /// pipeline as `persistQueue` so a continuation queued for the turn is
    /// saved before its marker is cleared.
    func setDirectTurnInFlight(_ inFlight: Bool) {
        guard session.directTurnInFlight != inFlight else { return }
        session.directTurnInFlight = inFlight
        persistDirectTurnInFlight()
    }

    func persistDirectTurnInFlight() {
        guard holdsLeaseForWrite() else { return }
        let fence = leaseFenceProvider()
        let sessionId = sessionId
        let inFlight = session.directTurnInFlight
        enqueuePersistence { persistence in
            _ = try await persistence.setDirectTurnInFlight(sessionId: sessionId, inFlight: inFlight, fence: fence)
        }
    }

    private func persistForkContextDelivered(
        acknowledging acknowledgement: ACPDurableConsumptionAcknowledgement? = nil
    ) {
        guard holdsLeaseForWrite() else { return }
        let fence = leaseFenceProvider()
        let sessionId = sessionId
        if let acknowledgement {
            enqueuePersistence({ persistence in
                try await persistence.clearForkContextDeliveryPending(
                    targetSessionID: sessionId,
                    fence: fence
                )
            }, completion: { persisted in
                if persisted == true {
                    acknowledgement()
                }
            })
        } else {
            enqueuePersistence { persistence in
                _ = try await persistence.clearForkContextDeliveryPending(
                    targetSessionID: sessionId,
                    fence: fence
                )
            }
        }
    }

    private func persistForkContextDeliveredAndQueue(
        acknowledging acknowledgement: ACPDurableConsumptionAcknowledgement?
    ) {
        guard holdsLeaseForWrite() else { return }
        let queueSnapshot = queueSnapshotForPersistence()
        let fence = leaseFenceProvider()
        let sessionId = sessionId
        enqueuePersistence({ persistence in
            let items = await queueSnapshot()
            guard try await persistence.clearForkContextDeliveryPending(
                targetSessionID: sessionId,
                fence: fence
            ) else { return false }
            return try await persistence.upsertQueue(
                sessionId: sessionId,
                items: items,
                fence: fence
            )
        }, completion: { persisted in
            if persisted == true {
                acknowledgement?()
            }
        })
    }

    /// Drain the queue head if the runner is still live, setup is not
    /// blocked on auth, no prompt owns the transport, transcript state is
    /// `.idle`, the head is `.pending`, and the head has no `lastError`.
    /// Marks the head `.sending`, persists, and dispatches `sendNow` with the
    /// head's id so success can pop the right item and failure can flag the
    /// right item without disturbing the rest of the queue.
    ///
    /// Chained drain is implicit: sendNow's completion sets state to
    /// `.idle` and calls back here.
    func flushQueueIfIdle() {
        guard isConnectionCurrent() else { return }
        guard !stopped else { return }
        guard holdsLeaseForWrite() else { return }
        guard !backgroundCancellationInProgress,
              !nativeForkBarrierActive,
              !session.holdsPromptsForDelegatedSelection,
              !steerInProgress,
              !detachedSteeringTurn,
              session.agentState == .ready,
              session.pendingQueuePersistenceCount == 0,
              activePromptID == nil,
              session.transcript.streamingState == .idle,
              session.transcript.pendingUserInputs.isEmpty,
              let head = session.queue.first,
              head.status == .pending,
              head.lastError == nil,
              !head.deliveryUncertain,
              // Sending a pre-limit item into the limit would consume it.
              // It drains once a successful turn clears `usageLimit`.
              !head.isHeld(by: session.usageLimit)
        else { return }
        if case .needsAuth = session.setupState { return }
        guard head.isReady() else {
            scheduleQueueWake(at: head.scheduledAt!)
            return
        }
        scheduledQueueWakeTask?.cancel()
        scheduledQueueWakeTask = nil
        guard let brokerOperationKey = session.markQueueHeadSending() else {
            return
        }
        sendQueuedHead(head, brokerOperationKey: brokerOperationKey)
    }

    /// Shared durable dispatch boundary for ordinary queue drains and owned
    /// continuations whose steering request did not consume the content.
    private func sendQueuedHead(
        _ head: QueuedPrompt,
        brokerOperationKey: String,
        onPromptFinished: (@MainActor (Bool) -> Void)? = nil,
        onDispatchSettled: (@MainActor @Sendable () -> Void)? = nil
    ) {
        persistQueue(completion: { [weak self] persisted in
            guard let self else {
                onPromptFinished?(false)
                onDispatchSettled?()
                return
            }
            guard persisted else {
                guard self.isConnectionCurrent(),
                      !self.stopped,
                      self.session.queue.first?.id == head.id,
                      self.session.queue.first?.status == .sending
                else {
                    onPromptFinished?(false)
                    onDispatchSettled?()
                    return
                }
                self.session.setQueueHeadError(
                    "Could not save queued message; it was not sent.",
                    clearDispatchProvenance: true
                )
                self.persistQueue()
                self.onPromptWorkChanged?()
                onPromptFinished?(false)
                onDispatchSettled?()
                return
            }
            guard self.isConnectionCurrent(),
                  !self.stopped,
                  self.session.queue.first?.id == head.id,
                  self.session.queue.first?.status == .sending
            else {
                onPromptFinished?(false)
                onDispatchSettled?()
                return
            }
            var onDispatchRegistered = self.queuedPromptDispatchRegistration(for: head.id)
            if let onDispatchSettled {
                let registration = onDispatchRegistered
                onDispatchRegistered = {
                    registration?()
                    Task { @MainActor in onDispatchSettled() }
                }
            }
            self.sendNow(
                blocks: head.blocks,
                queuedItemId: head.id,
                delegatedSource: head.delegatedSource,
                brokerOperationKey: brokerOperationKey,
                normalUserTurn: self.session.normalQueuedTurnIDs.contains(head.id),
                // The raw optional, not `restorableDraft`: that heuristically
                // fabricates a draft from `blocks` when none was captured, and
                // `blocks` has already flattened every image to the end of the
                // text — annotating from it would invent a wrong end-of-message
                // offset instead of leaving `textOffset` nil as documented on
                // `ACPMessage.Attachment.textOffset`.
                draft: head.draft,
                onDispatchRegistered: onDispatchRegistered,
                beforeRequestHandoff: self.queuedPromptRequestHandoff(for: head.id),
                onRequestHandoffDidOccur: self.queuedPromptHandoffDidOccur(for: head.id),
                onPromptFinished: onPromptFinished
            )
        })
    }

    private func queuedPromptDispatchRegistration(for itemId: UUID) -> (@Sendable () -> Void)? {
        onQueuedPromptDispatchRegistration?(itemId)
    }

    private func queuedPromptRequestHandoff(
        for itemId: UUID
    ) -> (@Sendable (ACPBrokerGeneration?) async throws -> Void)? {
        guard connection.client is ACPRequestHandoffPreparing else { return nil }
        return { [weak self] brokerGeneration in
            guard let brokerGeneration else { return }
            guard let self else { throw CancellationError() }
            try await self.persistQueueDispatchProvenance(
                itemId: itemId,
                brokerGeneration: brokerGeneration
            )
        }
    }

    private func queuedPromptHandoffDidOccur(for itemId: UUID) -> (@Sendable () throws -> Void)? {
        guard connection.client is ACPRequestHandoffPreparing else { return nil }
        return { [queueDispatchHandoffTracker] in
            guard queueDispatchHandoffTracker.markHandedOff(itemId) else {
                throw CancellationError()
            }
        }
    }

    /// Invalidates every provenance write that has not crossed the transport
    /// handoff boundary. The broker callback checks the same tracker
    /// synchronously before sending, so a racing teardown either preserves an
    /// actually-handed-off marker or prevents the superseded request.
    func takeUnhandedQueueDispatchesForTeardown() -> Set<UUID> {
        queueDispatchHandoffTracker.takeUnhandedItemIDs()
    }

    private func persistQueueDispatchProvenance(
        itemId: UUID,
        brokerGeneration: ACPBrokerGeneration
    ) async throws {
        guard !stopped, isConnectionCurrent(),
              session.queue.contains(where: { $0.id == itemId && $0.status == .sending }),
              session.markQueueHeadDispatched(id: itemId, brokerGeneration: brokerGeneration)
        else { throw CancellationError() }
        queueDispatchHandoffTracker.markProvenancePending(itemId)

        let persisted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            persistQueue(completion: { didPersist in
                continuation.resume(returning: didPersist)
            })
        }
        guard persisted else {
            guard !stopped, isConnectionCurrent() else { throw CancellationError() }
            clearQueueDispatchProvenance(itemId: itemId, brokerGeneration: brokerGeneration)
            throw QueueDispatchProvenancePersistenceError()
        }
#if DEBUG
        await queueDispatchProvenancePersistedForTesting?(itemId)
#endif
        guard !stopped, isConnectionCurrent(),
              session.queue.contains(where: {
                  $0.id == itemId && $0.status == .sending && $0.dispatchedBrokerGeneration == brokerGeneration
              })
        else {
            throw CancellationError()
        }
    }

    private func clearQueueDispatchProvenance(
        itemId: UUID,
        brokerGeneration: ACPBrokerGeneration
    ) {
        guard let index = session.queue.firstIndex(where: {
            $0.id == itemId && $0.status == .sending && $0.dispatchedBrokerGeneration == brokerGeneration
        }) else { return }
        session.queue[index].dispatchedBrokerGeneration = nil
    }

    private func scheduleQueueWake(at date: Date) {
        scheduledQueueWakeTask?.cancel()
        let delay = max(0, date.timeIntervalSinceNow)
        scheduledQueueWakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.scheduledQueueWakeTask = nil
            self?.flushQueueIfIdle()
        }
    }

    func beginNativeForkBarrier() async -> Bool {
        guard canBeginNativeForkBarrier,
              await hasConfirmedLeaseForSideEffect(),
              canBeginNativeForkBarrier
        else { return false }
        nativeForkBarrierActive = true
        return true
    }

    func confirmNativeForkBarrier() async -> Bool {
        guard nativeForkBarrierActive else { return false }
        return await hasConfirmedLeaseForSideEffect()
    }

    func endNativeForkBarrier() {
        guard nativeForkBarrierActive else { return }
        nativeForkBarrierActive = false
        flushQueueIfIdle()
    }

    private var canBeginNativeForkBarrier: Bool {
        !nativeForkBarrierActive
            && !steerInProgress
            && session.agentState == .ready
            && activePromptID == nil
            && session.transcript.streamingState == .idle
            && session.transcript.pendingUserInputs.isEmpty
            && session.queue.isEmpty
    }

    /// Send a queued item next, steering the active turn where supported.
    /// Preserve every other pending item, including during fallback interruption.
    func forceSendQueuedItem(id: UUID) {
        guard holdsLeaseForWrite() else { return }
        guard let idx = session.queue.firstIndex(where: { $0.id == id }),
              session.queue[idx].status == .pending
        else { return }
        guard session.agentState == .ready else { return }
        if session.queue[idx].deliveryUncertain {
            guard session.retryQueueItem(id: id) else { return }
            persistQueue()
        }
        guard session.pendingQueuePersistenceCount == 0 else {
            if !pendingQueueForceSendsAfterPersistence.contains(id) {
                pendingQueueForceSendsAfterPersistence.append(id)
            }
            return
        }

        if steerInProgress {
            pendingForceSendQueuedItemID = id
            return
        }

        if nativeForkBarrierActive || session.holdsPromptsForDelegatedSelection {
            guard session.forceQueueItem(id: id) else { return }
            persistQueue()
            return
        }

        if session.transcript.streamingState == .idle,
           activePromptID == nil,
           !steerInProgress {
            guard session.forceQueueItem(id: id) else { return }
            persistQueue()
            flushQueueIfIdle()
            return
        }

        let item = session.queue.remove(at: idx)
        let normalUserTurn = session.normalQueuedTurnIDs.remove(item.id) != nil
        let recordedUserMessageID = session.normalQueuedTurnUserMessageIDs.removeValue(forKey: item.id)
        if session.canSteerRunningTurn {
            steerRunningTurn(
                blocks: item.blocks, delegatedSource: item.delegatedSource,
                recordUserPrompt: !item.transcriptRecorded, normalUserTurn: normalUserTurn,
                recordedUserMessageID: recordedUserMessageID, draft: item.draft,
                onDispatchRegistered: queuedPromptDispatchRegistration(for: item.id),
                onPromptFinished: nil, recoveryQueueItem: (item, idx))
            return
        }
        if item.backgroundTaskWake != nil {
            session.queue.insert(item, at: min(idx, session.queue.count))
        }
        persistQueue()
        steer(
            blocks: item.blocks,
            delegatedSource: item.delegatedSource,
            recordUserPrompt: !item.transcriptRecorded,
            normalUserTurn: normalUserTurn,
            recordedUserMessageID: recordedUserMessageID,
            // See the matching comment in `flushQueueIfIdle`: the raw
            // optional, not the heuristic `restorableDraft`.
            draft: item.draft,
            recoveryQueueItemID: item.backgroundTaskWake == nil ? nil : item.id,
            onDispatchRegistered: queuedPromptDispatchRegistration(for: item.id)
        )
    }

    @discardableResult
    private func sendPendingQueueForceSendsAfterPersistence() -> Bool {
        guard session.pendingQueuePersistenceCount == 0,
              !pendingQueueForceSendsAfterPersistence.isEmpty
        else { return false }
        let itemIds = pendingQueueForceSendsAfterPersistence
        pendingQueueForceSendsAfterPersistence.removeAll()
        var forced = false
        for itemId in itemIds.reversed() {
            if session.queue.first(where: { $0.id == itemId })?.deliveryUncertain == true {
                _ = session.retryQueueItem(id: itemId)
            }
            forced = session.forceQueueItem(id: itemId) || forced
        }
        guard forced else { return false }
        persistQueue()
        flushQueueIfIdle()
        return true
    }

    /// Inject into the running turn where supported, otherwise interrupt and
    /// send a fresh turn. The fallback removes an ordinary cancelled queue
    /// head; a background wake stays until cancellation is durably confirmed.
    /// Every other pending item keeps its position.
    func steer(
        blocks: [ACPContentBlock],
        delegatedSource: ACPDelegatedPromptSource? = nil,
        recordUserPrompt: Bool = true,
        normalUserTurn: Bool = true,
        recordedUserMessageID: UUID? = nil,
        draft: ACPComposerDraft? = nil,
        recoveryQueueItemID: UUID? = nil,
        onDispatchRegistered: (@Sendable () -> Void)? = nil,
        onPromptFinished: (@MainActor (_ succeeded: Bool) -> Void)? = nil
    ) {
        if session.canSteerRunningTurn {
            steerRunningTurn(
                blocks: blocks, delegatedSource: delegatedSource,
                recordUserPrompt: recordUserPrompt, normalUserTurn: normalUserTurn,
                recordedUserMessageID: recordedUserMessageID, draft: draft,
                onDispatchRegistered: onDispatchRegistered, onPromptFinished: onPromptFinished)
            return
        }
        turnPublicationGeneration += 1
        discardPendingSuccessfulTurn("steer")
        flushPendingIncomingUpdates(flushQueueWhenBoundaryReady: false)
        let interruptedBackgroundWake = session.queue.first.map {
            $0.status == .sending && $0.backgroundTaskWake != nil
        } ?? false
        session.queue.removeAll { $0.status == .sending && $0.backgroundTaskWake == nil }
        persistQueue()
        let interruptedPromptTask = activePromptID == nil ? nil : latestPromptTask
        // Invalidate the in-flight prompt NOW (before awaiting userCancel)
        // so its completion can't race the redirect during the cancel
        // round-trip. Without this, a slow `session/cancel` leaves the
        // old `activePromptID` valid; the cancelled RPC's completion
        // would then flip state to .idle, opening a window where the
        // composer could accept another submit before the redirect's
        // `sendNow` installs a new one.
        if let promptID = activePromptID {
            cancelledPromptIDs.insert(promptID)
            activePromptID = nil
        }
        // Suppress queue flushing until the redirect is installed: while
        // userCancel awaits the cancel notification, userCancel's own
        // trailing flushQueueIfIdle would otherwise be free to dispatch a
        // pending head ahead of the steer's replacement prompt.
        steerInProgress = true

        Task { [weak self, onDispatchRegistered, onPromptFinished] in
            guard let self else {
                await MainActor.run {
                    onDispatchRegistered?()
                    onPromptFinished?(false)
                }
                return
            }
            await self.userCancel()
            guard !self.stopped, self.isConnectionCurrent() else {
                await MainActor.run {
                    self.steerInProgress = false
                    self.pendingForceSendQueuedItemID = nil
                    onDispatchRegistered?()
                    onPromptFinished?(false)
                }
                return
            }
            // The redirect still owns prompt work while the cancelled RPC
            // settles. Keep cleanup observers informed before waiting on it.
            self.onPromptWorkChanged?()
            await interruptedPromptTask?.value
            if interruptedBackgroundWake {
                await self.flushPersistence()
            }
            await MainActor.run {
                // Detach and restart both invalidate this runner, but a
                // replacement may already have put the shared session back
                // in `.ready`. Check runner identity as well as visible
                // state before sending through the old connection.
                guard !self.stopped,
                      self.isConnectionCurrent(),
                      self.session.agentState == .ready
                else {
                    self.steerInProgress = false
                    self.pendingForceSendQueuedItemID = nil
                    onDispatchRegistered?()
                    onPromptFinished?(false)
                    return
                }
                if let recoveryQueueItemID {
                    guard let index = self.session.queue.firstIndex(where: { $0.id == recoveryQueueItemID }) else {
                        self.steerInProgress = false
                        onDispatchRegistered?()
                        onPromptFinished?(false)
                        return
                    }
                    var head = self.session.queue.remove(at: index)
                    head.status = .pending
                    head.lastError = nil
                    head.deliveryUncertain = false
                    self.session.queue.insert(head, at: 0)
                    guard let brokerOperationKey = self.session.markQueueHeadSending() else {
                        self.steerInProgress = false
                        onDispatchRegistered?()
                        onPromptFinished?(false)
                        return
                    }
                    self.sendQueuedHead(head, brokerOperationKey: brokerOperationKey,
                                        onPromptFinished: onPromptFinished,
                                        onDispatchSettled: { [weak self] in
                                            onDispatchRegistered?()
                                            guard let self else { return }
                                            self.steerInProgress = false
                                            if let id = self.pendingForceSendQueuedItemID {
                                                self.pendingForceSendQueuedItemID = nil
                                                self.forceSendQueuedItem(id: id)
                                            }
                                            self.flushQueueIfIdle()
                                        })
                    return
                }
                self.sendNow(
                    blocks: blocks,
                    queuedItemId: nil,
                    delegatedSource: delegatedSource,
                    recordUserPrompt: recordUserPrompt,
                    normalUserTurn: normalUserTurn,
                    recordedUserMessageID: recordedUserMessageID,
                    draft: draft,
                    onDispatchRegistered: onDispatchRegistered,
                    onPromptFinished: onPromptFinished
                )
                self.steerInProgress = false
                if let queuedID = self.pendingForceSendQueuedItemID {
                    self.pendingForceSendQueuedItemID = nil
                    self.forceSendQueuedItem(id: queuedID)
                }
            }
        }
    }

    /// The extension acknowledges delivery; the original prompt still owns
    /// completion. Preserve its tool state and every item in the queue.
    private func steerRunningTurn(
        blocks: [ACPContentBlock],
        delegatedSource: ACPDelegatedPromptSource?,
        recordUserPrompt: Bool,
        normalUserTurn: Bool,
        recordedUserMessageID: UUID?,
        draft: ACPComposerDraft?,
        onDispatchRegistered: (@Sendable () -> Void)?,
        onPromptFinished: (@MainActor (Bool) -> Void)?,
        recoveryQueueItem: (item: QueuedPrompt, index: Int)? = nil
    ) {
        let dispatchHandoff = onDispatchRegistered.map(ACPRequestHandoff.init)
        // A force-steered item may keep provenance from an earlier failed
        // send; that dispatch does not describe this steered delivery.
        let durableQueueItem = recoveryQueueItem.map { recovery in
            var item = recovery.item
            item.dispatchedBrokerGeneration = nil
            return (item: item, index: recovery.index)
        } ?? (
            item: QueuedPrompt(blocks: blocks, draft: draft, delegatedSource: delegatedSource,
                               transcriptRecorded: !recordUserPrompt),
            index: session.queue.count)
        var pendingDelivery = durableQueueItem.item
        pendingDelivery.status = .sending
        pendingDelivery.lastError = "Follow-up delivery is awaiting confirmation. Retry if it cannot be confirmed."
        pendingDelivery.markDeliveryUncertain()
        session.queue.insert(pendingDelivery, at: min(durableQueueItem.index, session.queue.count))
        if normalUserTurn { session.normalQueuedTurnIDs.insert(pendingDelivery.id) }
        let initialRecoveryPersistence = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await withCheckedContinuation { continuation in
                self.persistQueue(completion: { continuation.resume(returning: $0) })
            }
        }
        nativeSteeringGeneration += 1
        nativeSteeringQueueItemID = durableQueueItem.item.id
        let generation = nativeSteeringGeneration
        let originalPromptTask = activePromptID == nil ? nil : latestPromptTask
        let hadOwnedPrompt = activePromptID != nil
        nativeSteeringInProgress = true
        steerInProgress = true
        steeringSawIdle = lastSteeringThreadStatus == "idle" || (!hadOwnedPrompt && !detachedSteeringTurn)
        steeringSawActive = detachedSteeringTurn && lastSteeringThreadStatus == "active"
        steeringSawActiveAfterIdle = false
        turnPublicationGeneration += 1
        discardPendingSuccessfulTurn("steerRunningTurn")
        onPromptWorkChanged?()

        Task { [weak self] in
            var recoveryPersisted = await initialRecoveryPersistence.value
            guard let self else { dispatchHandoff?.fire()
            onPromptFinished?(recoveryPersisted)
            return }
            var recordedMessageID = recordedUserMessageID
            var recordedMessagePersisted = durableQueueItem.item.transcriptRecorded
            var ownedContinuationStarted = false
            var steeringAcknowledgement: ACPDurableConsumptionAcknowledgement?
            let finishPrompt: @MainActor (Bool) -> Void = { [weak self] succeeded in
                if let self, !self.stopped, self.isConnectionCurrent() {
                    if succeeded {
                        if let wake = self.session.queue.first(where: {
                            $0.id == durableQueueItem.item.id && $0.backgroundTaskWake != nil
                        }) {
                            self.session.normalQueuedTurnIDs.remove(wake.id)
                            self.session.normalQueuedTurnUserMessageIDs.removeValue(forKey: wake.id)
                            self.persistBackgroundWakeAndQueue(
                                rows: self.markBackgroundWakesDelivered(for: wake), consuming: wake,
                                acknowledging: steeringAcknowledgement)
                            onPromptFinished?(true)
                            return
                        }
                        self.session.queue.removeAll { $0.id == durableQueueItem.item.id }
                        self.session.normalQueuedTurnIDs.remove(durableQueueItem.item.id)
                        self.session.normalQueuedTurnUserMessageIDs.removeValue(forKey: durableQueueItem.item.id)
                    } else if !ownedContinuationStarted {
                        var item = durableQueueItem.item
                        item.transcriptRecorded = recordedMessagePersisted
                        item.status = .pending
                        item.lastError = "Follow-up delivery was not confirmed. Retry to send it again."
                        item.markDeliveryUncertain()
                        if let index = self.session.queue.firstIndex(where: { $0.id == item.id }) {
                            self.session.queue[index] = item
                        } else {
                            self.session.queue.insert(item, at: min(durableQueueItem.index, self.session.queue.count))
                        }
                        if normalUserTurn {
                            self.session.normalQueuedTurnIDs.insert(item.id)
                            self.session.normalQueuedTurnUserMessageIDs[item.id] = recordedMessagePersisted ? recordedMessageID : nil
                        }
                    }
                    // Submission is accepted if its content is retained for
                    // retry; restoring the draft as well would duplicate it.
                    let accepted = succeeded || self.session.queue.contains { $0.id == durableQueueItem.item.id }
                    self.persistQueue(acknowledging: steeringAcknowledgement, retainOnFailure: true, completion: { persisted in
                        if !persisted, self.isConnectionCurrent(), !self.stopped {
                            self.session.lastError = "Could not save follow-up delivery confirmation."
                        }
                        if succeeded, persisted { self.flushQueueIfIdle() }
                        onPromptFinished?(accepted)
                    })
                } else {
                    // A replacement owns the persisted recovery item. Keep
                    // its submitted draft cleared without touching its state.
                    onPromptFinished?(succeeded || recoveryPersisted)
                }
            }
            do {
                guard await self.hasConfirmedLeaseForSideEffect(),
                      !self.stopped, self.isConnectionCurrent(),
                      self.nativeSteeringGeneration == generation
                else { throw CancellationError() }
                let symbolExpansion = await ACPSymbolReference.expansion(
                    of: blocks, worktreeRoot: URL(fileURLWithPath: self.worktreePath),
                    embeddedContext: self.session.promptCapabilities.embeddedContext)
                var wireBlocks = ACPSymbolReference.replacingReferences(
                    in: await self.expandingSessionReferences(Self.hydrate(
                        blocks, promptCapabilities: self.session.promptCapabilities,
                        worktreePath: self.worktreePath)),
                    with: symbolExpansion)
                guard await self.hasConfirmedLeaseForSideEffect(),
                      !self.stopped, self.isConnectionCurrent(),
                      self.nativeSteeringGeneration == generation
                else { throw CancellationError() }
                self.flushPendingIncomingUpdates(flushQueueWhenBoundaryReady: false)
                let boundaryCrossingBefore = self.session.allowsStreamingBoundaryCrossing
                if recordUserPrompt {
                    self.flushStreamingPersist()
                    let before = self.session.transcript.messages.count
                    let titleBefore = self.session.title
                    let titleSourceBefore = self.session.titleSource
                    let completedBoundaryBefore = self.session.transcript.completedOutputBoundaryMessageIds
                    if !self.session.followsTranscriptTail {
                        self.session.followsTranscriptTail = true
                        self.onResumeTranscriptTail?()
                    }
                    let promptText = Self.textPreview(of: blocks)
                    let userMessageID = self.session.recordUserPrompt(
                        text: promptText,
                        attachments: ACPSymbolReference.attachingSnapshots(
                            to: Self.attachments(of: blocks, draft: draft), from: symbolExpansion),
                        pastedSpans: draft?.pastedTextSpans(matching: promptText) ?? [],
                        delegatedSource: delegatedSource)
                    recordedMessageID = userMessageID
                    let recordedTitle = self.session.title
                    let userIndex = self.session.transcript.messages.count - 1
                    var boundaryMetadata: [(text: StreamingText, metadata: AnyCodable?)] = []
                    self.session.allowsStreamingBoundaryCrossing = true
                    let boundaryDirty = self.session.beginSteeringOutputBoundary(beforeUserMessageAt: userIndex) { text in
                        boundaryMetadata.append((text, text.metadata))
                    }
                    // Defer incoming mutations until commit/rollback so they
                    // cannot persist a provisional row or boundary separately.
                    self.steeringRowPersistencePending = true
                    guard await self.persistSteeringUserRow(from: before, userMessageID: userMessageID,
                                                           boundaryDirty: boundaryDirty, queueItemID: durableQueueItem.item.id) else {
                        // Invalidation cancels delivery, not rollback of this
                        // exact provisional row. A replacement connection owns
                        // its own rows and remains fenced out here.
                        if self.isConnectionCurrent(),
                           let index = self.session.transcript.messages.firstIndex(where: {
                               if case .user(let id, _, _, _, _, _) = $0 { return id == recordedMessageID }
                               return false
                           }) {
                            boundaryMetadata.forEach { $0.text.restoreMetadata($0.metadata) }
                            self.session.allowsStreamingBoundaryCrossing = boundaryCrossingBefore
                            self.session.transcript.messages.remove(at: index)
                            // Replay output materialized before this user row
                            // belongs to the preceding turn, even if steering
                            // persistence failed. Save it independently.
                            self.persistFromIndex(before)
                            self.session.transcript.lastContentTouchIndex = nil
                            self.session.transcript.completedOutputBoundaryMessageIds = completedBoundaryBefore
                            if self.session.title == recordedTitle, self.session.titleSource == .fallback {
                                self.session.title = titleBefore
                                self.session.titleSource = titleSourceBefore
                            }
                        }
                        self.steeringRowPersistencePending = false
                        self.flushPendingIncomingUpdates(flushQueueWhenBoundaryReady: false, treatBufferedUpdatesAsPromptOwned: self.stopped)
                        recordedMessageID = nil
                        throw ACPClientError.jsonrpc(.init(code: -32000, message: "Could not save the follow-up; it was not sent.", data: nil))
                    }
                    recordedMessagePersisted = true
                    recoveryPersisted = true
                    self.steeringRowPersistencePending = false
                    self.flushPendingIncomingUpdates(flushQueueWhenBoundaryReady: false, treatBufferedUpdatesAsPromptOwned: self.stopped)
                    guard !self.stopped, self.isConnectionCurrent(), self.nativeSteeringGeneration == generation
                    else { throw CancellationError() }
                    if self.session.title != titleBefore { self.persistFallbackTitleIfStoredPlaceholder() }
                } else {
                    if let recordedMessageID,
                       let index = self.session.replaceSymbolSnapshots(inUserMessage: recordedMessageID, from: symbolExpansion) {
                        self.persistIndices([index])
                    }
                    self.session.allowsStreamingBoundaryCrossing = true
                    var boundaryMetadata: [(text: StreamingText, metadata: AnyCodable?)] = []
                    let dirty = self.session.beginSteeringOutputBoundary(followingUserCount: 0) { text in
                        boundaryMetadata.append((text, text.metadata))
                    }
                    self.steeringRowPersistencePending = true
                    let persisted = await withCheckedContinuation { continuation in
                        if !self.persistIndices(dirty, completion: { continuation.resume(returning: $0) }) {
                            continuation.resume(returning: false)
                        }
                    }
                    if !persisted, self.isConnectionCurrent() {
                        boundaryMetadata.forEach { $0.text.restoreMetadata($0.metadata) }
                        self.session.allowsStreamingBoundaryCrossing = boundaryCrossingBefore
                    }
                    self.steeringRowPersistencePending = false
                    self.flushPendingIncomingUpdates(flushQueueWhenBoundaryReady: false, treatBufferedUpdatesAsPromptOwned: self.stopped)
                    guard persisted else {
                        throw ACPClientError.jsonrpc(.init(code: -32000, message: "Could not save the follow-up boundary; it was not sent.", data: nil))
                    }
                }
                guard await self.hasConfirmedLeaseForSideEffect(),
                      !self.stopped, self.isConnectionCurrent(),
                      self.nativeSteeringGeneration == generation
                else { throw CancellationError() }
                if recordUserPrompt, let messageID = recordedMessageID,
                   let checkpointID = await self.onCheckpointCapture?(
                       Self.textPreview(of: blocks), !Self.attachments(of: blocks).isEmpty) {
                    guard !self.stopped, self.isConnectionCurrent(),
                          self.nativeSteeringGeneration == generation
                    else { throw CancellationError() }
                    if self.session.attachCheckpoint(checkpointID, toUserMessage: messageID),
                       let index = self.session.transcript.messages.firstIndex(where: {
                           if case .user(let id, _, _, _, _, _) = $0 { return id == messageID }
                           return false
                       }) {
                        self.persistIndices([index])
                    }
                }
                guard await self.hasConfirmedLeaseForSideEffect(),
                      !self.stopped, self.isConnectionCurrent(),
                      self.nativeSteeringGeneration == generation
                else { throw CancellationError() }
                // Match normal prompts' per-dispatch context, while keeping
                // private context out of the recorded user message.
                let context = await self.pluginContext?(self.sessionId) ?? []
                wireBlocks.insert(contentsOf: context.map { .text($0) }, at: 0)
                if self.session.readOnlyRestricted {
                    wireBlocks.insert(.text(ACPSideQuestion.guidance), at: context.count)
                }
                guard await self.hasConfirmedLeaseForSideEffect(),
                      !self.stopped, self.isConnectionCurrent(),
                      self.nativeSteeringGeneration == generation
                else { throw CancellationError() }
                guard let queueIndex = self.session.queue.firstIndex(where: { $0.id == durableQueueItem.item.id })
                else { throw CancellationError() }
                self.session.queue[queueIndex].transcriptRecorded = pendingDelivery.transcriptRecorded || recordedMessageID != nil
                if normalUserTurn { self.session.normalQueuedTurnUserMessageIDs[durableQueueItem.item.id] = recordedMessageID }
                let persisted = await withCheckedContinuation { continuation in
                    self.persistQueue(completion: { continuation.resume(returning: $0) })
                }
                guard persisted else {
                    throw ACPClientError.jsonrpc(.init(code: -32000, message: "Could not save the follow-up; it was not sent.", data: nil))
                }
                recoveryPersisted = true
                guard await self.hasConfirmedLeaseForSideEffect(),
                      !self.stopped, self.isConnectionCurrent(),
                      self.nativeSteeringGeneration == generation
                else { throw CancellationError() }
                self.session.expectSymbolExpansionEchoes(symbolExpansion.sentBlocks)
                let result = try await self.connection.steer(
                    sessionId: self.session.remoteSessionId ?? self.sessionId, blocks: wireBlocks,
                    brokerOperationKey: durableQueueItem.item.steeringBrokerOperationKey)
                steeringAcknowledgement = result.acknowledgement
                guard await self.hasConfirmedLeaseForSideEffect(),
                      !self.stopped, self.isConnectionCurrent(),
                      self.nativeSteeringGeneration == generation
                else { throw CancellationError() }
                self.flushPendingIncomingUpdates(flushQueueWhenBoundaryReady: false)
                switch try result.outcome.get() {
                case .injected:
                    dispatchHandoff?.fire()
                    self.session.lastError = nil
                    finishPrompt(true)
                    self.finishNativeSteering(generation: generation)
                case .startedNewTurn:
                    dispatchHandoff?.fire()
                    guard self.session.supportsCodexSteeringCompletion || self.lastSteeringThreadStatus != nil else {
                        let message = "The agent started a follow-up without a supported completion signal. Stop or restart before continuing."
                        self.session.supportsSteering = false
                        self.session.agentState = .failed(message)
                        self.session.transcript.streamingState = .awaitingInput
                        throw ACPClientError.jsonrpc(.init(code: -32000, message: message, data: nil))
                    }
                    // Codex's legacy idle fallback starts a detached prompt.
                    // Hold the queue until its thread status reports completion,
                    // including status received before this acknowledgement.
                    self.detachedSteeringTurn = true
                    self.steeringSawActive = self.steeringSawActiveAfterIdle
                    self.steeringSawIdle = true
                    self.session.allowsStreamingBoundaryCrossing = true
                    self.session.transcript.streamingState = .streaming
                    self.session.lastError = nil
                    finishPrompt(true)
                    self.finishNativeSteering(generation: generation)
                case .promptRequired:
                    // No content was consumed. Install an owned continuation
                    // before releasing the queue, without recording another row.
                    await originalPromptTask?.value
                    guard await self.hasConfirmedLeaseForSideEffect(),
                          !self.stopped, self.isConnectionCurrent(),
                          self.nativeSteeringGeneration == generation
                    else { throw CancellationError() }
                    self.detachedSteeringTurn = false
                    // An owned continuation uses the queue's normal failure
                    // handling, which retains its head before releasing output.
                    ownedContinuationStarted = true
                    self.session.queue.removeAll { $0.id == durableQueueItem.item.id }
                    var continuationItem = durableQueueItem.item
                    continuationItem.status = .pending
                    continuationItem.transcriptRecorded = continuationItem.transcriptRecorded || recordedMessageID != nil
                    continuationItem.lastError = nil
                    continuationItem.deliveryUncertain = false
                    self.session.queue.insert(continuationItem, at: 0)
                    if normalUserTurn {
                        self.session.normalQueuedTurnIDs.insert(continuationItem.id)
                        self.session.normalQueuedTurnUserMessageIDs[continuationItem.id] = recordedMessageID
                    }
                    guard let brokerOperationKey = self.session.markQueueHeadSending() else {
                        throw CancellationError()
                    }
                    self.sendQueuedHead(
                        continuationItem, brokerOperationKey: brokerOperationKey,
                        onPromptFinished: finishPrompt,
                        onDispatchSettled: { [weak self] in
                            dispatchHandoff?.fire()
                            self?.finishNativeSteering(generation: generation)
                        })
                case .failed:
                    throw ACPClientError.jsonrpc(.init(
                        code: -32000, message: "The agent could not inject the follow-up.", data: nil))
                }
            } catch {
                if !self.stopped, self.isConnectionCurrent(), self.nativeSteeringGeneration == generation {
                    if case ACPClientError.jsonrpc(let rpcError) = error, rpcError.code == -32601 {
                        // Method-not-found proves the content was not consumed.
                        self.session.supportsSteering = false
                        self.nativeSteeringInProgress = false
                        self.steerInProgress = false
                        // Preserve recovery through fallback cancellation,
                        // which discards the interrupted sending queue head.
                        if let index = self.session.queue.firstIndex(where: { $0.id == durableQueueItem.item.id }) {
                            self.session.queue[index].status = .pending
                            self.persistQueue()
                        }
                        ownedContinuationStarted = true
                        self.steer(
                            blocks: blocks, delegatedSource: delegatedSource,
                            recordUserPrompt: recordedMessageID == nil && recordUserPrompt,
                            normalUserTurn: normalUserTurn, recordedUserMessageID: recordedMessageID,
                            draft: draft, recoveryQueueItemID: durableQueueItem.item.id,
                            onDispatchRegistered: { dispatchHandoff?.fire() }, onPromptFinished: finishPrompt)
                        return
                    }
                    dispatchHandoff?.fire()
                    if !(error is CancellationError) {
                        self.session.lastError = "Follow-up failed: \(error.localizedDescription)"
                    }
                    // Restore a forced queue item before releasing the barrier;
                    // it must not be dropped or automatically sent again.
                    finishPrompt(false)
                    self.finishNativeSteering(generation: generation)
                    return
                }
                // An ambiguous failure may have consumed the content. Restore
                // the caller's draft without blindly sending it again.
                dispatchHandoff?.fire()
                finishPrompt(false)
            }
        }
    }

    private func persistSteeringUserRow(from index: Int, userMessageID: UUID, boundaryDirty: Set<Int>, queueItemID: UUID) async -> Bool {
        guard holdsLeaseForWrite(),
              let userIndex = session.transcript.messages.firstIndex(where: {
                  if case .user(let id, _, _, _, _, _) = $0 { return id == userMessageID }
                  return false
              }), userIndex >= index,
              let queueIndex = session.queue.firstIndex(where: { $0.id == queueItemID })
        else { return false }
        // Recording the prompt may first materialize held replay candidates.
        // Persist them and the identified user row in the same transaction.
        let rows: [ACPStoredMessage]
        do {
            rows = try boundaryDirty.union(index...userIndex).sorted().map { index in
                let message = session.transcript.messages[index]
                return ACPStoredMessage(id: messageRowID(index), sessionId: self.sessionId, kind: message.kind,
                                        seq: Int64(index), payload: try ACPMessageCodec.encode(message),
                                        createdAt: createdAt(forMessageAt: index))
            }
        } catch { return false }
        session.queue[queueIndex].transcriptRecorded = true
        let queueSnapshot = queueSnapshotForPersistence()
        let sessionId = sessionId
        let fence = leaseFenceProvider()
        session.pendingQueuePersistenceCount += 1
        return await withCheckedContinuation { continuation in
            enqueuePersistence({ persistence in
                let items = await queueSnapshot()
                return try await persistence.persistMessagesAndQueue(rows, sessionId: sessionId, items: items, fence: fence)
            }, completion: { persisted in
                self.session.pendingQueuePersistenceCount -= 1
                if persisted == true { self.commitPersistedMessageRows(rows) }
                continuation.resume(returning: persisted == true)
            })
        }
    }

    private func invalidateNativeSteering() {
        if !stopped, isConnectionCurrent(), holdsLeaseForWrite(),
           let id = nativeSteeringQueueItemID,
           let index = session.queue.firstIndex(where: { $0.id == id }),
           session.queue[index].status == .sending, session.queue[index].deliveryUncertain {
            // The invalidated task no longer owns recovery. Keep it actionable
            // even when an earlier queued prompt occupies the head.
            session.queue[index].status = .pending
            session.queue[index].lastError = "Follow-up delivery was interrupted. Retry if it cannot be confirmed."
            persistQueue()
        }
        nativeSteeringQueueItemID = nil
        nativeSteeringGeneration += 1
        if nativeSteeringInProgress { steerInProgress = false }
        nativeSteeringInProgress = false
        detachedSteeringTurn = false
    }

    private func finishNativeSteering(generation: Int) {
        guard nativeSteeringGeneration == generation else { return }
        nativeSteeringQueueItemID = nil
        nativeSteeringInProgress = false
        finishDetachedSteeringIfReady()
        steerInProgress = false
        applyPendingCompletedOutputBoundaryIfReady(flushQueueWhenReady: false)
        if let id = pendingForceSendQueuedItemID {
            pendingForceSendQueuedItemID = nil
            forceSendQueuedItem(id: id)
        }
        flushQueueIfIdle()
        onPromptWorkChanged?()
    }

    private func observeSteeringThreadStatus(_ info: ACPSessionInfoUpdate) {
        guard let root = info.metadata?.value as? [String: AnyCodable],
              let codex = root["codex"]?.value as? [String: AnyCodable],
              let status = codex["threadStatus"]?.value as? [String: AnyCodable],
              let type = status["type"]?.value as? String,
              ["active", "idle", "systemError"].contains(type)
        else { return }
        lastSteeringThreadStatus = type
        if nativeSteeringInProgress || detachedSteeringTurn {
            if type == "active", steeringSawIdle {
                steeringSawActive = true
                steeringSawActiveAfterIdle = true
            }
            if type == "idle" || type == "systemError" { steeringSawIdle = true }
            finishDetachedSteeringIfReady()
        }
    }

    private func finishDetachedSteeringIfReady() {
        guard detachedSteeringTurn, !nativeSteeringInProgress, steeringSawActive,
              lastSteeringThreadStatus == "idle" || lastSteeringThreadStatus == "systemError"
        else { return }
        detachedSteeringTurn = false
        if lastSteeringThreadStatus == "systemError" { session.lastError = "Steered turn failed." }
        deferCompletedOutputBoundaryUntilUpdatesDrain()
        onPromptWorkChanged?()
    }

    var hasRetainedCleanupPromptWork: Bool {
        steerInProgress
            || detachedSteeringTurn
            || !deferredQueueAcknowledgements.isEmpty
            || activePromptID != nil
            || session.transcript.streamingState != .idle
            || (session.pendingQueuePersistenceCount > 0 && !session.queue.isEmpty)
    }

    var hasRetainedCleanupSteerWork: Bool {
        steerInProgress || detachedSteeringTurn
    }

    var hasRetainedCleanupForkBarrierWork: Bool {
        nativeForkBarrierActive
    }

    /// Direct prompt RPC path. `queuedItemId` is set when called by the
    /// flusher; nil when called from the user-typed-and-submitted path.
    /// `onPromptFinished` fires when the active turn ends (success or
    /// cancel/failure) and lets the composer reconcile its persisted
    /// draft. Stale completions (steer cancelled us; another sendNow
    /// took ownership) skip the callback so the composer stays in sync
    /// with the SUCCESSOR turn only.
    func sendNow(
        blocks: [ACPContentBlock],
        queuedItemId: UUID?,
        delegatedSource: ACPDelegatedPromptSource? = nil,
        brokerOperationKey: String? = nil,
        recordUserPrompt: Bool = true,
        normalUserTurn: Bool = true,
        recordedUserMessageID: UUID? = nil,
        draft: ACPComposerDraft? = nil,
        onDispatchRegistered: (@Sendable () -> Void)? = nil,
        beforeRequestHandoff: (@Sendable (ACPBrokerGeneration?) async throws -> Void)? = nil,
        onRequestHandoffDidOccur: (@Sendable () throws -> Void)? = nil,
        onPromptFinished: (@MainActor (_ succeeded: Bool) -> Void)? = nil
    ) {
        discardPendingSuccessfulTurn("sendNow")
        flushPendingIncomingUpdates()
        session.clearRetryStatus()
        let promptID = session.allocatePromptID()
        // Register ownership SYNCHRONOUSLY, before the Task spawn. Without
        // this, `detach.invalidateActivePrompt()` (or another concurrent
        // cancel) could land between the increment above and the Task's
        // first `MainActor.run`, see no active prompt to invalidate, and
        // the Task would then run normally, fail on `connection.shutdown`,
        // and persist `lastError` on the queue head — defeating the
        // detach-clears-cleanly fix from the previous commit.
        activePromptID = promptID
        let connectionIsCurrent = isConnectionCurrent
        let queueDispatchHandoffTracker = self.queueDispatchHandoffTracker
        latestPromptTask = Task {
            [weak self, onDispatchRegistered, beforeRequestHandoff, onRequestHandoffDidOccur,
             onPromptFinished, connectionIsCurrent, queuedItemId, queueDispatchHandoffTracker] in
            guard let self else {
                await MainActor.run {
                    onDispatchRegistered?()
                    if connectionIsCurrent() {
                        onPromptFinished?(false)
                    }
                }
                return
            }
            defer {
                if let queuedItemId {
                    queueDispatchHandoffTracker.finish(queuedItemId)
                }
            }
            let abandonUnrecordedPrompt = { @MainActor in
                // Losing the lease stands this runner down inside the
                // check itself, so `stopped` is already true by the time
                // we get here. That teardown belongs to THIS prompt, not a
                // successor: when the connection still belongs to this
                // attempt and no newer prompt has taken over, the
                // submitter must learn the send failed — otherwise the
                // composer and remote gateways wait forever on a
                // completion that never fires. A replaced connection or a
                // newer active prompt keeps the callback (its successor
                // turn owns the outcome).
                let canFinishPrompt = self.isConnectionCurrent() &&
                    !self.steerInProgress &&
                    (self.activePromptID == nil || self.activePromptID == promptID)
                if self.activePromptID == promptID {
                    self.activePromptID = nil
                }
                self.cancelledPromptIDs.remove(promptID)
                onDispatchRegistered?()
                if canFinishPrompt {
                    onPromptFinished?(false)
                }
            }
            guard await self.hasConfirmedLeaseForSideEffect() else {
                await abandonUnrecordedPrompt()
                return
            }
            let symbolExpansion = await ACPSymbolReference.expansion(
                of: blocks, worktreeRoot: URL(fileURLWithPath: self.worktreePath),
                embeddedContext: self.session.promptCapabilities.embeddedContext)
            // Resolution suspends for file reads, so a takeover can land
            // meanwhile. Confirm the lease again before recording anything.
            guard await self.hasConfirmedLeaseForSideEffect() else {
                await abandonUnrecordedPrompt()
                return
            }
            let checkpointPrompt = Self.textPreview(of: blocks)
            let checkpointHasAttachments = !Self.attachments(of: blocks).isEmpty
            let promptRecording = await MainActor.run { () -> (proceeded: Bool, messageID: UUID?) in
                // Stopped, or its connection replaced, while symbol mentions
                // resolved: this prompt is over and must not be recorded.
                if self.activePromptID == promptID, self.stopped || !self.isConnectionCurrent() {
                    abandonUnrecordedPrompt()
                    return (false, nil)
                }
                // If we were cancelled while this Task was being scheduled,
                // exit without touching transcript or state. The connection
                // may already be torn down by detach, and recording the
                // user prompt now would leak transcript writes into a
                // detached session.
                if self.activePromptID != promptID {
                    self.cancelledPromptIDs.remove(promptID)
                    onDispatchRegistered?()
                    if self.isConnectionCurrent(), !self.stopped,
                       !self.steerInProgress, self.activePromptID == nil {
                        onPromptFinished?(false)
                    }
                    return (false, nil)
                }
                // A queued prompt whose turn already started (its user prompt
                // is recorded) keeps that start: this is a resend of the same
                // turn, e.g. after a relaunch re-attached to a broker that
                // kept it running. Reporting the resend time instead would
                // treat a delegated child's mid-turn report as stale.
                let queuedTurnStartedAt = queuedItemId.flatMap { qid in
                    self.session.queue.first(where: { $0.id == qid && $0.transcriptRecorded })?.turnStartedAt
                }
                self.activePromptStartedAt = queuedTurnStartedAt ?? Int64(Date().timeIntervalSince1970 * 1000)
                self.activePromptStreamStart = self.connection.client.yieldedUpdateCount
                self.activePromptDelegatedSource = delegatedSource
                // Captured before the user prompt is recorded below, so the
                // floor points at this turn's own first transcript entry.
                self.activePromptTranscriptFloor = self.session.transcript.messages.count
                // Re-allow streaming boundary crossings now that we are inside
                // the Task and have confirmed this prompt is still active. The
                // RPC is sent below, so any agent chunk that follows is genuine
                // new output — N+1 bubble creation is correct from here on.
                self.session.allowsStreamingBoundaryCrossing = true
                // Record the user prompt BEFORE awaiting `session/prompt`.
                // The agent streams `session/update` notifications through
                // `incomingUpdates` while the RPC is in flight, so if we
                // recorded after the await an agent_message_chunk could
                // land first and the transcript would render answer-
                // before-question. Skip for a queued retry whose prompt
                // is already in the transcript from the previous attempt.
                let shouldRecord: Bool = {
                    guard recordUserPrompt else { return false }
                    if let qid = queuedItemId,
                       let idx = self.session.queue.firstIndex(where: { $0.id == qid }),
                       self.session.queue[idx].transcriptRecorded {
                        return false
                    }
                    return true
                }()
                if shouldRecord {
                    let before = self.session.transcript.messages.count
                    let titleBefore = self.session.title
                    if !self.session.followsTranscriptTail {
                        self.session.followsTranscriptTail = true
                        self.onResumeTranscriptTail?()
                    }
                    let promptText = Self.textPreview(of: blocks)
                    let messageID = self.session.recordUserPrompt(text: promptText,
                                                                  attachments: ACPSymbolReference.attachingSnapshots(
                                                                      to: Self.attachments(of: blocks, draft: draft),
                                                                      from: symbolExpansion),
                                                                  pastedSpans: draft?.pastedTextSpans(matching: promptText) ?? [],
                                                                  delegatedSource: delegatedSource)
                    self.persistFromIndex(before)
                    if self.session.title != titleBefore {
                        self.persistFallbackTitleIfStoredPlaceholder()
                    }
                    if !self.localTitleAttempted, delegatedSource == nil,
                       (!self.session.restoredFromPersistence || before == 0),
                       !self.session.transcript.messages.dropLast().contains(where: {
                           if case .user(_, _, let text, _, let source, _) = $0, source == nil {
                               return ACPLocalTitleGenerator.candidate(from: text) != nil
                           }
                           return false
                       }) {
                        self.generateLocalTitle(for: Self.textPreview(of: blocks))
                    }
                    if let qid = queuedItemId,
                       let idx = self.session.queue.firstIndex(where: { $0.id == qid }) {
                        self.session.queue[idx].transcriptRecorded = true
                        self.session.queue[idx].turnStartedAt = self.activePromptStartedAt
                        if normalUserTurn {
                            self.session.normalQueuedTurnUserMessageIDs[qid] = messageID
                        }
                        self.persistQueue()
                    }
                    self.resetStreamingPersistBuffer()
                    self.session.transcript.streamingState = .sending
                    return (true, messageID)
                }
                let recordedID = recordedUserMessageID
                    ?? queuedItemId.flatMap { self.session.normalQueuedTurnUserMessageIDs[$0] }
                if let recordedID,
                   let index = self.session.replaceSymbolSnapshots(inUserMessage: recordedID, from: symbolExpansion) {
                    self.persistIndices([index])
                }
                self.resetStreamingPersistBuffer()
                self.session.transcript.streamingState = .sending
                return (true, nil)
            }
            guard promptRecording.proceeded else { return }
            if let messageID = promptRecording.messageID,
               let checkpointID = await self.onCheckpointCapture?(checkpointPrompt, checkpointHasAttachments) {
                await MainActor.run {
                    guard self.session.attachCheckpoint(checkpointID, toUserMessage: messageID),
                          let index = self.session.transcript.messages.firstIndex(where: { message in
                              guard case .user(let id, _, _, _, _, _) = message else { return false }
                              return id == messageID
                          }) else { return }
                    self.persistIndices([index])
                }
            }
            do {
                let remoteId = self.session.remoteSessionId ?? self.sessionId
                // Read the capability flags on the main actor (cheap), then
                // hydrate off-main so file reads + encoding don't block UI.
                let promptCapabilities = self.session.promptCapabilities
                let pendingPreamble = self.session.pendingMCPPreamble
                let pendingForkContext: String? = {
                    guard let fork = self.session.forkRecord,
                          fork.phase == .ready,
                          fork.mechanism == .transcriptTransfer,
                          fork.contextDeliveryPending
                    else { return nil }
                    return ACPTranscriptMarkdown.forkContext(
                        sourceAgentID: fork.sourceAgentID,
                        messages: Array(self.session.transcript.messages.prefix(fork.inheritedMessageCount))
                    )
                }()
                var wireBlocks = ACPSymbolReference.replacingReferences(
                    in: await self.expandingSessionReferences(Self.hydrate(
                        blocks,
                        promptCapabilities: promptCapabilities,
                        worktreePath: self.worktreePath
                    )),
                    with: symbolExpansion)
                // Wire-only context is prepended for the agent and never part
                // of the recorded transcript — recording above used `blocks`.
                var privateBlocks: [ACPContentBlock] = []
                if let pendingPreamble { privateBlocks.append(.text(pendingPreamble)) }
                if let pendingForkContext { privateBlocks.append(.text(pendingForkContext)) }
                for context in await self.pluginContext?(self.sessionId) ?? [] { privateBlocks.append(.text(context)) }
                if self.session.readOnlyRestricted { privateBlocks.append(.text(ACPSideQuestion.guidance)) }
                wireBlocks.insert(contentsOf: privateBlocks, at: 0)
                // A queued turn is found at launch by its `.sending` row, saved
                // before dispatch; a direct one needs its marker saved just as
                // durably before the prompt can reach the agent. Set after the
                // preflight work, so an exit during it leaves no stale marker.
                var markedDirectTurn = false
                if queuedItemId == nil {
                    let markerWrite = await MainActor.run { () -> Task<Void, Never>? in
                        guard self.activePromptID == promptID else { return nil }
                        self.setDirectTurnInFlight(true)
                        return self.persistenceTail
                    }
                    markedDirectTurn = markerWrite != nil
                    await markerWrite?.value
                }
                // Invalidated before the request went out: a turn that was never
                // sent must not be continued. A newer prompt owns its own marker.
                let releaseUnsentMarker = { @MainActor in
                    guard markedDirectTurn, self.activePromptID == nil || self.activePromptID == promptID else { return }
                    self.setDirectTurnInFlight(false)
                }
                guard await self.hasConfirmedLeaseForSideEffect() else {
                    await releaseUnsentMarker()
                    onDispatchRegistered?()
                    throw CancellationError()
                }
                // Hydration suspends for file I/O. A steer can invalidate this
                // prompt while that work is in progress, so verify ownership
                // again before sending a stale RPC.
                guard await MainActor.run(body: {
                    guard self.activePromptID == promptID else {
                        releaseUnsentMarker()
                        return false
                    }
                    // Usage starts when the prompt goes out, after checkpoints, attachments and context providers.
                    let sentAt = self.nextSentAt()
                    // Updates sent during that work belong to what came before.
                    self.activePromptStreamStart = self.connection.client.yieldedUpdateCount
                    self.unreportedPrompts[promptID] = (
                        self.activePromptStartedAt ?? sentAt, sentAt, self.activePromptStreamStart, self.session.currentModel, false)
                    self.noteSent(promptID, streamStart: self.activePromptStreamStart)
                    self.session.expectSymbolExpansionEchoes(symbolExpansion.sentBlocks)
                    // ponytail: a prompt whose result never arrives (a lost connection) leaves its entry; keep a few.
                    // The oldest is reported without tokens before it goes, so every sent turn still gets a row.
                    // Usage it holds counts too, or a result that never comes would hold every later turn's.
                    if self.unreportedPrompts.count + self.heldUsage.count > 8,
                       let oldest = self.unreportedPrompts.keys.min() {
                        self.reportSupersededTurnUsage(oldest, quota: nil)
                    }
                    return true
                }) else {
                    onDispatchRegistered?()
                    throw CancellationError()
                }
                let promptOutcome = try await self.connection.prompt(
                    sessionId: remoteId,
                    blocks: wireBlocks,
                    brokerOperationKey: brokerOperationKey,
                    acknowledgeDurableConsumption: queuedItemId == nil && pendingForkContext == nil,
                    onRequestHandoff: onDispatchRegistered,
                    onTransportHandoff: { [weak self, promptHandoffs] in
                        promptHandoffs.mark(promptID)
                        Task { @MainActor in
                            guard let self, !self.stopped, self.isConnectionCurrent(),
                                  self.activePromptID == promptID,
                                  self.session.transcript.streamingState == .sending
                            else { return }
                            self.session.transcript.streamingState = .streaming
                        }
                    },
                    beforeRequestHandoff: beforeRequestHandoff,
                    onRequestHandoffDidOccur: onRequestHandoffDidOccur
                )
                let promptAcknowledgement = promptOutcome.acknowledgement
                await MainActor.run {
                    guard self.isConnectionCurrent() else { return }
                    let isActivePrompt = self.activePromptID == promptID
                    let hasNewerActivePrompt = self.activePromptID != nil && !isActivePrompt
                    // Read-only here (not `.remove`): `deferCompletedOutputBoundaryUntilUpdatesDrain`'s
                    // `successfulTurn` closure below also checks `cancelledPromptIDs.contains(promptID)`
                    // and needs the id still present when it runs. The actual removal happens once,
                    // after the `isActivePrompt` block, mirroring the pre-existing cleanup point.
                    let wasCancelled = self.cancelledPromptIDs.contains(promptID)
                    // A cancelled/superseded prompt's response can still
                    // arrive after a successor has started or finished.
                    // Its tokens are real spend, so always fold them into
                    // the session total, but only overwrite "last turn"
                    // when this response still belongs to the active
                    // prompt — otherwise it would show stale usage as
                    // current, or clear a newer prompt's just-recorded one.
                    self.session.recordPromptQuota(promptOutcome.quota, updatesLastTurn: isActivePrompt)
                    if !isActivePrompt { self.reportSupersededTurnUsage(promptID, quota: promptOutcome.quota) }
                    let deliveredForkContext = pendingForkContext != nil
                    // The agent received the preamble whenever the RPC above
                    // succeeded, regardless of whether this prompt is still
                    // "active" by the time we get back on the main actor —
                    // guard against a racing change (e.g. a new preamble
                    // queued mid-flight) before clearing.
                    if let pendingPreamble, self.session.pendingMCPPreamble == pendingPreamble {
                        self.session.pendingMCPPreamble = nil
                        self.session.mcpPreambleSent = true
                        self.persistMCPPreambleSent()
                    }
                    if pendingForkContext != nil,
                       var fork = self.session.forkRecord,
                       fork.contextDeliveryPending {
                        fork.contextDeliveryPending = false
                        self.session.forkRecord = fork
                    }
                    if deliveredForkContext {
                        if queuedItemId == nil {
                            self.persistForkContextDelivered(acknowledging: promptAcknowledgement)
                        } else if !isActivePrompt {
                            self.persistForkContextDelivered(acknowledging: promptAcknowledgement)
                        }
                    }
                    if isActivePrompt {
                        self.session.clearRetryStatus()
                        let completionUserMessageID = promptRecording.messageID
                            ?? recordedUserMessageID
                            ?? queuedItemId.flatMap { self.session.normalQueuedTurnUserMessageIDs[$0] }
                        if let queuedItemId {
                            let completedItem = self.session.queue.first
                            let wakeRows = completedItem.map { self.markBackgroundWakesDelivered(for: $0) } ?? []
                            self.session.normalQueuedTurnIDs.remove(queuedItemId)
                            self.session.normalQueuedTurnUserMessageIDs.removeValue(forKey: queuedItemId)
                            if let completedItem, completedItem.backgroundTaskWake != nil {
                                self.persistBackgroundWakeAndQueue(rows: wakeRows, consuming: completedItem,
                                    deliveredForkContext: deliveredForkContext, acknowledging: promptAcknowledgement)
                            } else {
                                _ = self.session.popQueueHead()
                                if deliveredForkContext {
                                    self.persistForkContextDeliveredAndQueue(acknowledging: promptAcknowledgement)
                                } else {
                                    self.persistQueue(acknowledging: promptAcknowledgement)
                                }
                            }
                        }
                        if !wasCancelled, self.session.usageLimit != nil || self.session.usageLimitResumeItem != nil {
                            self.session.usageLimit = nil
                            self.persistUsageLimit()
                            if self.session.removeUsageLimitResume() {
                                self.persistQueue()
                            }
                        }
                        self.activePromptID = nil
                        self.emitTurnCompleted(wasCancelled ? .cancelled : .completed, promptID: promptID, quota: promptOutcome.quota)
                        self.deferCompletedOutputBoundaryUntilUpdatesDrain(
                            successfulTurn: completionUserMessageID.flatMap { userMessageID in
                                guard normalUserTurn,
                                      delegatedSource == nil,
                                      pendingForkContext == nil,
                                      !self.cancelledPromptIDs.contains(promptID)
                                else {
                                    nextPromptLogger.notice("prompt \(promptID) not a suggestion candidate: normalUserTurn=\(normalUserTurn) delegated=\(delegatedSource != nil) forkContext=\(pendingForkContext != nil) cancelled=\(self.cancelledPromptIDs.contains(promptID))")
                                    return nil
                                }
                                return NextPromptCompletedTurn(
                                    sessionID: self.sessionId,
                                    incarnation: self.session.incarnation,
                                    promptID: promptID,
                                    userMessageID: userMessageID,
                                    transcriptRevision: self.session.transcript.messagesGeneration
                                )
                            }
                        )
                        if completionUserMessageID == nil {
                            nextPromptLogger.notice("prompt \(promptID) not a suggestion candidate: no recorded user message")
                        }
                        self.onPromptWorkChanged?()
                    } else {
                        nextPromptLogger.notice("prompt \(promptID) not a suggestion candidate: no longer the active prompt (newerActive=\(hasNewerActivePrompt), cancelled=\(wasCancelled))")
                    }
                    self.cancelledPromptIDs.remove(promptID)
                    if !hasNewerActivePrompt {
                        onPromptFinished?(true)
                    }
#if DEBUG
                    self.onPromptResponseProcessedForTesting?(promptID)
#endif
                }
            } catch {
                await self.waitForPromptUpdateDelivery(promptID: promptID)
                await MainActor.run {
                    guard self.isConnectionCurrent() else { return }
                    self.forgetUsageUnlessAgentAnswered(promptID, error)
                    let wasCancelled = self.cancelledPromptIDs.remove(promptID) != nil
                    let isActivePrompt = self.activePromptID == promptID
                    let hasNewerActivePrompt = self.activePromptID != nil && !isActivePrompt
                    if !isActivePrompt { self.reportSupersededTurnUsage(promptID, quota: nil) }
                    // A prompt stopped by a usage limit reached the agent and a
                    // continue is scheduled, so the composer must not restore it.
                    var deliveredBeforeUsageLimit = false
                    if isActivePrompt {
                        self.session.clearRetryStatus()
                        self.flushStreamingPersist()
                        let usageLimit: ACPUsageLimit? = {
                            guard !wasCancelled, ACPAuthFailure.message(from: error) == nil else { return nil }
                            let bufferedText = self.bufferedAgentText()
                            // Join a flushed prefix with its buffered suffix, but also
                            // recognize a complete buffered limit after ordinary output.
                            let candidates = [
                                [self.currentTurnLastAgentText(), bufferedText].compactMap { $0 }.joined(),
                                bufferedText,
                            ].compactMap { $0 }
                            let now = Date()
                            return candidates.lazy.compactMap { text in
                                ACPUsageLimitDetector.detect(
                                    error: error,
                                    turnAgentText: text,
                                    claudeRateLimit: self.session.latestClaudeRateLimit,
                                    now: now
                                )
                            }.first
                        }()
                        if let usageLimit {
                            deliveredBeforeUsageLimit = true
                            self.applyUsageLimit(usageLimit, failedQueuedItemId: queuedItemId)
                            self.activePromptID = nil
                            self.emitTurnCompleted(.limited, promptID: promptID)
                            self.deferCompletedOutputBoundaryUntilUpdatesDrain()
                            self.onPromptWorkChanged?()
                        } else {
                            let authReason = wasCancelled ? nil : ACPAuthFailure.message(from: error)
                            let errorMessage = authReason ?? error.localizedDescription
                            if queuedItemId != nil, !wasCancelled, authReason == nil {
                                // Queued send failed naturally — leave the item
                                // at the head with lastError so the bubble shows
                                // Retry. Cancelled queued sends had the item
                                // discarded elsewhere (steer) and don't surface.
                                let terminalBrokerFailure: Bool = {
                                    guard brokerOperationKey != nil else { return false }
                                    if case ACPClientError.jsonrpc = error {
                                        return true
                                    }
                                    return false
                                }()
                                self.session.setQueueHeadError(
                                    errorMessage,
                                    advancesBrokerOperationAttempt: terminalBrokerFailure
                                )
                                self.persistQueue()
                            } else if queuedItemId != nil, authReason != nil {
                                self.session.restoreQueue(self.session.queue)
                                self.persistQueue()
                            } else if queuedItemId == nil, !wasCancelled, authReason == nil {
                                self.session.lastError = "prompt failed: \(errorMessage)"
                            }
                            if let authReason {
                                self.session.setupState = .needsAuth(
                                    methods: self.session.authMethods,
                                    reason: authReason
                                )
                                self.session.agentState = .failed(authReason)
                                Task { @MainActor in
                                    await self.onAuthRequired?(self, authReason)
                                }
                            }
                            self.activePromptID = nil
                            self.emitTurnCompleted(wasCancelled ? .cancelled : .failed(errorMessage), promptID: promptID)
                            self.deferCompletedOutputBoundaryUntilUpdatesDrain()
                            self.onPromptWorkChanged?()
                        }
                    }
                    if !hasNewerActivePrompt {
                        onPromptFinished?(wasCancelled || deliveredBeforeUsageLimit)
                    }
#if DEBUG
                    self.onPromptResponseProcessedForTesting?(promptID)
#endif
                }
            }
        }
    }

    @discardableResult
    func sendRecoveryContext(
        _ prompt: String,
        flushQueueOnCompletion: Bool = true,
        onCompleted: (@MainActor (_ delivered: Bool) -> Void)? = nil
    ) -> Bool {
        guard !nativeForkBarrierActive, !session.holdsPromptsForDelegatedSelection else { return false }
        turnPublicationGeneration += 1
        discardPendingSuccessfulTurn("sendRecoveryContext")
        flushPendingIncomingUpdates()
        let promptID = session.allocatePromptID()
        activePromptID = promptID
        let connectionIsCurrent = isConnectionCurrent
        latestPromptTask = Task { [weak self, onCompleted, connectionIsCurrent] in
            guard let self else {
                await MainActor.run {
                    if connectionIsCurrent() {
                        onCompleted?(false)
                    }
                }
                return
            }
            let proceeded = await MainActor.run { () -> Bool in
                if self.activePromptID != promptID {
                    self.cancelledPromptIDs.remove(promptID)
                    return false
                }
                guard connectionIsCurrent(), !self.stopped else {
                    self.cancelledPromptIDs.remove(promptID)
                    return false
                }
                self.session.allowsStreamingBoundaryCrossing = true
                self.resetStreamingPersistBuffer()
                self.session.transcript.streamingState = .sending
                // A recovery prompt is usage of its own, reported with its result (never as a turn completion).
                let sentAt = self.nextSentAt()
                self.unreportedPrompts[promptID] = (
                    sentAt, sentAt, self.connection.client.yieldedUpdateCount, self.session.currentModel, true)
                self.noteSent(promptID, streamStart: self.connection.client.yieldedUpdateCount)
                return true
            }
            guard proceeded else {
                await MainActor.run {
                    if connectionIsCurrent() {
                        onCompleted?(false)
                    }
                }
                return
            }
            do {
                let remoteId = self.session.remoteSessionId ?? self.sessionId
                let promptOutcome = try await self.connection.prompt(
                    sessionId: remoteId, blocks: [.text(prompt)],
                    onTransportHandoff: { [promptHandoffs] in promptHandoffs.mark(promptID) })
                await MainActor.run {
                    guard connectionIsCurrent() else { return }
                    let wasCancelled = self.cancelledPromptIDs.remove(promptID) != nil
                    let isActivePrompt = self.activePromptID == promptID
                    // See the matching comment in sendNow: always accumulate
                    // into the session total, only overwrite "last turn"
                    // when this response still belongs to the active prompt.
                    self.session.recordPromptQuota(promptOutcome.quota, updatesLastTurn: isActivePrompt)
                    if isActivePrompt {
                        self.activePromptID = nil
                        self.deferCompletedOutputBoundaryUntilUpdatesDrain(
                            flushQueueWhenReady: flushQueueOnCompletion
                        )
                        self.onPromptWorkChanged?()
                    }
                    // Always resolve the recovery status, even when a newer
                    // prompt (e.g. the user steered) has taken over the
                    // transport. Unlike `sendNow`, whose completion legitimately
                    // hands UI state to its successor turn, this callback is the
                    // ONLY thing that clears the "Restoring…" spinner — skipping
                    // it on supersession strands the spinner forever.
                    self.reportSupersededTurnUsage(
                        promptID, quota: promptOutcome.quota, result: wasCancelled ? .cancelled : .completed)
                    onCompleted?(isActivePrompt && !wasCancelled)
#if DEBUG
                    self.onPromptResponseProcessedForTesting?(promptID)
#endif
                }
            } catch {
                await MainActor.run {
                    guard connectionIsCurrent() else { return }
                    self.forgetUsageUnlessAgentAnswered(promptID, error)
                    _ = self.cancelledPromptIDs.remove(promptID)
                    let isActivePrompt = self.activePromptID == promptID
                    if isActivePrompt {
                        self.flushStreamingPersist()
                        self.activePromptID = nil
                        self.session.transcript.streamingState = .idle
                        self.onPromptWorkChanged?()
                    }
                    self.reportSupersededTurnUsage(
                        promptID, quota: nil, result: .failed(error.localizedDescription))
                    // See the success path above: the recovery status must
                    // resolve regardless of supersession or the spinner strands.
                    onCompleted?(false)
#if DEBUG
                    self.onPromptResponseProcessedForTesting?(promptID)
#endif
                }
            }
        }
        return true
    }

    /// First text block as the user-facing preview. Used when recording
    /// the queued item's bubble in the transcript on flush. Concatenating
    /// every text block matches the wire shape we already send.
    static func textPreview(of blocks: [ACPContentBlock]) -> String {
        blocks.compactMap { b -> String? in
            if case .text(let s) = b { return s }
            return nil
        }.joined()
    }

    /// Attachments derived from the prompt blocks for the user-bubble UI:
    /// resource links plus deferred image blocks (which still carry the staged
    /// file uri). Mirrors the shape `recordUserPrompt` expects (which
    /// previously came from the composer-level attachments array). Inline-
    /// hydrated images (uri == nil) are intentionally skipped — they have no
    /// file to point the thumbnail at and only appear post-`hydrate`.
    ///
    /// `blocks` always flattens an image's original mid-sentence position —
    /// `Self.blocks(text:attachments:)` emits one leading text block followed
    /// by every attachment in order, so the composer's interleaving is gone
    /// by the time it gets here. `draft`, when supplied, is the structured
    /// `ACPComposerDraft` captured at submit time (still ordered, still
    /// interleaved); its image segments are matched to this call's image
    /// blocks by position to recover each one's `textOffset`. Omitted
    /// (`nil`) for callers with no draft on hand (checkpoint bookkeeping,
    /// delegated/commentary content) — every image attachment they produce
    /// simply carries no offset.
    static func attachments(
        of blocks: [ACPContentBlock],
        draft: ACPComposerDraft? = nil
    ) -> [ACPMessage.Attachment] {
        var offsets = ArraySlice(draft?.imageTextOffsets() ?? [])
        return blocks.compactMap { b -> ACPMessage.Attachment? in
            if case .resourceLink(let uri, let name) = b {
                return ACPMessage.Attachment(uri: uri, name: name)
            }
            if case .resource(let uri, _, _) = b {
                return ACPMessage.Attachment(uri: uri, name: URL(string: uri)?.lastPathComponent)
            }
            if case .image(_, let uri, let mime) = b, let uri {
                let name = URL(string: uri)?.lastPathComponent
                let offset = offsets.isEmpty ? nil : offsets.removeFirst()
                return ACPMessage.Attachment(uri: uri, name: name, mimeType: mime ?? "image/png", textOffset: offset)
            }
            return nil
        }
    }

    private func deferCompletedOutputBoundaryUntilUpdatesDrain(
        flushQueueWhenReady: Bool = true,
        successfulTurn: NextPromptCompletedTurn? = nil
    ) {
        let target = connection.client.yieldedUpdateCount
        pendingCompletedOutputBoundary = (
            updateCount: max(pendingCompletedOutputBoundary?.updateCount ?? target, target),
            successfulTurn: successfulTurn
        )
        applyPendingCompletedOutputBoundaryIfReady(flushQueueWhenReady: flushQueueWhenReady)
    }

    private func applyPendingCompletedOutputBoundaryIfReady(flushQueueWhenReady: Bool) {
        guard !nativeSteeringInProgress, !detachedSteeringTurn,
              let boundary = pendingCompletedOutputBoundary,
              appliedUpdateCount >= boundary.updateCount
        else {
            if let turn = pendingCompletedOutputBoundary?.successfulTurn {
                nextPromptLogger.debug("prompt \(turn.promptID) waiting: steering=\(self.nativeSteeringInProgress || self.detachedSteeringTurn) updatesApplied=\(self.appliedUpdateCount)/\(self.pendingCompletedOutputBoundary?.updateCount ?? 0)")
            }
            return
        }
        pendingCompletedOutputBoundary = nil
        flushStreamingPersist()
        // markCompletedOutputBoundary() materialises any held replay candidate
        // (a stranded final chunk); persist the appended rows so they survive
        // detach/reopen — no `ACPSessionUpdate` carries them here.
        let before = session.transcript.messages.count
        session.markCompletedOutputBoundary()
        if session.transcript.messages.count > before {
            persistFromIndex(before)
        }
        guard activePromptID == nil else {
            if let turn = boundary.successfulTurn { nextPromptLogger.notice("prompt \(turn.promptID) dropped at boundary: another prompt is active") }
            return
        }
        // The turn's updates have drained: its echoes have all arrived.
        session.endSymbolExpansionEchoTurn()
        session.transcript.streamingState = .idle
        guard flushQueueWhenReady else {
            if let turn = boundary.successfulTurn { nextPromptLogger.notice("prompt \(turn.promptID) dropped at boundary: queue flush deferred") }
            return
        }
        flushQueueIfIdle()
        guard let turn = boundary.successfulTurn else { return }
        if let blocker = successfulTurnBlocker() {
            nextPromptLogger.notice("prompt \(turn.promptID) dropped at boundary: \(blocker, privacy: .public)")
            return
        }
        let publicationGeneration = turnPublicationGeneration
        let publicationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.flushPersistence()
            if self.turnPublicationGeneration != publicationGeneration {
                nextPromptLogger.notice("prompt \(turn.promptID) dropped before publishing: superseded")
                return
            }
            if self.session.nextPromptID != turn.promptID + 1 {
                nextPromptLogger.notice("prompt \(turn.promptID) dropped before publishing: a newer prompt was allocated")
                return
            }
            if let blocker = self.successfulTurnBlocker() {
                nextPromptLogger.notice("prompt \(turn.promptID) dropped before publishing: \(blocker, privacy: .public)")
                return
            }
            self.onSuccessfulTurn(NextPromptCompletedTurn(
                sessionID: turn.sessionID,
                incarnation: turn.incarnation,
                promptID: turn.promptID,
                userMessageID: turn.userMessageID,
                transcriptRevision: self.session.transcript.messagesGeneration
            ))
        }
#if DEBUG
        turnPublicationTasksForTesting?[turn.promptID] = publicationTask
#endif
    }

    /// Append a system notice to the session AND persist it. Use this
    /// instead of `session.appendSystemNotice` directly so the message
    /// survives a session reload.
    func appendAndPersistSystemNotice(_ text: String) {
        let before = session.transcript.messages.count
        session.appendSystemNotice(text)
        persistFromIndex(before)
    }

    /// Append a system notice and report whether it actually reached the
    /// store, unlike the fire-and-forget `appendAndPersistSystemNotice`.
    /// A caller that holds the only other durable copy — the delegated
    /// message inbox — needs the real answer, because it deletes that copy
    /// on success and would otherwise lose the notice entirely when the
    /// write is rejected by the lease fence or fails in SQLite.
    ///
    /// Deliberately goes through the same fire-and-forget path rather than
    /// writing directly, so the notice keeps its place in the serialized
    /// persistence queue, and reads the outcome from a recorded row id
    /// rather than awaiting a completion: `enqueuePersistence` skips its
    /// completion when the task is cancelled, so a continuation waiting on
    /// it could hang forever.
    ///
    /// The answer has to name THIS row. `persistedMessageCount` is a global
    /// high-water mark that any later index can advance — a queued agent
    /// update committing while this flush awaits, or the streaming path,
    /// which raises it optimistically at enqueue time — so it reports
    /// success for a notice whose own write was rejected by the fence or
    /// failed in SQLite, and the caller then deletes the inbox row that was
    /// the notice's only other copy. `confirmedAwaitedWrites` is
    /// populated solely by `commitPersistedMessageRows`, which runs only on
    /// a confirmed write of this exact row payload, so an unwritten notice
    /// always reports `false` and is retried from the inbox.
    func appendAndPersistSystemNoticeAwaitingResult(_ text: String) async -> Bool {
        guard holdsLeaseForWrite() else { return false }
        let before = session.transcript.messages.count
        session.appendSystemNotice(text)
        return await awaitingWrite(ofRowAt: session.transcript.messages.count - 1) {
            persistFromIndex(before)
        }
    }

    /// Enqueue a write of the row at `index` through `enqueue` and report
    /// whether a confirmed write stored that row with the payload it holds
    /// NOW. Matching the payload, not just the row id, keeps an earlier write
    /// of the same row — still in flight when the row was mutated — from
    /// confirming this one. Registering happens before any suspension point,
    /// so no commit can slip in between the mutation and the registration.
    private func awaitingWrite(ofRowAt index: Int, enqueue: () -> Void) async -> Bool {
        guard session.transcript.messages.indices.contains(index),
              let payload = try? ACPMessageCodec.encode(messageForPersistence(session.transcript.messages[index]))
        else { return false }
        let token = UUID()
        awaitedWrites[token] = AwaitedWrite(rowID: messageRowID(index), payload: payload)
        defer {
            awaitedWrites[token] = nil
            confirmedAwaitedWrites.remove(token)
        }
        enqueue()
        await flushPersistence()
        return confirmedAwaitedWrites.contains(token)
    }

    /// Append a file-edit card to the session AND persist it.
    func appendAndPersistFileEdit(_ edit: ACPMessage.FileEdit) {
        let before = session.transcript.messages.count
        session.appendFileEdit(edit)
        persistFromIndex(before)
    }

    /// Append a visual aid and report whether its row reached the store, the
    /// way `appendAndPersistSystemNoticeAwaitingResult` does: `visual_show`
    /// tells the agent the visual is shown only once it would survive a reload.
    ///
    /// Rows are keyed by position, so a failed card never shifts the rows behind it: a shifted
    /// row's old and new positions cannot both be kept consistent in the store if the rewrite fails
    /// too, and a lost message is worse than a ghost card.
    /// - Last row: nothing follows it and its own row was never stored, so it is removed, and the
    ///   agent's retry cannot leave a second card next to a ghost that a reload would lose.
    /// - Rows were appended behind it while its write was in flight: it stays, and its single row is
    ///   written once more. If that lands the card is stored and the call succeeds; if not, the card
    ///   stays in memory unstored (a reload drops it) and the call fails.
    func appendAndPersistVisualAidAwaitingResult(_ visual: ACPVisualAid) async -> Bool {
        guard holdsLeaseForWrite() else { return false }
        let before = session.transcript.messages.count
        unconfirmedVisualAids[visual.id] = []
        failedFirstWriteVisualAidIDs.remove(visual.id)
        session.appendVisualAid(visual)
        var written = await awaitingWrite(ofRowAt: session.transcript.messages.count - 1) {
            persistFromIndex(before)
        }
        if !written, let index = session.transcript.messages.firstIndex(where: {
            if case .visualAid(let existing) = $0 { return existing.id == visual.id }
            return false
        }) {
            if index == session.transcript.messages.count - 1 {
                session.removeVisualAid(id: visual.id)
                // Nothing was stored at or after this index, so the caches must not claim otherwise.
                persistedMessageCount = min(persistedMessageCount, index)
                lastPersistedPayloads = lastPersistedPayloads.filter { $0.key < index }
            } else {
                written = await awaitingWrite(ofRowAt: index) {
                    persistIndices([index])
                }
            }
        }
        if !written { failedFirstWriteVisualAidIDs.insert(visual.id) }
        for waiter in unconfirmedVisualAids.removeValue(forKey: visual.id) ?? [] {
            waiter.resume(returning: written)
        }
        return written
    }

    /// Waits until the visual's first write is resolved and reports whether it was stored, or, once it
    /// is resolved, whether the card is in the transcript and its first write did not fail. An answer must not start earlier: the card
    /// appears in the transcript before that write is confirmed, and if it then fails at the tail the
    /// card is removed, which would also remove the row an already-queued answer had stored.
    func awaitVisualAidFirstWrite(id visualId: UUID) async -> Bool {
        guard unconfirmedVisualAids[visualId] != nil else {
            return !failedFirstWriteVisualAidIDs.contains(visualId) && session.transcript.visualAid(id: visualId) != nil
        }
        return await withCheckedContinuation { continuation in
            unconfirmedVisualAids[visualId]?.append(continuation)
        }
    }

    /// Replace the visual aid with the same id in place and report whether
    /// that row reached the store. The in-memory change happens before the
    /// first suspension point, so a second answer already sees this one.
    func replaceAndPersistVisualAidAwaitingResult(_ visual: ACPVisualAid) async -> Bool {
        guard holdsLeaseForWrite(),
              let index = session.transcript.messages.firstIndex(where: {
                  if case .visualAid(let existing) = $0 { return existing.id == visual.id }
                  return false
              })
        else { return false }
        session.transcript.replaceMessage(at: index, with: .visualAid(visual))
        return await awaitingWrite(ofRowAt: index) {
            persistIndices([index])
        }
    }

    /// Persist the row of a visual aid already changed in the transcript with
    /// the payload it holds now, and report whether that exact payload was
    /// committed. False without the lease, where nothing is written.
    func persistVisualAidRowAwaitingResult(id visualId: UUID) async -> Bool {
        guard holdsLeaseForWrite(),
              let index = session.transcript.messages.firstIndex(where: {
                  if case .visualAid(let existing) = $0 { return existing.id == visualId }
                  return false
              })
        else { return false }
        return await awaitingWrite(ofRowAt: index) {
            persistIndices([index])
        }
    }
}

extension ACPSessionRunner {
    /// True when this runner may write — it still holds the session lease.
    /// When `ownerInstanceId` is nil (tests that construct a runner directly
    /// without a lease), gating is disabled and writes always proceed.
    private func holdsLeaseForWrite() -> Bool {
        canWrite()
    }

    /// Names the first condition that keeps a finished turn from being offered a next-prompt suggestion.
    private func successfulTurnBlocker() -> String? {
        if stopped { return "runner stopped" }
        if !holdsLeaseForWrite() { return "write lease not held" }
        if session.agentState != .ready { return "agent not ready" }
        if activePromptID != nil { return "another prompt is active" }
        if !session.queue.isEmpty { return "queue not empty" }
        if session.transcript.pendingPermission != nil { return "pending permission" }
        if session.transcript.pendingQuestion != nil { return "pending question" }
        if session.transcript.pendingPlan != nil { return "pending plan" }
        if !session.transcript.pendingUserInputs.isEmpty { return "pending user input" }
        if steerInProgress { return "steer in progress" }
        if nativeForkBarrierActive { return "native fork barrier" }
        return nil
    }

    private func discardPendingSuccessfulTurn(_ reason: String) {
        if let turn = pendingCompletedOutputBoundary?.successfulTurn {
            nextPromptLogger.notice("prompt \(turn.promptID) discarded: \(reason, privacy: .public)")
        }
        pendingCompletedOutputBoundary?.successfulTurn = nil
    }

    /// Cached authority is enough for in-memory updates and persistence fences,
    /// but RPCs and process/file side effects must confirm the token against
    /// SQLite immediately before they run.
    private func hasConfirmedLeaseForSideEffect() async -> Bool {
        guard holdsLeaseForWrite() else { return false }
        return await validateLease()
    }

    private func shouldBatchStreamingPersist(
        for update: ACPSessionUpdate,
        isPromptOwnedBufferedUpdate: Bool,
        hasUnderLeaseBufferedStreamingWrites: Bool
    ) -> Bool {
        guard activePromptID != nil
            || isPromptOwnedBufferedUpdate
            || hasUnderLeaseBufferedStreamingWrites
        else { return false }
        switch session.transcript.streamingState {
        case .sending, .streaming:
            break
        case .idle, .awaitingPermission, .awaitingInput:
            return false
        }
        switch update {
        case .agentMessageChunk, .agentThoughtChunk, .toolCallUpdate, .compactionSummaryChunk:
            return true
        case .userMessageChunk, .toolCall, .compactionUpdate,
             .plan, .availableModelsUpdate,
             .currentModeUpdate, .currentModelUpdate, .sessionInfoUpdate,
             .sessionConfigOptionsUpdate, .availableCommandsUpdate,
             .usageUpdate, .notice, .subagentSpawned, .subagentStateUpdate, .asyncTask, .unknown:
            return false
        }
    }

    private func scheduleStreamingPersist(
        _ indices: Set<Int>,
        mayCapturePersistedBases: Bool = true,
        durableConsumptionAcknowledgement: ACPDurableConsumptionAcknowledgement? = nil
    ) {
        guard !indices.isEmpty else {
            durableConsumptionAcknowledgement?()
            return
        }
        // Per-chunk work is intentionally cheap: record the dirty indices and
        // arm the debounce. Encoding the (growing) message and reading its
        // stored payload happen once per debounce window in the flush, not
        // once per streamed chunk.
        //
        // One exception: an already-persisted row this runner has not written
        // yet (loaded from disk, or trimmed from the cache) has no compare-and-
        // swap base. Capture its stored payload NOW — the caller reaches here
        // only after confirming we hold the lease, so this reads our own view,
        // not a future owner's. Deferring to the stand-down freeze would be too
        // late (the row could hold a new owner's payload by then), and skipping
        // it would silently drop a legitimate under-lease update. This reads at
        // most once per such row, never on the hot streaming-tail path (a new
        // trailing row is not yet persisted, so it is written, not read).
        if mayCapturePersistedBases {
            for i in indices {
                capturePersistedBaseIfNeeded(at: i)
            }
        }
        pendingStreamingPersistIndices.formUnion(indices)
        if let durableConsumptionAcknowledgement {
            pendingStreamingPersistAcknowledgements.append(durableConsumptionAcknowledgement)
        }
        for index in indices {
            pendingStreamingPersistRevisions[index, default: 0] += 1
        }
        guard streamingPersistTask == nil else { return }
        streamingPersistTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.streamingPersistDebounceNanos)
            guard !Task.isCancelled else { return }
            self.flushStreamingPersist()
        }
    }

    private func capturePersistedBaseIfNeeded(at index: Int) {
        guard index < persistedMessageCount,
              lastPersistedPayloads[index] == nil,
              !capturingPersistedBaseIndices.contains(index),
              let fence = leaseFenceProvider()
        else { return }
        capturingPersistedBaseIndices.insert(index)
        let id = messageRowID(index)
        enqueuePersistence({ persistence in
            try await persistence.loadMessagePayload(id: id, fence: fence)
        }, completion: { [weak self] payload in
            guard let self else { return }
            self.capturingPersistedBaseIndices.remove(index)
            guard let payload = payload ?? nil else { return }
            self.lastPersistedPayloads[index] = payload
            if self.streamingLeaseLost {
                self.freezeStreamingPersistSnapshots()
                self.persistStreamingPersistSnapshots()
            }
        })
    }

    private func flushStreamingPersist() {
        flushStreamingPersist(requiresLease: true)
    }

    /// Clear streaming-persist buffer state carried over from a prior stream.
    /// A taken-over stream leaves frozen snapshots and a set latch behind; if
    /// this runner later reacquires the lease and sends a fresh prompt, those
    /// stale rows must not resurrect.
    private func resetStreamingPersistBuffer() {
        guard streamingLeaseLost else { return }
        streamingLeaseLost = false
        pendingStreamingPersistIndices.removeAll()
        pendingStreamingPersistRevisions.removeAll()
        streamingPersistInFlightIndices.removeAll()
        pendingStreamingPersistSnapshots.removeAll()
        pendingStreamingPersistAcknowledgements.removeAll()
    }

    /// Bound the compare-and-swap base cache to the recent tail so it can't
    /// grow without limit over a long session.
    private func trimLastPersistedPayloads() {
        let keepFrom = persistedMessageCount - Self.lastPersistedPayloadsWindow
        guard keepFrom > 0, lastPersistedPayloads.count > Self.lastPersistedPayloadsWindow else { return }
        lastPersistedPayloads = lastPersistedPayloads.filter { $0.key >= keepFrom }
    }

    private func flushStreamingPersistOnStop() {
        // During takeover, the lease row may already point at the new owner
        // by the time stand-down stops this runner. Flush once so the debounce
        // buffer is not the only copy of the tail chunks.
        flushStreamingPersist(requiresLease: false)
    }

    /// Flush the buffered streaming rows.
    ///
    /// - If a takeover was already detected mid-stream, only the frozen
    ///   snapshots are safe to write, and only via compare-and-swap.
    /// - Otherwise the live transcript is authoritative: try a lease-gated
    ///   write. If that reveals the lease has since moved, freeze the buffered
    ///   rows so a later stand-down can CAS-write them; when this *is* the
    ///   stand-down flush (`requiresLease == false`), CAS-write them now.
    private func flushStreamingPersist(requiresLease: Bool) {
        streamingPersistTask?.cancel()
        streamingPersistTask = nil
        if streamingLeaseLost {
            persistStreamingPersistSnapshots()
            return
        }
        let indices = pendingStreamingPersistIndices.subtracting(streamingPersistInFlightIndices)
        guard !indices.isEmpty else { return }
        let revisions = Dictionary(uniqueKeysWithValues: indices.map {
            ($0, pendingStreamingPersistRevisions[$0, default: 0])
        })
        let acknowledgements = pendingStreamingPersistAcknowledgements
        pendingStreamingPersistAcknowledgements.removeAll(keepingCapacity: true)
        streamingPersistInFlightIndices.formUnion(indices)
        // This flush's own completion is not part of any subagent lifecycle
        // batch — an unrelated earlier failure must not report a spurious
        // `false` here, which would be misread below as the write lease
        // having moved and stop scheduling the rest of this prompt's output.
        if persistIndices(
            indices, requiresLease: true, participatesInLifecycleBatch: false,
            completion: { [weak self] succeeded in
                guard let self else { return }
                self.streamingPersistInFlightIndices.subtract(indices)
                if succeeded {
                    for acknowledgement in acknowledgements {
                        acknowledgement()
                    }
                    for index in indices where self.pendingStreamingPersistRevisions[index] == revisions[index] {
                        self.pendingStreamingPersistIndices.remove(index)
                        self.pendingStreamingPersistRevisions.removeValue(forKey: index)
                    }
                    if !self.pendingStreamingPersistIndices.isEmpty, !self.streamingLeaseLost {
                        self.flushStreamingPersist()
                    }
                    return
                }
                self.freezeStreamingPersistSnapshots()
                self.streamingLeaseLost = true
                self.persistStreamingPersistSnapshots()
            }
        ) {
            return
        }
        streamingPersistInFlightIndices.subtract(indices)
        // The lease moved between the last chunk and this flush. Freeze the
        // buffered rows' current state — every chunk so far arrived while we
        // held the lease — for the stand-down CAS write.
        freezeStreamingPersistSnapshots()
        streamingLeaseLost = true
        persistStreamingPersistSnapshots()
    }

    /// Encode the buffered streaming rows from the live transcript into
    /// compare-and-swap snapshots. Called exactly once, at the moment a
    /// takeover is detected, so the payloads capture the last transcript
    /// state produced while we still held the lease.
    private func freezeStreamingPersistSnapshots() {
        let messages = session.transcript.messages
        for i in pendingStreamingPersistIndices {
            guard i >= 0, i < messages.count else { continue }
            let message = messageForPersistence(messages[i])
            guard let payload = try? ACPMessageCodec.encode(message) else { continue }
            let basePayload: Data?
            // A row may have been created by an earlier queued persistence
            // operation even when `persistedMessageCount` has not caught up.
            // Only a payload captured under our token may authorize a CAS
            // update after takeover; otherwise this remains insert-only.
            if let base = lastPersistedPayloads[i] {
                basePayload = base
            } else if i < persistedMessageCount {
                // Never read a missing base after takeover: that could capture
                // the new owner's payload and make a stale CAS destructive.
                continue
            } else {
                basePayload = nil
            }
            pendingStreamingPersistSnapshots[i] = .init(kind: message.kind, payload: payload, basePayload: basePayload)
        }
    }

    private func persistStreamingPersistSnapshots() {
        guard !pendingStreamingPersistSnapshots.isEmpty else { return }
        let snapshots = pendingStreamingPersistSnapshots
        for i in snapshots.keys.sorted() {
            guard let snapshot = snapshots[i] else { continue }
            let id = messageRowID(i)
            // Both writes below are best-effort salvage attempts that can
            // legitimately lose the race — a CAS whose base payload no
            // longer matches, or an insert onto a row the new owner already
            // wrote. onMessageActivity must only fire once the completion
            // confirms the write actually landed; onPersist keeps firing
            // unconditionally, matching its established cross-process/lease
            // notification contract.
            if let basePayload = snapshot.basePayload {
                let payload = snapshot.payload
                let sid = sessionId
                enqueuePersistence({ persistence in
                    try await persistence.compareAndSwapMessagePayload(
                        id: id,
                        sessionId: sid,
                        payload: payload,
                        expectedPayload: basePayload
                    )
                }, completion: { [weak self] succeeded in
                    if succeeded == true {
                        self?.onMessageActivity?()
                    }
                })
            } else {
                let row = ACPStoredMessage(
                    id: id,
                    sessionId: sessionId,
                    kind: snapshot.kind,
                    seq: Int64(i),
                    payload: snapshot.payload,
                    createdAt: createdAt(forMessageAt: i)
                )
                enqueuePersistence({ persistence in
                    try await persistence.insertMessageIfMissing(row)
                }, completion: { [weak self] inserted in
                    if inserted == true {
                        self?.onMessageActivity?()
                    }
                })
                persistedMessageCount = max(persistedMessageCount, i + 1)
            }
            lastPersistedPayloads[i] = snapshot.payload
            pendingStreamingPersistIndices.remove(i)
            pendingStreamingPersistRevisions.removeValue(forKey: i)
            pendingStreamingPersistSnapshots.removeValue(forKey: i)
        }
        trimLastPersistedPayloads()
        onPersist?()
    }

    /// Persist the specific message rows touched by an `apply()` call.
    /// Use this instead of `persistFromIndex` when the caller can name
    /// exactly which indices changed — a plan or tool-call update may
    /// mutate a row anywhere in the transcript, not just the trailing
    /// one, so the count-delta heuristic in `persistFromIndex` would
    /// write back the wrong row.
    @discardableResult
    func persistIndices(
        _ indices: Set<Int>,
        requiresLease: Bool = true,
        participatesInLifecycleBatch: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) -> Bool {
        streamingPersistTask?.cancel()
        streamingPersistTask = nil
        guard !requiresLease || holdsLeaseForWrite() else { return false }
        guard !indices.isEmpty else {
            completion?(true)
            return true
        }
        let messages = session.transcript.messages
        var rows: [ACPStoredMessage] = []
        for i in indices.sorted() {
            guard i >= 0, i < messages.count else { continue }
            let m = messageForPersistence(messages[i])
            guard let payload = try? ACPMessageCodec.encode(m) else { continue }
            let id = messageRowID(i)
            rows.append(ACPStoredMessage(
                id: id,
                sessionId: sessionId,
                kind: m.kind,
                seq: Int64(i),
                payload: payload,
                createdAt: createdAt(forMessageAt: i)
            ))
        }
        let fence = requiresLease ? leaseFenceProvider() : nil
        if !rows.isEmpty {
            let messageRows = rows
            enqueuePersistence({ persistence in
                try await persistence.persistMessages(messageRows, fence: fence)
            }, completion: { [weak self] persisted in
                guard let self else { return }
                // This write's own bookkeeping — what Alas now believes is
                // actually on disk — reflects ONLY this write's own outcome,
                // regardless of any other write's combined `succeeded` below.
                if persisted == true {
                    self.commitPersistedMessageRows(messageRows)
                }
                // `lastQueuedPersistenceSucceeded` combining exists to
                // couple an OpenCode-normalized dual-write batch (a spawn
                // with no ack of its own, followed by a trailing update
                // that carries the real one) — live or replayed. A caller
                // whose write has nothing to do with that batch, like
                // `flushStreamingPersist`'s own non-durable completion on
                // every streaming flush, opts out via
                // `participatesInLifecycleBatch: false`: an unrelated
                // EARLIER batch's transient failure must not make THIS
                // write's own success report back as `false`, which
                // `flushStreamingPersist` reads as its write lease having
                // moved and stops scheduling further output.
                guard participatesInLifecycleBatch else {
                    completion?(persisted == true)
                    return
                }
                // See the matching comment in `persistSubagentIndices`:
                // combine with the preceding write's outcome rather than
                // record only this one, so a batch's earlier failure isn't
                // erased by a later write's own success — but reset once a
                // write that carries the caller's own completion concludes
                // (the batch's acknowledgement boundary), so a transient
                // failure can't block every later, unrelated batch forever.
                let succeeded = persisted == true && self.lastQueuedPersistenceSucceeded
                self.lastQueuedPersistenceSucceeded = completion == nil ? succeeded : true
                completion?(succeeded)
            })
        } else {
            completion?(true)
        }
        return true
    }

    private func messageForPersistence(_ message: ACPMessage) -> ACPMessage {
        message
    }

    private func createdAt(forMessageAt index: Int) -> Int64 {
        Int64(session.transcript.createdAt(forMessageAt: index)?.timeIntervalSince1970
            ?? Date().timeIntervalSince1970)
    }

    /// The store's row id for the message at `index`. Single source of truth:
    /// `awaitedWrites` matches on this, so a divergence between how a
    /// row is written and how its write is confirmed would silently report
    /// every awaited write as unwritten.
    private func messageRowID(_ index: Int) -> String {
        "msg-\(sessionId)-\(index)"
    }

    private func commitPersistedMessageRows(_ rows: [ACPStoredMessage]) {
        for row in rows {
            let index = Int(row.seq)
            persistedMessageCount = max(persistedMessageCount, index + 1)
            lastPersistedPayloads[index] = row.payload
            for (token, awaited) in awaitedWrites where awaited.rowID == row.id && awaited.payload == row.payload {
                confirmedAwaitedWrites.insert(token)
            }
        }
        trimLastPersistedPayloads()
        onPersist?()
        onMessageActivity?()
    }

    private func effectiveRemoteHost() -> String? {
        remoteHost ?? (usesRemoteHostRegistry ? RemoteHostRegistry.shared.host(forPath: worktreePath) : nil)
    }

    /// Persist messages from the apply() boundary. Three cases:
    ///   1. apply() appended N >= 1 new messages: persist them as new rows.
    ///   2. apply() mutated the trailing message in place (chunk-merge,
    ///      tool-call update, plan update): persist that trailing row.
    ///   3. apply() did nothing (e.g. availableModelsUpdate): nothing to do.
    ///
    /// `from` is the message count CAPTURED BEFORE apply(); compare it
    /// against the current count to figure out which case we're in. The
    /// previous version dropped case 2 silently — chunk-merged agent
    /// text was visible in memory but never written, so reopening a
    /// session lost most of the conversation.
    func persistFromIndex(_ from: Int) {
        flushStreamingPersist()
        guard holdsLeaseForWrite() else { return }
        let messages = session.transcript.messages
        guard messages.count > 0 else { return }

        let lowerBound: Int
        if from < messages.count {
            // New messages appended (possibly with the trailing one
            // also mutated as a side effect of the same apply()).
            lowerBound = from
        } else if from == messages.count {
            // No new entries — the trailing one was mutated. Re-persist it.
            lowerBound = messages.count - 1
        } else {
            return
        }

        var rows: [ACPStoredMessage] = []
        for i in lowerBound..<messages.count {
            let m = messages[i]
            guard let payload = try? ACPMessageCodec.encode(m) else { continue }
            let id = messageRowID(i)
            rows.append(ACPStoredMessage(
                id: id,
                sessionId: sessionId,
                kind: m.kind,
                seq: Int64(i),
                payload: payload,
                createdAt: createdAt(forMessageAt: i)
            ))
        }
        let fence = leaseFenceProvider()
        if !rows.isEmpty {
            let messageRows = rows
            enqueuePersistence({ persistence in
                try await persistence.persistMessages(messageRows, fence: fence)
            }, completion: { [weak self] persisted in
                guard let self, persisted == true else { return }
                self.commitPersistedMessageRows(messageRows)
            })
        }
    }
}

extension ACPSessionRunner {
    /// Reconcile only after a successful attach. A disconnected socket alone
    /// does not establish that the adapter, or any process it started, died.
    func reconcileBackgroundTasks(adapterSurvived: Bool, previousTaskIds: Set<String>) async {
        guard isConnectionCurrent(), holdsLeaseForWrite() else { return }
        // The attach response can arrive before updatesTask has dequeued its
        // replay. Drain the captured client watermark before deciding which
        // tasks the replacement adapter failed to reannounce.
        let updateWatermark = connection.client.yieldedUpdateCount
        flushPendingIncomingUpdates(flushQueueWhenBoundaryReady: false)
        while appliedUpdateCount < updateWatermark {
            guard !stopped, !Task.isCancelled, isConnectionCurrent(), holdsLeaseForWrite(),
                  session.agentState != .disconnected else { return }
            await Task.yield()
            flushPendingIncomingUpdates(flushQueueWhenBoundaryReady: false)
        }
        guard !stopped, !Task.isCancelled, isConnectionCurrent(), holdsLeaseForWrite() else { return }
        var dirty: Set<Int> = []
        if !adapterSurvived {
            for var task in session.backgroundTasks where previousTaskIds.contains(task.id)
                && !observedBackgroundTaskIds.contains(task.id) && task.isActive {
                task.loseObservation()
                dirty.formUnion(session.saveBackgroundTask(task))
            }
        }
        // Recover both pending completions and obsolete loss wakes after a
        // crash between the task snapshot write and its queue update.
        let wakeTasks = session.backgroundTasks.filter { $0.needsWake || ($0.isActive && $0.wakeId != nil) }
        for task in wakeTasks {
            if let index = session.transcript.toolCallIndex(toolCallId: task.id) { dirty.insert(index) }
        }
        let wakeIds = Set(wakeTasks.compactMap(\.wakeId))
        persistIndices(dirty, completion: { [weak self] persisted in
            if persisted { self?.enqueuePendingBackgroundWakes(persistedWakeIds: wakeIds) }
        })
    }

    private func enqueuePendingBackgroundWakes(persistedWakeIds: Set<UUID>) {
        guard isConnectionCurrent(), !stopped, !suppressingLoadReplay, holdsLeaseForWrite() else { return }
        let reobservedTaskIds = Set(session.backgroundTasks.filter { task in
            task.isActive && task.wakeId.map { persistedWakeIds.contains($0) } == true
        }.map(\.id))
        let queueChanged = retireReobservedBackgroundWakes(taskIds: reobservedTaskIds)
        let pending = pendingBackgroundWakeTasks(persistedWakeIds: persistedWakeIds)
        guard !pending.isEmpty || queueChanged else { return }
        for task in pending {
            enqueueBackgroundWake(for: task)
        }
        persistQueue(completion: { [weak self] persisted in
            guard let self, self.isConnectionCurrent() else { return }
            if persisted {
                self.flushQueueIfIdle()
            } else {
                self.markBackgroundWakeEnqueueFailed(tasks: pending)
            }
        })
    }

    private func retireReobservedBackgroundWakes(taskIds: Set<String>) -> Bool {
        var changed = false
        for index in Array(session.queue.indices.reversed()) where session.queue[index].canBatchBackgroundTaskWake {
            guard session.queue[index].backgroundTaskWakes.contains(where: {
                taskIds.contains($0.taskId)
            }) else { continue }
            var item = session.queue[index]
            guard item.removeBackgroundTaskWakes(taskIds: taskIds) else { continue }
            changed = true
            if item.backgroundTaskWakes.isEmpty {
                session.queue.remove(at: index)
            } else {
                session.queue[index] = item
            }
        }
        return changed
    }

    private func pendingBackgroundWakeTasks(persistedWakeIds: Set<UUID>) -> [ACPBackgroundTask] {
        session.backgroundTasks.filter { task in
            guard task.needsWake, let id = task.wakeId, persistedWakeIds.contains(id) else { return false }
            guard let item = session.queue.first(where: {
                $0.containsBackgroundTaskWake(taskId: task.id, wakeId: id)
            }) else { return true }
            return item.canBatchBackgroundTaskWake
        }
    }

    private func enqueueBackgroundWake(for task: ACPBackgroundTask) {
        guard let id = task.wakeId else { return }
        let block = ACPContentBlock.text(task.wakeText)
        if let index = session.queue.firstIndex(where: {
            $0.containsBackgroundTaskWake(taskId: task.id, wakeId: id)
        }) {
            _ = session.queue[index].upsertBackgroundTaskWake(
                taskId: task.id, wakeId: id, block: block)
            return
        }
        removeUndispatchedBackgroundWakes(taskId: task.id)
        let insertAt = session.queue.firstIndex {
            $0.status == .pending && ($0.scheduledAt != nil || $0.isHeld(by: session.usageLimit))
        } ?? session.queue.endIndex
        if insertAt > session.queue.startIndex,
           session.queue[insertAt - 1].canBatchBackgroundTaskWake {
            _ = session.queue[insertAt - 1].upsertBackgroundTaskWake(
                taskId: task.id, wakeId: id, block: block)
        } else {
            session.queue.insert(.init(id: id, blocks: [block],
                backgroundTaskWake: task.id, transcriptRecorded: true), at: insertAt)
        }
    }

    private func removeUndispatchedBackgroundWakes(taskId: String) {
        for index in Array(session.queue.indices.reversed())
            where session.queue[index].canBatchBackgroundTaskWake
                && session.queue[index].backgroundTaskWakes.contains(where: { $0.taskId == taskId }) {
            var item = session.queue[index]
            _ = item.removeBackgroundTaskWakes(taskIds: [taskId])
            if item.backgroundTaskWakes.isEmpty {
                session.queue.remove(at: index)
            } else {
                session.queue[index] = item
            }
        }
    }

    private func markBackgroundWakeEnqueueFailed(tasks: [ACPBackgroundTask]) {
        for task in tasks {
            guard let wakeId = task.wakeId,
                  let index = session.queue.firstIndex(where: {
                      $0.containsBackgroundTaskWake(taskId: task.id, wakeId: wakeId)
                  }) else { continue }
            session.queue[index].lastError =
                "Could not save background work notification; retry to deliver it."
        }
    }

    private func markBackgroundWakesDelivered(for item: QueuedPrompt) -> Set<Int> {
        var rows: Set<Int> = []
        for wake in item.backgroundTaskWakes {
            guard var task = session.backgroundTasks.first(where: { $0.id == wake.taskId }) else { continue }
            if task.wakeId == wake.wakeId, !task.wakeDelivered {
                task.wakeDelivered = true
                rows.formUnion(session.saveBackgroundTask(task))
            } else if let index = session.transcript.toolCallIndex(toolCallId: task.id) {
                // Confirming an older snapshot must preserve newer task facts,
                // including when their earlier write failed.
                rows.insert(index)
            }
        }
        return rows
    }

    private func restoreBackgroundWakesAfterFailedConfirmation(_ item: QueuedPrompt) -> Set<Int> {
        var restoredRows: Set<Int> = []
        for wake in item.backgroundTaskWakes {
            guard var task = session.backgroundTasks.first(where: {
                $0.id == wake.taskId && $0.wakeId == wake.wakeId
            }) else { continue }
            task.wakeDelivered = false
            restoredRows.formUnion(session.saveBackgroundTask(task))
        }
        return restoredRows
    }

    private func removeConfirmedBackgroundWake(_ item: QueuedPrompt) {
        session.queue.removeAll {
            $0.id == item.id && $0.brokerOperationAttempt == item.brokerOperationAttempt
        }
    }

    private func persistBackgroundWakeAndQueue(
        rows: Set<Int>, consuming item: QueuedPrompt, deliveredForkContext: Bool = false,
        acknowledging acknowledgement: ACPDurableConsumptionAcknowledgement? = nil
    ) {
        guard holdsLeaseForWrite() else { return }
        if let acknowledgement {
            backgroundWakeAcknowledgements[item.id, default: []].append(acknowledgement)
        }
        guard backgroundWakeConfirmations[item.id] == nil else { return }
        backgroundWakeConfirmations[item.id] = item.brokerOperationAttempt
        let messages = rows.sorted().compactMap { index -> ACPStoredMessage? in
            guard let payload = try? ACPMessageCodec.encode(session.transcript.messages[index]) else { return nil }
            return .init(id: messageRowID(index), sessionId: self.sessionId,
                kind: session.transcript.messages[index].kind, seq: Int64(index),
                payload: payload, createdAt: createdAt(forMessageAt: index))
        }
        let queueSnapshot = queueSnapshotForPersistence(consuming: item)
        let sessionId = sessionId
        let fence = leaseFenceProvider()
        session.pendingQueuePersistenceCount += 1
        enqueuePersistence({ persistence in
            let items = await queueSnapshot()
            return try await persistence.persistBackgroundWakeAndQueue(
                sessionId: sessionId, messages: messages, items: items,
                deliveredForkContext: deliveredForkContext, fence: fence)
        }, completion: { persisted in
            defer { self.backgroundWakeConfirmations.removeValue(forKey: item.id) }
            let acknowledgements = self.backgroundWakeAcknowledgements.removeValue(forKey: item.id) ?? []
            self.session.pendingQueuePersistenceCount -= 1
            if persisted == true {
                self.commitPersistedMessageRows(messages)
                // Committed delivery survives teardown; a newer retry under
                // the same wake ID still owns its separate attempt.
                self.removeConfirmedBackgroundWake(item)
                acknowledgements.forEach { $0() }
                guard self.isConnectionCurrent(), !self.stopped else { return }
                self.onPromptWorkChanged?()
                if !self.sendPendingQueueForceSendsAfterPersistence() { self.flushQueueIfIdle() }
            } else {
                guard let index = self.session.queue.firstIndex(where: {
                    $0.id == item.id && $0.brokerOperationAttempt == item.brokerOperationAttempt
                }) else { return }
                self.session.queue[index].status = .pending
                self.session.queue[index].lastError =
                    "Could not save background work delivery confirmation. Retry may repeat the notification."
                self.session.queue[index].deliveryUncertain = true
                let restoredRows = self.restoreBackgroundWakesAfterFailedConfirmation(item)
                if deliveredForkContext, var fork = self.session.forkRecord {
                    fork.contextDeliveryPending = true
                    self.session.forkRecord = fork
                }
                guard self.isConnectionCurrent(), !self.stopped, self.holdsLeaseForWrite() else { return }
                self.persistIndices(restoredRows)
                self.persistQueue(completion: { _ in self.onPromptWorkChanged?() })
            }
        })
    }

    @discardableResult
    func stopBackgroundTask(id: String) async -> Bool {
        guard isConnectionCurrent(), session.backgroundTaskStopSupported,
              let task = session.backgroundTasks.first(where: { $0.id == id }),
              task.isActive, task.canStop, !backgroundStopRequests.contains(id) else { return false }
        backgroundStopRequests.insert(id)
        defer { backgroundStopRequests.remove(id) }
        guard await hasConfirmedLeaseForSideEffect(), isConnectionCurrent() else { return false }
        var reachedAgent = false
        let errorMessage: String?
        do {
            // Both adapters keep the control runtime on the ROOT session even
            // when a notification is routed to a native child transcript.
            let stopped = try await connection.stopBackgroundTask(
                sessionId: session.remoteSessionId ?? sessionId, asyncTaskId: task.asyncTaskId)
            reachedAgent = true
            errorMessage = stopped ? nil : "The adapter did not stop this task."
            guard isConnectionCurrent(), holdsLeaseForWrite() else { return reachedAgent }
            if stopped, var current = session.backgroundTasks.first(where: { $0.id == id }), current.isActive {
                current.merge(.init(sessionUpdate: "async_task_state_update", asyncTaskId: current.asyncTaskId,
                    state: "stopped"), wakeOnCompletion: false)
                persistIndices(session.saveBackgroundTask(current))
            }
        } catch {
            errorMessage = "Could not stop task: \(error.localizedDescription)"
        }
        guard isConnectionCurrent(), holdsLeaseForWrite(),
              var current = session.backgroundTasks.first(where: { $0.id == id }),
              current.isActive else { return reachedAgent }
        current.stopError = errorMessage
        persistIndices(session.saveBackgroundTask(current))
        return reachedAgent
    }
}
