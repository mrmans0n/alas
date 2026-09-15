import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class WorkspaceEditUndoCoordinator {
    private struct MissingParticipant {
        let document: EditorDocumentID
        let canReattach: Bool
    }
    private final class Operation {
        var recordID: UUID
        let documents: Set<EditorDocumentID>
        var buffers: [EditorDocumentID: EditorBuffer]
        var reopenedWatchGenerations: [EditorDocumentID: Int] = [:]
        var undone = false
        var pendingRecovery: UUID?
        var recoveryMessage: String?
        var journalIDs: Set<UUID>
        var missing: [EditorDocumentID: MissingParticipant] = [:]

        init(recordID: UUID, documents: Set<EditorDocumentID>, buffers: [EditorDocumentID: EditorBuffer]) {
            self.recordID = recordID
            self.documents = documents
            self.buffers = buffers
            journalIDs = [recordID]
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
    private(set) var lastOperationID: UUID?
    private var displayedRecoveryID: UUID?

    var recoveryOperationID: UUID? {
        if let id = displayedRecoveryID, operations[id]?.pendingRecovery != nil { return id }
        return operations.keys.filter { operations[$0]?.pendingRecovery != nil }.sorted { $0.uuidString < $1.uuidString }.first
    }

    var pendingRecoveryCount: Int { operations.values.filter { $0.pendingRecovery != nil }.count }
    var displayedOperationID: UUID? { recoveryOperationID ?? lastOperationID }

    var affectedPaths: [String] {
        if recoveryOperationID == nil, case .conflict(let documents) = lastOutcome { return documents.map { URL(string: $0.uri)?.path ?? $0.uri } }
        guard let id = displayedOperationID else { return [] }
        return operations[id]?.documents.map { URL(string: $0.uri)?.path ?? $0.uri }.sorted() ?? []
    }

    var statusMessage: String? {
        if isRunning { return "Applying workspace undo operation…" }
        if let id = recoveryOperationID { return operations[id]?.recoveryMessage ?? "A workspace edit needs explicit recovery." }
        switch lastOutcome {
        case .conflict: return "Workspace undo is blocked by changed files or unavailable buffer history."
        case .recoveryRequired(_, let message), .recovered(let message): return message
        default: return nil
        }
    }

    init(access: any WorkspaceEditFileAccess, journal: WorkspaceEditJournal, bufferForDocument: @escaping (EditorDocumentID) -> EditorBuffer?) {
        self.access = access
        self.journal = journal
        self.executor = WorkspaceEditExecutor(access: access, journal: journal)
        self.bufferForDocument = bufferForDocument
    }

    /// Only a fully confirmed executor journal can arm shared undo markers.
    /// Each marker addresses this one entry, including its inverse journals.
    func register(operationID: UUID, affectedDocuments: Set<EditorDocumentID>, initiatingDocument: EditorDocumentID? = nil) {
        guard operations[operationID] == nil,
              let record = try? journal.record(operationID), record.status == .applied,
              !record.entries.isEmpty, record.entries.allSatisfy({ $0.state == .confirmed }) else { return }
        let documents = affectedDocuments.union(record.entries.flatMap { [$0.step.document, $0.step.destination].compactMap { $0 } })
        var buffers: [EditorDocumentID: EditorBuffer] = [:]
        for document in documents.union(initiatingDocument.map { [$0] } ?? []) {
            if let buffer = bufferForDocument(document) { buffers[document] = buffer }
        }
        operations[operationID] = Operation(recordID: operationID, documents: documents, buffers: buffers)
        retainedJournalIDs.insert(operationID)
        for buffer in buffers.values {
            installMarker(operationID, in: buffer, undone: false)
        }
        retireIfUnreachable(operationID)
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
                  let participant = operation.missing.first(where: { $0.value.document == document && $0.value.canReattach }),
                  let record = try? journal.record(operation.recordID), record.status == .applied,
                  let expected = record.entries.reversed().lazy.compactMap({ entry in
                      entry.observedAfter?.first { $0.document == document }
                  }).first,
                  expected.isOpen, !expected.isDirty, expected.tombstoneContent == nil,
                  expected.content == expected.diskContent,
                  expected.content == Data(buffer.storage.string.utf8),
                  expected.diskContent == Data(buffer.originalText.utf8) else { continue }
            operation.buffers[participant.key] = buffer
            operation.missing.removeValue(forKey: participant.key)
            operation.reopenedWatchGenerations[document] = buffer.fileWatchGeneration
            installMarker(id, in: buffer, undone: operation.undone)
            return
        }
    }

    private func installMarker(_ id: UUID, in buffer: EditorBuffer, undone: Bool) {
        buffer.undoManager.installMarker(id, removed: { [weak self, weak buffer] in
            guard let self, let buffer else { return }
            self.markerRemoved(id, buffer: buffer)
        }) { [weak self] redo in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if redo { _ = await self.redo(operationID: id) }
                else { _ = await self.undo(operationID: id) }
            }
        }
        if undone { buffer.undoManager.completeMarker(id, redo: false) }
    }

    func undo(operationID: UUID) async -> WorkspaceEditOutcome {
        lastOperationID = operationID
        let outcome = await perform(operationID: operationID, redo: false)
        lastOutcome = outcome
        return outcome
    }

    func redo(operationID: UUID) async -> WorkspaceEditOutcome {
        lastOperationID = operationID
        let outcome = await perform(operationID: operationID, redo: true)
        lastOutcome = outcome
        return outcome
    }

    /// Explicit recovery rolls back an uncertain attempt before it can retry.
    /// It does not move the shared marker to the other side of the operation.
    func recover(operationID: UUID) async -> WorkspaceEditOutcome {
        lastOperationID = operationID
        guard !isRunning, let operation = operations[operationID], let id = operation.pendingRecovery else {
            return .conflict([])
        }
        isRunning = true
        let managers = operation.buffers.values.map(\.undoManager)
        managers.forEach { $0.workspaceActionInFlight = true }
        defer { isRunning = false
            managers.forEach { $0.workspaceActionInFlight = false }
            for id in Array(operations.keys) { retireIfUnreachable(id) }
        }
        let outcome = await executor.recover(id)
        if case .recovered = outcome {
            operation.pendingRecovery = nil
            operation.recoveryMessage = nil
            if displayedRecoveryID == operationID { displayedRecoveryID = nil }
            displayedRecoveryID = recoveryOperationID
        }
        lastOutcome = outcome
        retireIfUnreachable(operationID)
        return outcome
    }

    /// A confirmation must still refer to the operation the user reviewed.
    func recoverPresentedOperation(operationID: UUID) async -> WorkspaceEditOutcome {
        guard recoveryOperationID == operationID, !isRunning else { return .conflict([]) }
        return await recover(operationID: operationID)
    }

    private func perform(operationID: UUID, redo: Bool) async -> WorkspaceEditOutcome {
        guard let operation = operations[operationID] else { return .conflict([]) }
        let documents = operation.documents.sorted { $0.uri < $1.uri }
        guard !isRunning, operation.undone == redo else { return .conflict(documents) }
        if let id = operation.pendingRecovery {
            return .recoveryRequired(id, "Recover the previous workspace undo attempt before retrying.")
        }
        guard operation.missing.isEmpty else { return .conflict(operation.missing.values.map(\.document).sorted { $0.uri < $1.uri }) }
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
            for id in Array(operations.keys) { retireIfUnreachable(id) }
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
                operation.journalIDs.insert(id)
                operation.recordID = id
                operation.reopenedWatchGenerations.removeAll()
                operation.undone.toggle()
                managers.forEach { $0.completeMarker(operationID, redo: redo) }
                return .applied(operationID)
            case .recoveryRequired(let id, let message):
                retainedJournalIDs.insert(id)
                operation.journalIDs.insert(id)
                operation.pendingRecovery = id
                operation.recoveryMessage = message
                if displayedRecoveryID == nil { displayedRecoveryID = recoveryOperationID }
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

    func bufferWillClose(_ buffer: EditorBuffer) {
        for (id, operation) in operations {
            for (key, participant) in operation.buffers where participant === buffer {
                let document = EditorDocumentID(host: buffer.workspaceEditHost, worktreeID: key.worktreeID,
                                                uri: buffer.worktreeRoot.appendingPathComponent(buffer.relativePath).lspURI)
                if operation.documents.contains(key) {
                    operation.missing[key] = MissingParticipant(document: document, canReattach: !buffer.dirty && buffer.undoManager.isAtMarker(id, redo: operation.undone))
                }
                operation.buffers.removeValue(forKey: key)
            }
        }
        buffer.undoManager.removeAllActions()
        for id in Array(operations.keys) { retireIfUnreachable(id) }
    }

    func disposeHistory() {
        let buffers = operations.values.flatMap { Array($0.buffers.values) }
        for buffer in buffers { bufferWillClose(buffer) }
        for id in Array(operations.keys) { retireIfUnreachable(id) }
    }

    private func markerRemoved(_ id: UUID, buffer: EditorBuffer) {
        guard let operation = operations[id] else { return }
        for (key, participant) in operation.buffers where participant === buffer {
            if operation.documents.contains(key) {
                operation.missing[key] = MissingParticipant(document: .init(host: buffer.workspaceEditHost, worktreeID: key.worktreeID,
                                                                       uri: buffer.worktreeRoot.appendingPathComponent(buffer.relativePath).lspURI), canReattach: false)
            }
            operation.buffers.removeValue(forKey: key)
        }
        retireIfUnreachable(id)
    }

    private func retireIfUnreachable(_ id: UUID) {
        guard !isRunning, let operation = operations[id], operation.pendingRecovery == nil,
              !operation.buffers.values.contains(where: { $0.undoManager.reachableMarkerIDs.contains(id) }) else { return }
        for journalID in operation.journalIDs {
            try? journal.retireSuccessfulRecord(journalID)
            retainedJournalIDs.remove(journalID)
        }
        operations.removeValue(forKey: id)
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

struct WorkspaceEditRecoveryView: View {
    let coordinator: WorkspaceEditUndoCoordinator
    @State private var confirmRecovery = false
    @State private var recoveryCandidate: UUID?

    var body: some View {
        if let message = coordinator.statusMessage {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if coordinator.isRunning { ProgressView().controlSize(.small) }
                    Text(message).font(.caption)
                    Spacer()
                    if coordinator.recoveryOperationID != nil {
                        Button("Recover Workspace Edit…") {
                            recoveryCandidate = coordinator.recoveryOperationID
                            confirmRecovery = true
                        }
                            .disabled(coordinator.isRunning)
                    }
                }
                if coordinator.pendingRecoveryCount > 1 {
                    Text("\(coordinator.pendingRecoveryCount) workspace edits need recovery").font(.caption)
                }
                if let id = coordinator.displayedOperationID {
                    Text("Operation \(id.uuidString)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text(coordinator.affectedPaths.joined(separator: "\n"))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            }
            .padding(8)
            .confirmationDialog("Roll back the uncertain workspace edit attempt? Files are checked again before recovery.", isPresented: $confirmRecovery) {
                Button("Recover Workspace Edit") {
                    guard let id = recoveryCandidate else { return }
                    Task { _ = await coordinator.recoverPresentedOperation(operationID: id) }
                }
            }
        }
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
