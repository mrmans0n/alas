import Foundation

@MainActor
final class WorkspaceEditUndoCoordinator {
    private final class Operation {
        var recordID: UUID
        let documents: Set<EditorDocumentID>
        var buffers: [EditorDocumentID: EditorBuffer]
        var reopenedWatchGenerations: [EditorDocumentID: Int] = [:]
        var undone = false
        var pendingRecovery: UUID?

        init(recordID: UUID, documents: Set<EditorDocumentID>, buffers: [EditorDocumentID: EditorBuffer]) {
            self.recordID = recordID
            self.documents = documents
            self.buffers = buffers
        }
    }

    private let access: any WorkspaceEditFileAccess
    let journal: WorkspaceEditJournal
    let executor: WorkspaceEditExecutor
    private let bufferForDocument: (EditorDocumentID) -> EditorBuffer?
    private var operations: [UUID: Operation] = [:]
    private(set) var isRunning = false
    private(set) var retainedJournalIDs: Set<UUID> = []
    private(set) var lastOutcome: WorkspaceEditOutcome?

    init(access: any WorkspaceEditFileAccess, journal: WorkspaceEditJournal, bufferForDocument: @escaping (EditorDocumentID) -> EditorBuffer?) {
        self.access = access
        self.journal = journal
        self.executor = WorkspaceEditExecutor(access: access, journal: journal)
        self.bufferForDocument = bufferForDocument
    }

    /// Only a fully confirmed executor journal can arm shared undo markers.
    /// Each marker addresses this one entry, including its inverse journals.
    func register(operationID: UUID, affectedDocuments: Set<EditorDocumentID>) {
        guard operations[operationID] == nil,
              let record = try? journal.record(operationID), record.status == .applied,
              !record.entries.isEmpty, record.entries.allSatisfy({ $0.state == .confirmed }) else { return }
        let documents = affectedDocuments.union(record.entries.flatMap { [$0.step.document, $0.step.destination].compactMap { $0 } })
        var buffers: [EditorDocumentID: EditorBuffer] = [:]
        for document in documents {
            if let buffer = bufferForDocument(document) { buffers[document] = buffer }
        }
        operations[operationID] = Operation(recordID: operationID, documents: documents, buffers: buffers)
        retainedJournalIDs.insert(operationID)
        for buffer in buffers.values {
            installMarker(operationID, in: buffer, undone: false)
        }
    }

    /// Closing a clean tab ends its local typing history. A new buffer may
    /// recover the confirmed shared boundary, never inverses targeting the
    /// closed storage or unsaved text that the user explicitly discarded.
    func reattachCleanBuffer(_ buffer: EditorBuffer, document: EditorDocumentID) {
        guard !isRunning, buffer.initialLoadFinished, buffer.loadKind == .loaded,
              !buffer.dirty, !buffer.workspaceEditDeleted,
              !buffer.undoManager.canUndo, !buffer.undoManager.canRedo else { return }
        for (id, operation) in operations {
            guard operation.pendingRecovery == nil,
                  let participant = operation.buffers.first(where: { key, old in
                      key.worktreeID == document.worktreeID && old.workspaceEditHost == document.host
                          && old.worktreeRoot.appendingPathComponent(old.relativePath).lspURI == document.uri
                  }), participant.value !== buffer, !participant.value.dirty,
                  participant.value.undoManager.isAtMarker(id, redo: operation.undone),
                  let record = try? journal.record(operation.recordID), record.status == .applied,
                  let expected = record.entries.reversed().lazy.compactMap({ entry in
                      entry.observedAfter?.first { $0.document == document }
                  }).first,
                  expected.isOpen, !expected.isDirty, expected.tombstoneContent == nil,
                  expected.content == expected.diskContent,
                  expected.content == Data(buffer.storage.string.utf8),
                  expected.diskContent == Data(buffer.originalText.utf8) else { continue }
            operation.buffers[participant.key] = buffer
            operation.reopenedWatchGenerations[document] = buffer.fileWatchGeneration
            installMarker(id, in: buffer, undone: operation.undone)
            return
        }
    }

