import Foundation
import SQLite3
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP

/// Serial, off-main owner of a worktree's writable ACP session store.
///
/// The initializer only records a path. Opening SQLite and running migrations
/// happen on this actor's executor when the first operation is awaited, so
/// constructing a manager on `MainActor` never performs database I/O.
///
/// The actor runs on a dispatch queue of its own, not the cooperative pool:
/// SQLite blocks its thread for every statement, and a few stores migrating
/// at once would otherwise hold every pool thread and starve unrelated tasks.
public actor ACPSessionPersistence: SessionSummaryStoring {
    public nonisolated let path: String
    private nonisolated let queue: DispatchSerialQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let busyTimeoutMilliseconds: Int32
    private var store: ACPSessionStore?
    private var hydrator: ACPSessionHydrator?

    public init(path: String, busyTimeoutMilliseconds: Int32 = 5_000) {
        self.path = path
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
        queue = DispatchSerialQueue(label: "io.nlopez.alas.acp-session-persistence \(path)")
    }

    private func openedStore() throws -> ACPSessionStore {
        if let store { return store }
        let opened = try ACPSessionStore(
            path: path,
            busyTimeoutMilliseconds: busyTimeoutMilliseconds
        )
        store = opened
        return opened
    }

    private func openedHydrator() throws -> ACPSessionHydrator {
        if let hydrator { return hydrator }
        let opened = try ACPSessionHydrator(path: path)
        hydrator = opened
        return opened
    }

    public func prepare() throws {
        _ = try openedStore()
    }

    public func hydrate(sessionId: String) async throws -> HydrationResult {
        try await openedHydrator().hydrate(sessionId: sessionId)
    }

    public func mirrorSnapshot(sessionId: String) async throws -> HydrationResult {
        try await openedHydrator().mirrorSnapshot(sessionId: sessionId)
    }

    public func recentSessions(limit: Int = 50) throws -> [ACPSessionRow] {
        try openedStore().recentSessions(limit: limit)
    }

    public func loadSession(id: String) throws -> ACPSessionRow? {
        try openedStore().loadSession(id: id)
    }

    public func setLastSeenAt(id: String, at: Int64) throws {
        try openedStore().setLastSeenAt(id: id, at: at)
    }

    public func loadLastSeenAt(id: String) throws -> Int64? {
        try openedStore().loadLastSeenAt(id: id)
    }

    public func loadSummarySourceSnapshot(sessionId: String) throws -> StoredSummarySourceSnapshot? {
        try openedStore().loadSummarySourceSnapshot(sessionId: sessionId)
    }

    public func loadSessionSummary(sessionId: String, inputHash: String, modelID: String) throws -> SessionSummary? {
        try openedStore().loadSessionSummary(sessionId: sessionId, inputHash: inputHash, modelID: modelID)
    }

    public func saveSessionSummary(sessionId: String, _ stored: StoredSessionSummary) throws {
        try openedStore().saveSessionSummary(sessionId: sessionId, stored)
    }

    public func deleteAllSessionSummaries() throws {
        try openedStore().deleteAllSessionSummaries()
    }

    public func createFork(
        session: ACPSessionRow,
        messages: [ACPStoredMessage],
        record: ACPSessionForkRecord
    ) throws {
        try openedStore().createFork(session: session, messages: messages, record: record)
    }

    public func loadFork(targetSessionID: String) throws -> ACPSessionForkRecord? {
        try openedStore().loadFork(targetSessionID: targetSessionID)
    }

    public func finalizeFork(
        targetSessionID: String,
        mechanism: ACPSessionForkMechanism,
        remoteSessionID: String?
    ) throws {
        try openedStore().finalizeFork(
            targetSessionID: targetSessionID,
            mechanism: mechanism,
            remoteSessionID: remoteSessionID
        )
    }

    public func clearForkContextDeliveryPending(targetSessionID: String) throws {
        try openedStore().clearForkContextDeliveryPending(targetSessionID: targetSessionID)
    }

    @discardableResult
    public func clearForkContextDeliveryPending(
        targetSessionID: String,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = {
            try store.clearForkContextDeliveryPending(targetSessionID: targetSessionID)
        }
        if let fence {
            return try store.withLeaseFence(fence, operation) != nil
        }
        try operation()
        return true
    }

    public func loadSession(agentId: String, remoteSessionId: String) throws -> ACPSessionRow? {
        try openedStore().loadSession(agentId: agentId, remoteSessionId: remoteSessionId)
    }

    public func prepareRemoteContextRecovery(fence: ACPSessionLeaseFence, procId: String) throws -> Bool {
        let store = try openedStore()
        return try store.withLeaseFence(fence) {
            try store.disableReplicaExport(sessionId: fence.sessionId)
            return try store.db.execChanges("""
                UPDATE sessions SET remote_session_id=NULL,context_recovery_pending=1,recovery_proc_id=?
                WHERE id=? AND recovery_proc_id IS NULL
                """, bindings: [procId, fence.sessionId]) == 1
        } ?? false
    }

    public func rotateRemoteRecoveryLease(fence: ACPSessionLeaseFence, pid: Int64, now: Int64, token: String) throws -> ACPSessionLease? {
        let store = try openedStore()
        // Nil when the fence no longer holds, or the session was archived
        // meanwhile and its lease cannot be taken.
        return try store.withLeaseFence(fence) { () -> ACPSessionLease? in
            guard try store.seizeLease(sessionId: fence.sessionId, instanceId: fence.ownerInstance, pid: pid, now: now, leaseToken: token) else {
                return nil
            }
            return ACPSessionLease(sessionId: fence.sessionId, ownerInstance: fence.ownerInstance, pid: pid, heartbeatAt: now, status: "idle", token: token)
        } ?? nil
    }

    public func completeRemoteContextRecoveryBinding(
        fence: ACPSessionLeaseFence, procId: String, remoteSessionId: String
    ) throws -> Bool {
        let store = try openedStore()
        return try store.withLeaseFence(fence) {
            return try store.db.execChanges("""
                UPDATE sessions SET remote_session_id=?,recovery_proc_id=NULL
                WHERE id=? AND recovery_proc_id=?
                """, bindings: [remoteSessionId, fence.sessionId, procId]) == 1
        } ?? false
    }

    public func upsertSession(_ row: ACPSessionRow, preserveTitle: Bool = false, preserveBrokerState: Bool = false) throws {
        try openedStore().upsertSession(row, preserveTitle: preserveTitle, preserveBrokerState: preserveBrokerState)
    }

    @discardableResult
    public func upsertSession(
        _ row: ACPSessionRow,
        preserveTitle: Bool = false,
        preserveBrokerState: Bool = false,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = { try store.upsertSession(row, preserveTitle: preserveTitle, preserveBrokerState: preserveBrokerState) }
        if let fence { return try store.withLeaseFence(fence, operation) != nil }
        try operation()
        return true
    }

    @discardableResult
    public func updateSessionFromRuntime(
        id: String,
        title: String,
        titleSource: ACPSessionTitleSource,
        currentModel: String?,
        currentMode: String?,
        configOptionValues: [String: ACPConfigValue]?,
        autoRun: Bool,
        preserveTitle: Bool,
        fence: ACPSessionLeaseFence?
    ) throws -> ACPSessionRow? {
        let store = try openedStore()
        let operation = {
            guard var row = try store.loadSession(id: id) else { return nil as ACPSessionRow? }
            if !preserveTitle {
                row.title = title
                row.titleSource = titleSource
            }
            row.currentModel = currentModel
            row.currentMode = currentMode
            if let configOptionValues {
                row.configOptionValues = configOptionValues
            }
            row.autoRun = autoRun
            row.updatedAt = Int64(Date().timeIntervalSince1970)
            try store.upsertSession(row, preserveTitle: preserveTitle)
            return row
        }
        if let fence {
            return try store.withLeaseFence(fence, operation) ?? nil
        }
        return try operation()
    }

    public func touchLastOpenedAt(id: String, at timestamp: Int64) throws {
        try openedStore().touchLastOpenedAt(id: id, at: timestamp)
    }

    public func setContextRecoveryPending(sessionId: String, pending: Bool) throws {
        try openedStore().setContextRecoveryPending(sessionId: sessionId, pending: pending)
    }

    public func setMCPPreamble(sessionId: String, pendingText: String?, sent: Bool) throws {
        try openedStore().setMCPPreamble(sessionId: sessionId, pendingText: pendingText, sent: sent)
    }

    @discardableResult
    public func setUsageLimit(sessionId: String, limit: ACPUsageLimit?, fence: ACPSessionLeaseFence?) throws -> Bool {
        let store = try openedStore()
        let operation = { try store.setUsageLimit(sessionId: sessionId, limit: limit) }
        if let fence { return try store.withLeaseFence(fence, operation) != nil }
        try operation()
        return true
    }

    public func setDirectTurnInFlight(sessionId: String, inFlight: Bool, fence: ACPSessionLeaseFence?) throws -> Bool {
        let store = try openedStore()
        let operation = { try store.setDirectTurnInFlight(sessionId: sessionId, inFlight: inFlight) }
        if let fence { return try store.withLeaseFence(fence, operation) != nil }
        try operation()
        return true
    }

    public func setAuthStatus(sessionId: String, status: ACPAuthStatus?) throws {
        try openedStore().setAuthStatus(sessionId: sessionId, status: status)
    }

    public func setPromptSuggestions(sessionId: String, suggestions: [ACPPromptSuggestion]?, fence: ACPSessionLeaseFence?) throws {
        let store = try openedStore()
        let operation = { try store.setPromptSuggestions(sessionId: sessionId, suggestions: suggestions) }
        if let fence { _ = try store.withLeaseFence(fence, operation) }
        else { try operation() }
    }

    /// Ack-gated callers use this form: `false` means the lease fence was
    /// already lost or the write failed, so the broker must replay the update.
    public func setPromptSuggestionsAndReport(
        sessionId: String,
        suggestions: [ACPPromptSuggestion]?,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = { () -> Bool in
            try store.setPromptSuggestions(sessionId: sessionId, suggestions: suggestions)
            return true
        }
        if let fence { return (try store.withLeaseFence(fence, operation)) ?? false }
        try operation()
        return true
    }

    @discardableResult
    public func updateHelperProcOffsets(
        sessionId: String,
        stdoutOffset: Int64?,
        stderrOffset: Int64?,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = {
            try store.updateHelperProcOffsets(
                sessionId: sessionId,
                stdoutOffset: stdoutOffset,
                stderrOffset: stderrOffset
            )
        }
        if let fence { return try store.withLeaseFence(fence, operation) ?? false }
        return try operation()
    }

    @discardableResult
    public func resetHelperProcOffsets(
        sessionId: String,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = { try store.resetHelperProcOffsets(sessionId: sessionId) }
        if let fence { return try store.withLeaseFence(fence, operation) ?? false }
        return try operation()
    }

    @discardableResult
    public func updateACPBrokerState(
        sessionId: String,
        state: ACPBrokerDurableState,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let generation = try sqliteBrokerInt64(state.generation.rawValue, field: "generation")
        let acknowledgedCursor = try sqliteBrokerInt64(
            state.acknowledgedCursor.rawValue,
            field: "acknowledged cursor"
        )
        let operation = {
            try store.updateACPBrokerState(
                sessionId: sessionId,
                brokerId: state.brokerId.rawValue,
                generation: generation,
                acknowledgedCursor: acknowledgedCursor,
                wireContext: state.wireContext
            )
        }
        if let fence { return try store.withLeaseFence(fence, operation) ?? false }
        return try operation()
    }

    @discardableResult
    public func updateACPBrokerAcknowledgedCursor(
        sessionId: String,
        state: ACPBrokerDurableState,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let generation = try sqliteBrokerInt64(state.generation.rawValue, field: "generation")
        let acknowledgedCursor = try sqliteBrokerInt64(
            state.acknowledgedCursor.rawValue,
            field: "acknowledged cursor"
        )
        let operation = {
            try store.updateACPBrokerAcknowledgedCursor(
                sessionId: sessionId,
                brokerId: state.brokerId.rawValue,
                generation: generation,
                cursor: acknowledgedCursor,
                wireContext: state.wireContext
            )
        }
        if let fence { return try store.withLeaseFence(fence, operation) ?? false }
        return try operation()
    }

    @discardableResult
    public func clearACPBrokerState(
        sessionId: String,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = { try store.clearACPBrokerState(sessionId: sessionId) }
        if let fence { return try store.withLeaseFence(fence, operation) ?? false }
        return try operation()
    }

    private func sqliteBrokerInt64(_ value: UInt64, field: String) throws -> Int64 {
        guard value <= UInt64(Int64.max) else {
            throw ACPSessionPersistenceError.brokerValueOutOfRange(field: field, value: value)
        }
        return Int64(value)
    }

    @discardableResult
    public func setContextRecoveryPending(
        sessionId: String,
        pending: Bool,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = { try store.setContextRecoveryPending(sessionId: sessionId, pending: pending) }
        if let fence { return try store.withLeaseFence(fence, operation) != nil }
        try operation()
        return true
    }

    @discardableResult
    public func setAuthStatus(
        sessionId: String,
        status: ACPAuthStatus?,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = { try store.setAuthStatus(sessionId: sessionId, status: status) }
        if let fence { return try store.withLeaseFence(fence, operation) != nil }
        try operation()
        return true
    }

    @discardableResult
    public func setMCPPreamble(
        sessionId: String,
        pendingText: String?,
        sent: Bool,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = { try store.setMCPPreamble(sessionId: sessionId, pendingText: pendingText, sent: sent) }
        if let fence { return try store.withLeaseFence(fence, operation) != nil }
        try operation()
        return true
    }

    public func deleteSession(id: String) throws {
        try openedStore().deleteSession(id: id)
    }

    public func orphanedEphemeralSessions(now: Int64, staleAfter: Int64, sessionId: String? = nil) throws -> [ACPSessionRow] {
        try openedStore().orphanedEphemeralSessions(now: now, staleAfter: staleAfter, sessionId: sessionId)
    }

    public func deleteOrphanedEphemeralSession(
        id: String,
        now: Int64,
        staleAfter: Int64,
        fence: ACPSessionLeaseFence? = nil
    ) throws -> Bool {
        try openedStore().deleteOrphanedEphemeralSession(id: id, now: now, staleAfter: staleAfter, fence: fence)
    }

    public func markEphemeralCleanupPending(id: String) throws -> Bool {
        try openedStore().markEphemeralCleanupPending(id: id)
    }

    public func promoteEphemeralSession(id: String) throws -> Bool {
        try openedStore().promoteEphemeralSession(id: id)
    }

    public func setArchived(id: String, archived: Bool) throws {
        try openedStore().setArchived(id: id, archived: archived)
    }

    public func setArchived(id: String, archived: Bool, fence: ACPSessionLeaseFence) throws -> Bool {
        let store = try openedStore()
        return try store.withLeaseFence(fence) {
            try store.setArchived(id: id, archived: archived)
        } != nil
    }

    public func renameSession(
        id: String,
        title: String,
        titleSource: ACPSessionTitleSource,
        updatedAt: Int64
    ) throws -> Bool {
        try openedStore().renameSession(
            id: id,
            title: title,
            titleSource: titleSource,
            updatedAt: updatedAt
        )
    }

    public func updateFallbackTitleIfPlaceholder(id: String, title: String, updatedAt: Int64) throws -> Bool {
        try openedStore().updateFallbackTitleIfPlaceholder(id: id, title: title, updatedAt: updatedAt)
    }

    public func renameSession(
        id: String,
        title: String,
        titleSource: ACPSessionTitleSource,
        updatedAt: Int64,
        ifStillTitled expected: String,
        source expectedSource: ACPSessionTitleSource
    ) throws -> Bool {
        try openedStore().renameSession(
            id: id, title: title, titleSource: titleSource, updatedAt: updatedAt,
            ifStillTitled: expected, source: expectedSource
        )
    }

    public func updateFallbackTitleIfPlaceholder(
        id: String,
        title: String,
        updatedAt: Int64,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = {
            try store.updateFallbackTitleIfPlaceholder(id: id, title: title, updatedAt: updatedAt)
        }
        if let fence { return try store.withLeaseFence(fence, operation) ?? false }
        return try operation()
    }
    public func updateLocalTitleIfFallback(
        id: String,
        title: String,
        updatedAt: Int64,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = {
            try store.updateLocalTitleIfFallback(id: id, title: title, updatedAt: updatedAt)
        }
        if let fence { return try store.withLeaseFence(fence, operation) ?? false }
        return try operation()
    }

    public func updateGeneratedTitleIfNotManual(id: String, title: String, updatedAt: Int64) throws -> Bool {
        try openedStore().updateGeneratedTitleIfNotManual(id: id, title: title, updatedAt: updatedAt)
    }

    public func updateGeneratedTitleIfNotManual(
        id: String,
        title: String,
        updatedAt: Int64,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = {
            try store.updateGeneratedTitleIfNotManual(id: id, title: title, updatedAt: updatedAt)
        }
        if let fence { return try store.withLeaseFence(fence, operation) ?? false }
        return try operation()
    }

    public func clearGeneratedTitleIfNotManual(id: String, updatedAt: Int64) throws -> Bool {
        try openedStore().clearGeneratedTitleIfNotManual(id: id, updatedAt: updatedAt)
    }

    public func clearGeneratedTitleIfNotManual(
        id: String,
        updatedAt: Int64,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = { try store.clearGeneratedTitleIfNotManual(id: id, updatedAt: updatedAt) }
        if let fence { return try store.withLeaseFence(fence, operation) ?? false }
        return try operation()
    }

    public func setGoalDraft(sessionId: String, objective: String) throws {
        try openedStore().setGoalDraft(sessionId: sessionId, objective: objective)
    }

    public func clearGoalDraft(sessionId: String, matching objective: String) throws {
        try openedStore().clearGoalDraft(sessionId: sessionId, matching: objective)
    }

    public func loadComposerDraftRecord(sessionId: String) throws -> ACPStoredComposerDraft? {
        try openedStore().loadComposerDraftRecord(sessionId: sessionId)
    }

    public func upsertComposerDraft(
        sessionId: String,
        draft: ACPComposerDraft,
        updatedAt: Int64,
        submittedRecovery: Bool = false,
        submittedAfterSeq: Int64? = nil
    ) throws {
        try openedStore().upsertComposerDraft(
            sessionId: sessionId,
            draft: draft,
            updatedAt: updatedAt,
            submittedRecovery: submittedRecovery,
            submittedAfterSeq: submittedAfterSeq
        )
    }

    @discardableResult
    public func upsertComposerDraft(
        sessionId: String,
        draft: ACPComposerDraft,
        updatedAt: Int64,
        submittedRecovery: Bool = false,
        submittedAfterSeq: Int64? = nil,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = {
            try store.upsertComposerDraft(
                sessionId: sessionId,
                draft: draft,
                updatedAt: updatedAt,
                submittedRecovery: submittedRecovery,
                submittedAfterSeq: submittedAfterSeq
            )
        }
        if let fence { return try store.withLeaseFence(fence, operation) != nil }
        try operation()
        return true
    }

    public func deleteComposerDraft(sessionId: String) throws {
        try openedStore().deleteComposerDraft(sessionId: sessionId)
    }

    @discardableResult
    public func deleteComposerDraft(
        sessionId: String,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = { try store.deleteComposerDraft(sessionId: sessionId) }
        if let fence { return try store.withLeaseFence(fence, operation) != nil }
        try operation()
        return true
    }

    public func deleteComposerDraft(sessionId: String, matching stored: ACPStoredComposerDraft) throws -> Bool {
        try openedStore().deleteComposerDraft(sessionId: sessionId, matching: stored)
    }

    @discardableResult
    public func recordPermissionDecision(
        sessionId: String,
        scopeKey: String,
        decision: ACPPermissionDecision,
        scope: ACPPermissionScopeKind,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let decidedAt = Int64(Date().timeIntervalSince1970)
        let operation = {
            try store.recordPermissionDecision(
                sessionId: sessionId,
                scopeKey: scopeKey,
                decision: decision,
                scope: scope,
                decidedAt: decidedAt
            )
        }
        if let fence { return try store.withLeaseFence(fence, operation) != nil }
        try operation()
        return true
    }

    public func lookupPermissionDecision(sessionId: String, scopeKey: String) throws -> ACPPermissionDecision? {
        try openedStore().lookupPermissionDecision(sessionId: sessionId, scopeKey: scopeKey)
    }

    public func appendMessage(
        sessionId: String,
        id: String,
        kind: String,
        seq: Int64,
        payload: Data,
        createdAt: Int64
    ) throws {
        try openedStore().appendMessage(
            sessionId: sessionId,
            id: id,
            kind: kind,
            seq: seq,
            payload: payload,
            createdAt: createdAt
        )
    }

    @discardableResult
    public func persistMessages(
        _ messages: [ACPStoredMessage],
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        if let fence {
            return try store.withLeaseFence(fence) {
                try store.upsertMessages(messages)
            } != nil
        }
        try store.upsertMessages(messages)
        return true
    }

    /// See `ACPSessionStore.closeMessageSequenceGaps`. Fenced like a row
    /// write, since it moves rows other writers address by position.
    @discardableResult
    public func closeMessageSequenceGaps(
        sessionId: String,
        loadedMessageCount: Int,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = {
            try store.closeMessageSequenceGaps(sessionId: sessionId, loadedMessageCount: loadedMessageCount)
        }
        if let fence { return try store.withLeaseFence(fence, operation) ?? false }
        return try store.db.transaction(operation)
    }

    /// Child-session transcript rows. Fenced exactly like parent rows so a
    /// process that lost the lease can't keep writing a child's output.
    public func persistSubagentMessages(
        _ messages: [ACPStoredSubagentMessage],
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        if let fence {
            return try store.withLeaseFence(fence) {
                try store.upsertSubagentMessages(messages)
            } != nil
        }
        try store.upsertSubagentMessages(messages)
        return true
    }

    @discardableResult
    public func insertMessageIfMissing(_ message: ACPStoredMessage) throws -> Bool {
        try openedStore().insertMessageIfMissing(message)
    }

    public func compareAndSwapMessagePayload(
        id: String,
        sessionId: String,
        payload: Data,
        expectedPayload: Data
    ) throws -> Bool {
        try openedStore().updateMessagePayloadIfUnchanged(
            id: id,
            sessionId: sessionId,
            payload: payload,
            expectedPayload: expectedPayload
        )
    }

    public func updateMessagePayload(id: String, payload: Data) throws {
        try openedStore().updateMessagePayload(id: id, payload: payload)
    }

    public func updateMessageRow(id: String, kind: String, seq: Int64, payload: Data) throws -> Bool {
        try openedStore().updateMessageRow(id: id, kind: kind, seq: seq, payload: payload)
    }

    public func updateMessagePayloadIfUnchanged(
        id: String,
        sessionId: String,
        payload: Data,
        expectedPayload: Data
    ) throws -> Bool {
        try openedStore().updateMessagePayloadIfUnchanged(
            id: id,
            sessionId: sessionId,
            payload: payload,
            expectedPayload: expectedPayload
        )
    }

    public func loadMessagePayload(id: String) throws -> Data? {
        try openedStore().loadMessagePayload(id: id)
    }

    public func loadMessagePayload(id: String, fence: ACPSessionLeaseFence) throws -> Data? {
        let store = try openedStore()
        return try store.withLeaseFence(fence) {
            try store.loadMessagePayload(id: id)
        } ?? nil
    }

    public func messageCount(sessionId: String) throws -> Int {
        try openedStore().messageCount(sessionId: sessionId)
    }

    public func latestMessageSeq(sessionId: String) throws -> Int64? {
        try openedStore().latestMessageSeq(sessionId: sessionId)
    }

    public func loadMessages(sessionId: String) throws -> [ACPStoredMessage] {
        try openedStore().loadMessages(sessionId: sessionId)
    }

    public func loadToolCallContent(sessionId: String, toolCallId: String) throws -> String? {
        try openedStore().loadToolCallContent(sessionId: sessionId, toolCallId: toolCallId)
    }

    public func upsertQueue(sessionId: String, items: [QueuedPrompt]) throws {
        try openedStore().upsertQueue(sessionId: sessionId, items: items)
    }

    @discardableResult
    public func upsertQueue(
        sessionId: String,
        items: [QueuedPrompt],
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = { try store.upsertQueue(sessionId: sessionId, items: items) }
        if let fence { return try store.withLeaseFence(fence, operation) != nil }
        try operation()
        return true
    }

    /// Commit a recorded prompt and its recovery binding together so a
    /// restart cannot see one without the other.
    @discardableResult
    public func persistMessagesAndQueue(
        _ messages: [ACPStoredMessage], sessionId: String,
        items: [QueuedPrompt], fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = {
            try store.upsertMessages(messages)
            try store.upsertQueue(sessionId: sessionId, items: items)
        }
        if let fence { return try store.withLeaseFence(fence, operation) != nil }
        try store.db.transaction(operation)
        return true
    }

    public func loadQueue(sessionId: String) throws -> [QueuedPrompt] {
        try openedStore().loadQueue(sessionId: sessionId)
    }

    /// Completion delivery and queue removal share a transaction. Otherwise a
    /// crash between those writes could recreate an already delivered wake.
    public func persistBackgroundWakeAndQueue(
        sessionId: String, messages: [ACPStoredMessage], items: [QueuedPrompt],
        deliveredForkContext: Bool = false,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = {
            try store.upsertMessages(messages)
            try store.upsertQueue(sessionId: sessionId, items: items)
            if deliveredForkContext { try store.clearForkContextDeliveryPending(targetSessionID: sessionId) }
        }
        if let fence { return try store.withLeaseFence(fence, operation) != nil }
        try store.db.transaction(operation)
        return true
    }

    public func scheduledQueueSessionIds() throws -> [String] {
        try openedStore().scheduledQueueSessionIds()
    }

    public func interruptedQueueSessionIds() throws -> [String] {
        try openedStore().interruptedQueueSessionIds()
    }

    public func loadLease(sessionId: String) throws -> ACPSessionLease? {
        try openedStore().loadLease(sessionId: sessionId)
    }

    public func activeLeaseCount(now: Int64, staleAfter: Int64) throws -> Int {
        try openedStore().activeLeaseCount(now: now, staleAfter: staleAfter)
    }

    public func claimLease(
        sessionId: String,
        instanceId: String,
        pid: Int64,
        now: Int64,
        staleAfter: Int64,
        leaseToken: String,
        replaceOwnedToken: Bool = false
    ) throws -> ACPSessionLease? {
        let store = try openedStore()
        let won = try store.claimLease(
            sessionId: sessionId,
            instanceId: instanceId,
            pid: pid,
            now: now,
            staleAfter: staleAfter,
            leaseToken: leaseToken,
            replaceOwnedToken: replaceOwnedToken
        )
        return won ? try store.loadLease(sessionId: sessionId) : nil
    }

    public func refreshHeartbeat(sessionId: String, instanceId: String, now: Int64, status: String) throws {
        try openedStore().refreshHeartbeat(
            sessionId: sessionId,
            instanceId: instanceId,
            now: now,
            status: status
        )
    }

    public func releaseLease(sessionId: String, instanceId: String, leaseToken: String? = nil) throws {
        try openedStore().releaseLease(
            sessionId: sessionId,
            instanceId: instanceId,
            leaseToken: leaseToken
        )
    }

    public func seizeLease(
        sessionId: String,
        instanceId: String,
        pid: Int64,
        now: Int64,
        leaseToken: String
    ) throws -> ACPSessionLease {
        let store = try openedStore()
        guard try store.seizeLease(
            sessionId: sessionId,
            instanceId: instanceId,
            pid: pid,
            now: now,
            leaseToken: leaseToken
        ) else { throw ACPSessionLeaseRefusal.archived }
        guard let lease = try store.loadLease(sessionId: sessionId) else {
            throw SQLiteError.stepFailed(code: SQLITE_ERROR, message: "Lease seizure did not persist", sql: "session_leases")
        }
        return lease
    }
}

