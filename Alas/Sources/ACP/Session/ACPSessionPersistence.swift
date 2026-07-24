import Foundation
import SQLite3

private enum ACPSessionPersistenceError: Error, LocalizedError {
    case brokerValueOutOfRange(field: String, value: UInt64)

    var errorDescription: String? {
        switch self {
        case .brokerValueOutOfRange(let field, let value):
            return "ACP broker \(field) is out of SQLite Int64 range: \(value)"
        }
    }
}

/// Serial, off-main owner of a worktree's writable ACP session store.
///
/// The initializer only records a path. Opening SQLite and running migrations
/// happen on this actor's executor when the first operation is awaited, so
/// constructing a manager on `MainActor` never performs database I/O.
actor ACPSessionPersistence {
    nonisolated let path: String

    private let busyTimeoutMilliseconds: Int32
    private var store: ACPSessionStore?
    private var hydrator: ACPSessionHydrator?

    init(path: String, busyTimeoutMilliseconds: Int32 = 5_000) {
        self.path = path
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
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

    func prepare() throws {
        _ = try openedStore()
    }

    func hydrate(sessionId: String) async throws -> HydrationResult {
        try await openedHydrator().hydrate(sessionId: sessionId)
    }

    func mirrorSnapshot(sessionId: String) async throws -> HydrationResult {
        try await openedHydrator().mirrorSnapshot(sessionId: sessionId)
    }

    func recentSessions(limit: Int = 50) throws -> [ACPSessionRow] {
        try openedStore().recentSessions(limit: limit)
    }

    func loadSession(id: String) throws -> ACPSessionRow? {
        try openedStore().loadSession(id: id)
    }

    func createFork(
        session: ACPSessionRow,
        messages: [ACPStoredMessage],
        record: ACPSessionForkRecord
    ) throws {
        try openedStore().createFork(session: session, messages: messages, record: record)
    }

    func loadFork(targetSessionID: String) throws -> ACPSessionForkRecord? {
        try openedStore().loadFork(targetSessionID: targetSessionID)
    }

    func finalizeFork(
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

    func clearForkContextDeliveryPending(targetSessionID: String) throws {
        try openedStore().clearForkContextDeliveryPending(targetSessionID: targetSessionID)
    }

    @discardableResult
    func clearForkContextDeliveryPending(
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

    func loadSession(agentId: String, remoteSessionId: String) throws -> ACPSessionRow? {
        try openedStore().loadSession(agentId: agentId, remoteSessionId: remoteSessionId)
    }

    func upsertSession(_ row: ACPSessionRow, preserveTitle: Bool = false) throws {
        try openedStore().upsertSession(row, preserveTitle: preserveTitle)
    }

    @discardableResult
    func upsertSession(
        _ row: ACPSessionRow,
        preserveTitle: Bool = false,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = { try store.upsertSession(row, preserveTitle: preserveTitle) }
        if let fence { return try store.withLeaseFence(fence, operation) != nil }
        try operation()
        return true
    }

    @discardableResult
    func updateSessionFromRuntime(
        id: String,
        title: String,
        titleSource: ACPSessionTitleSource,
        currentModel: String?,
        currentMode: String?,
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

    func touchLastOpenedAt(id: String, at timestamp: Int64) throws {
        try openedStore().touchLastOpenedAt(id: id, at: timestamp)
    }

    func setContextRecoveryPending(sessionId: String, pending: Bool) throws {
        try openedStore().setContextRecoveryPending(sessionId: sessionId, pending: pending)
    }

    func setMCPPreamble(sessionId: String, pendingText: String?, sent: Bool) throws {
        try openedStore().setMCPPreamble(sessionId: sessionId, pendingText: pendingText, sent: sent)
    }

    @discardableResult
    func updateHelperProcOffsets(
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
    func resetHelperProcOffsets(
        sessionId: String,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = { try store.resetHelperProcOffsets(sessionId: sessionId) }
        if let fence { return try store.withLeaseFence(fence, operation) ?? false }
        return try operation()
    }

    @discardableResult
    func updateACPBrokerState(
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
                acknowledgedCursor: acknowledgedCursor
            )
        }
        if let fence { return try store.withLeaseFence(fence, operation) ?? false }
        return try operation()
    }

    @discardableResult
    func updateACPBrokerAcknowledgedCursor(
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
                cursor: acknowledgedCursor
            )
        }
        if let fence { return try store.withLeaseFence(fence, operation) ?? false }
        return try operation()
    }

    @discardableResult
    func clearACPBrokerState(
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
    func setContextRecoveryPending(
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
    func setMCPPreamble(
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

    func deleteSession(id: String) throws {
        try openedStore().deleteSession(id: id)
    }

    func setArchived(id: String, archived: Bool) throws {
        try openedStore().setArchived(id: id, archived: archived)
    }

    func renameSession(
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

    func updateGeneratedTitleIfPlaceholder(id: String, title: String, updatedAt: Int64) throws -> Bool {
        try openedStore().updateGeneratedTitleIfPlaceholder(id: id, title: title, updatedAt: updatedAt)
    }

    func updateGeneratedTitleIfPlaceholder(
        id: String,
        title: String,
        updatedAt: Int64,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = {
            try store.updateGeneratedTitleIfPlaceholder(id: id, title: title, updatedAt: updatedAt)
        }
        if let fence { return try store.withLeaseFence(fence, operation) ?? false }
        return try operation()
    }

    func updateGeneratedTitleIfNotManual(id: String, title: String, updatedAt: Int64) throws -> Bool {
        try openedStore().updateGeneratedTitleIfNotManual(id: id, title: title, updatedAt: updatedAt)
    }

    func updateGeneratedTitleIfNotManual(
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

    func clearGeneratedTitleIfNotManual(id: String, updatedAt: Int64) throws -> Bool {
        try openedStore().clearGeneratedTitleIfNotManual(id: id, updatedAt: updatedAt)
    }

    func clearGeneratedTitleIfNotManual(
        id: String,
        updatedAt: Int64,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = { try store.clearGeneratedTitleIfNotManual(id: id, updatedAt: updatedAt) }
        if let fence { return try store.withLeaseFence(fence, operation) ?? false }
        return try operation()
    }

    func loadComposerDraftRecord(sessionId: String) throws -> ACPStoredComposerDraft? {
        try openedStore().loadComposerDraftRecord(sessionId: sessionId)
    }

    func upsertComposerDraft(
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
    func upsertComposerDraft(
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

    func deleteComposerDraft(sessionId: String) throws {
        try openedStore().deleteComposerDraft(sessionId: sessionId)
    }

    @discardableResult
    func deleteComposerDraft(
        sessionId: String,
        fence: ACPSessionLeaseFence?
    ) throws -> Bool {
        let store = try openedStore()
        let operation = { try store.deleteComposerDraft(sessionId: sessionId) }
        if let fence { return try store.withLeaseFence(fence, operation) != nil }
        try operation()
        return true
    }

    func deleteComposerDraft(sessionId: String, matching stored: ACPStoredComposerDraft) throws -> Bool {
        try openedStore().deleteComposerDraft(sessionId: sessionId, matching: stored)
    }

    @discardableResult
    func recordPermissionDecision(
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

    func lookupPermissionDecision(sessionId: String, scopeKey: String) throws -> ACPPermissionDecision? {
        try openedStore().lookupPermissionDecision(sessionId: sessionId, scopeKey: scopeKey)
    }

    func appendMessage(
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
    func persistMessages(
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

    @discardableResult
    func insertMessageIfMissing(_ message: ACPStoredMessage) throws -> Bool {
        try openedStore().insertMessageIfMissing(message)
    }

    func compareAndSwapMessagePayload(
        id: String,
        payload: Data,
        expectedPayload: Data
    ) throws -> Bool {
        try openedStore().updateMessagePayloadIfUnchanged(
            id: id,
            payload: payload,
            expectedPayload: expectedPayload
        )
    }

    func updateMessagePayload(id: String, payload: Data) throws {
        try openedStore().updateMessagePayload(id: id, payload: payload)
    }

    func updateMessageRow(id: String, kind: String, seq: Int64, payload: Data) throws -> Bool {
        try openedStore().updateMessageRow(id: id, kind: kind, seq: seq, payload: payload)
    }

    func updateMessagePayloadIfUnchanged(
        id: String,
        payload: Data,
        expectedPayload: Data
    ) throws -> Bool {
        try openedStore().updateMessagePayloadIfUnchanged(
            id: id,
            payload: payload,
            expectedPayload: expectedPayload
        )
    }

    func loadMessagePayload(id: String) throws -> Data? {
        try openedStore().loadMessagePayload(id: id)
    }

    func loadMessagePayload(id: String, fence: ACPSessionLeaseFence) throws -> Data? {
        let store = try openedStore()
        return try store.withLeaseFence(fence) {
            try store.loadMessagePayload(id: id)
        } ?? nil
    }

    func messageCount(sessionId: String) throws -> Int {
        try openedStore().messageCount(sessionId: sessionId)
    }

    func latestMessageSeq(sessionId: String) throws -> Int64? {
        try openedStore().latestMessageSeq(sessionId: sessionId)
    }

    func loadMessages(sessionId: String) throws -> [ACPStoredMessage] {
        try openedStore().loadMessages(sessionId: sessionId)
    }

    func loadToolCallContent(sessionId: String, toolCallId: String) throws -> String? {
        try openedStore().loadToolCallContent(sessionId: sessionId, toolCallId: toolCallId)
    }

    func upsertQueue(sessionId: String, items: [QueuedPrompt]) throws {
        try openedStore().upsertQueue(sessionId: sessionId, items: items)
    }

    @discardableResult
    func upsertQueue(
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

    func loadQueue(sessionId: String) throws -> [QueuedPrompt] {
        try openedStore().loadQueue(sessionId: sessionId)
    }

    func loadLease(sessionId: String) throws -> ACPSessionLease? {
        try openedStore().loadLease(sessionId: sessionId)
    }

    func claimLease(
        sessionId: String,
        instanceId: String,
        pid: Int64,
        now: Int64,
        staleAfter: Int64,
        leaseToken: String
    ) throws -> ACPSessionLease? {
        let store = try openedStore()
        let won = try store.claimLease(
            sessionId: sessionId,
            instanceId: instanceId,
            pid: pid,
            now: now,
            staleAfter: staleAfter,
            leaseToken: leaseToken
        )
        return won ? try store.loadLease(sessionId: sessionId) : nil
    }

    func refreshHeartbeat(sessionId: String, instanceId: String, now: Int64, status: String) throws {
        try openedStore().refreshHeartbeat(
            sessionId: sessionId,
            instanceId: instanceId,
            now: now,
            status: status
        )
    }

    func releaseLease(sessionId: String, instanceId: String, leaseToken: String? = nil) throws {
        try openedStore().releaseLease(
            sessionId: sessionId,
            instanceId: instanceId,
            leaseToken: leaseToken
        )
    }

    func seizeLease(
        sessionId: String,
        instanceId: String,
        pid: Int64,
        now: Int64,
        leaseToken: String
    ) throws -> ACPSessionLease {
        let store = try openedStore()
        try store.seizeLease(
            sessionId: sessionId,
            instanceId: instanceId,
            pid: pid,
            now: now,
            leaseToken: leaseToken
        )
        guard let lease = try store.loadLease(sessionId: sessionId) else {
            throw SQLiteError.stepFailed(code: SQLITE_ERROR, message: "Lease seizure did not persist", sql: "session_leases")
        }
        return lease
    }
}