    private func installMarker(_ id: UUID, in buffer: EditorBuffer, undone: Bool) {
        buffer.undoManager.installMarker(id) { [weak self] redo in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastOutcome = await self.perform(operationID: id, redo: redo)
            }
        }
        if undone { buffer.undoManager.completeMarker(id, redo: false) }
    }

    func undo(operationID: UUID) async -> WorkspaceEditOutcome {
        let outcome = await perform(operationID: operationID, redo: false)
        lastOutcome = outcome
        return outcome
    }

    func redo(operationID: UUID) async -> WorkspaceEditOutcome {
        let outcome = await perform(operationID: operationID, redo: true)
        lastOutcome = outcome
        return outcome
    }

    /// Explicit recovery rolls back an uncertain attempt before it can retry.
    /// It does not move the shared marker to the other side of the operation.
    func recover(operationID: UUID) async -> WorkspaceEditOutcome {
        guard !isRunning, let operation = operations[operationID], let id = operation.pendingRecovery else {
            return .conflict([])
        }
        isRunning = true
        let managers = operation.buffers.values.map(\.undoManager)
        managers.forEach { $0.workspaceActionInFlight = true }
        defer { isRunning = false
            managers.forEach { $0.workspaceActionInFlight = false }
        }
        let outcome = await executor.recover(id)
        if case .recovered = outcome { operation.pendingRecovery = nil }
        lastOutcome = outcome
        return outcome
    }

    private func perform(operationID: UUID, redo: Bool) async -> WorkspaceEditOutcome {
        guard let operation = operations[operationID] else { return .conflict([]) }
        let documents = operation.documents.sorted { $0.uri < $1.uri }
        guard !isRunning, operation.undone == redo else { return .conflict(documents) }
        if let id = operation.pendingRecovery {
            return .recoveryRequired(id, "Recover the previous workspace undo attempt before retrying.")
        }
        let intervening = operation.buffers.compactMap { document, buffer -> EditorDocumentID? in
            guard !buffer.undoManager.isAtMarker(operationID, redo: redo) else { return nil }
            return EditorDocumentID(host: buffer.workspaceEditHost, worktreeID: document.worktreeID,
                                    uri: buffer.worktreeRoot.appendingPathComponent(buffer.relativePath).lspURI)
        }.sorted { $0.uri < $1.uri }
        guard intervening.isEmpty else { return .conflict(intervening) }
        isRunning = true
        let managers = operation.buffers.values.map(\.undoManager)
        managers.forEach { $0.workspaceActionInFlight = true }
        defer { isRunning = false
            managers.forEach { $0.workspaceActionInFlight = false }
        }
        do {
            let record = try journal.record(operation.recordID)
            guard record.status == .applied else { return .recoveryRequired(record.id, "The workspace edit journal is not confirmed.") }
            var expected: [EditorDocumentID: WorkspaceFileSnapshot] = [:]
            for entry in record.entries {
                for snapshot in entry.observedAfter ?? [] { expected[snapshot.document] = snapshot }
            }
            var actual: [EditorDocumentID: WorkspaceFileSnapshot] = [:]
            var conflicts: [EditorDocumentID] = []
            for document in expected.keys.sorted(by: { $0.uri < $1.uri }) {
                let snapshot = try await access.snapshot(document)
                actual[document] = snapshot
                // Returning to a marker through ordinary undo changes the
                // buffer version. Capture a fresh generation for the executor,
                // but still require the complete original content/ownership.
                if let before = expected[document],
                   !Self.sameBoundary(snapshot, before, reopenedWatchGeneration: operation.reopenedWatchGenerations[document]) {
                    conflicts.append(document)
                }
            }
            guard conflicts.isEmpty else { return .conflict(conflicts) }
            let plan = try Self.inversePlan(record, snapshots: actual)
            let outcome = await executor.apply(plan)
            switch outcome {
            case .applied(let id):
                retainedJournalIDs.insert(id)
                operation.recordID = id
                operation.reopenedWatchGenerations.removeAll()
                operation.undone.toggle()
                managers.forEach { $0.completeMarker(operationID, redo: redo) }
                return .applied(operationID)
            case .recoveryRequired(let id, _):
                retainedJournalIDs.insert(id)
                operation.pendingRecovery = id
            case .conflict, .recovered:
                break
            }
            return outcome
        } catch WorkspaceEditAccessError.conflict(let document) {
            return .conflict([document])
        } catch {
            return .recoveryRequired(operation.recordID, "Could not verify workspace undo targets. No new inverse was started.")
        }
    }

    private static func sameBoundary(_ actual: WorkspaceFileSnapshot, _ expected: WorkspaceFileSnapshot, reopenedWatchGeneration: Int?) -> Bool {
        actual.document == expected.document && actual.content == expected.content
            && actual.isOpen == expected.isOpen && actual.isDirectory == expected.isDirectory
            && actual.isSymbolicLink == expected.isSymbolicLink
            && (!expected.isOpen || actual.diskContent == expected.diskContent)
            && actual.tombstoneContent == expected.tombstoneContent
            && actual.fileWatchGeneration == (reopenedWatchGeneration ?? expected.fileWatchGeneration)
    }

    /// Reverse the last confirmed transaction. Redo reverses that inverse,
    /// so compound text/resource edits use the same recovery machinery.
    private static func inversePlan(_ record: WorkspaceEditJournal.Record, snapshots: [EditorDocumentID: WorkspaceFileSnapshot]) throws -> WorkspaceEditPlan {
        var current = snapshots
        var steps: [WorkspaceEditPlanStep] = []
        func replace(_ document: EditorDocumentID, with desired: WorkspaceFileSnapshot) throws {
            guard let before = current[document] else { throw WorkspaceEditAccessError.conflict(document) }
            steps.append(WorkspaceEditPlanStep(kind: desired.content == nil ? .delete : .text, document: document, destination: nil,
                                               before: before, after: desired, destinationBefore: nil, annotationID: nil, annotationIDs: [], resourceOptions: nil))
            current[document] = desired
        }
        for entry in record.entries.reversed() {
            let step = entry.step
            if step.kind == .rename, let destination = step.destination, step.after.document != step.document {
                guard let source = current[destination], let target = current[step.document] else {
                    throw WorkspaceEditAccessError.conflict(step.document)
                }
                steps.append(WorkspaceEditPlanStep(kind: .rename, document: destination, destination: step.document,
                                                   before: source, after: step.before, destinationBefore: target, annotationID: nil, annotationIDs: [], resourceOptions: nil))
                current[destination] = source.removingResource(keepingBuffer: false)
                current[step.document] = step.before
                if let overwritten = step.destinationBefore, overwritten.content != nil { try replace(destination, with: overwritten) }
            } else if step.before.content != step.after.content {
                try replace(step.document, with: step.before)
            }
        }
        return WorkspaceEditPlan(steps: steps, finalSnapshots: current, reviewAnnotations: [:], warnings: [], requiresPreview: false)
    }
}