extension ACPSessionPersistence {
    public func replicaChangeEvents() throws -> AsyncStream<Void> {
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observerId = UUID()
        try openedStore().db.observeReplicaChanges(id: observerId) { continuation.yield(()) }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeReplicaChangeObserver(id: observerId) }
        }
        return events
    }

    private func removeReplicaChangeObserver(id: UUID) {
        store?.db.removeReplicaChangeObserver(id: id)
    }

    public func enableReplicaExport(sessionId: String, recordId: String, localFence: ACPSessionLeaseFence? = nil) throws {
        try openedStore().enableReplicaExport(sessionId: sessionId, recordId: recordId, localFence: localFence)
    }

    public func disableReplicaExport(sessionId: String, localFence: ACPSessionLeaseFence? = nil) throws {
        let store = try openedStore()
        if let localFence {
            guard localFence.sessionId == sessionId else { throw ACPSessionReplicaError.localWriterActive }
            _ = try store.withLeaseFence(localFence) { try store.disableReplicaExport(sessionId: sessionId) }
        } else { try store.disableReplicaExport(sessionId: sessionId) }
    }

    public func replicaChanges(sessionId: String, limit: Int) throws -> ACPSessionReplicaExport? {
        try openedStore().replicaChanges(sessionId: sessionId, limit: limit)
    }

    public func acknowledgeReplicaChanges(sessionId: String, export: ACPSessionReplicaExport) throws {
        try openedStore().acknowledgeReplicaChanges(sessionId: sessionId, export: export)
    }

    public func stageReplicaPage(sessionId: String, recordId: String, page: RemoteSessionReadResult) throws {
        try openedStore().stageReplicaPage(sessionId: sessionId, recordId: recordId, page: page)
    }

    public func commitReplicaImport(importGuard: ACPSessionReplicaImportGuard) throws -> Int64 {
        try openedStore().commitReplicaImport(importGuard: importGuard)
    }

    public func discardReplicaImport(sessionId: String) throws {
        try openedStore().discardReplicaImport(sessionId: sessionId)
    }

    public func replicaRevision(sessionId: String, recordId: String) throws -> Int64 {
        try openedStore().replicaRevision(sessionId: sessionId, recordId: recordId)
    }

    public func resolveReplicaRelations() throws {
        try openedStore().resolveReplicaRelations()
    }
}