/// The owner keeps its coordinator, so the adapter must not retain the owner
/// between operations. The concrete host adapter retains it across each await.
@MainActor
final class TabsWorkspaceEditUndoAccess: WorkspaceEditFileAccess {
    private weak var tabs: TabsManager?
    private let worktreeID: String
    private let root: URL

    init(tabs: TabsManager, worktreeID: String, root: URL) {
        self.tabs = tabs
        self.worktreeID = worktreeID
        self.root = root
    }

    private func adapter(for document: EditorDocumentID) throws -> HostWorkspaceEditFileAccess {
        guard let tabs, document.worktreeID == worktreeID else { throw WorkspaceEditAccessError.unsupportedTarget(document) }
        let directory = root
        let ownerID = worktreeID
        return HostWorkspaceEditFileAccess(tabs: tabs, rootForDocument: { $0.worktreeID == ownerID ? directory : nil })
    }

    func snapshot(_ document: EditorDocumentID) async throws -> WorkspaceFileSnapshot {
        try await adapter(for: document).snapshot(document)
    }

    func replace(_ before: WorkspaceFileSnapshot, with after: WorkspaceFileSnapshot) async throws {
        try await adapter(for: before.document).replace(before, with: after)
    }

    func move(from: EditorDocumentID, to: EditorDocumentID, expectedSource: WorkspaceFileSnapshot, expectedDestination: WorkspaceFileSnapshot) async throws {
        try await adapter(for: from).move(from: from, to: to, expectedSource: expectedSource, expectedDestination: expectedDestination)
    }
}
