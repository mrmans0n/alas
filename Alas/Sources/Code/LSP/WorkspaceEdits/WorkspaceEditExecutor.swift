import Foundation

enum WorkspaceEditOutcome: Equatable {
    case applied(UUID)
    case conflict([EditorDocumentID])
    case recovered(String)
    case recoveryRequired(UUID, String)
}

@MainActor
final class WorkspaceEditExecutor {
    private let access: any WorkspaceEditFileAccess
    private let journal: WorkspaceEditJournal
    private var isApplying = false

    init(access: any WorkspaceEditFileAccess, journal: WorkspaceEditJournal) {
        self.access = access
        self.journal = journal
    }

    /// The caller owns preview approval. This executes an already approved
    /// plan and checks receipt-time snapshots again after that approval.
    func apply(_ plan: WorkspaceEditPlan) async -> WorkspaceEditOutcome {
        guard !isApplying else { return .conflict(plan.steps.map(\.document)) }
        isApplying = true
        defer { isApplying = false }
        // Validate every ownership transition before journaling or writing. Later
        // steps describe virtual state after preceding moves/deletes, not disk now.
        if let unsupported = plan.steps.first(where: { step in
            step.kind == .create && step.before.isOpen && step.before.content != step.after.content
                || step.kind == .rename && step.after.document != step.document && step.destinationBefore?.isOpen == true
        }) {
            return .conflict([unsupported.destination ?? unsupported.document])
        }
        var record: WorkspaceEditJournal.Record
        do { record = try journal.recordPrepared(plan) }
        catch { return .recovered("Could not prepare workspace edit recovery data.") }
        var expected: [EditorDocumentID: WorkspaceFileSnapshot] = [:]
        for step in plan.steps {
            if expected[step.document] == nil { expected[step.document] = step.before }
            if let destination = step.destination, expected[destination] == nil {
                expected[destination] = step.destinationBefore
            }
        }
        do {
            var conflicts: [EditorDocumentID] = []
            for document in expected.keys.sorted(by: { $0.uri < $1.uri }) {
                if let before = expected[document], !Self.matches(try await access.snapshot(document), before) {
                    conflicts.append(document)
                }
            }
            if !conflicts.isEmpty {
                record.status = .recovered
                try journal.save(record)
                return .conflict(conflicts)
            }
            for index in record.entries.indices {
                let step = record.entries[index].step
                try Task.checkCancellation()
                // The plan's later steps contain simulated versions. Use the
                // observed generation from our own last write for each target.
                let before = try await access.snapshot(step.document)
                guard Self.matches(before, expected[step.document] ?? step.before), before.content == step.before.content else {
                    throw WorkspaceEditAccessError.conflict(step.document)
                }
                if let destination = step.destination, let destinationBefore = step.destinationBefore {
                    let actual = try await access.snapshot(destination)
                    guard Self.matches(actual, expected[destination] ?? destinationBefore), actual.content == destinationBefore.content else {
                        throw WorkspaceEditAccessError.conflict(destination)
                    }
                }
                record.entries[index].state = .started
                record.status = .applying
                try journal.save(record)
                try await applyStep(step, before: before)
                let observed = try await postSnapshots(step)
                guard Self.isPostState(observed, of: step) else { throw WorkspaceEditAccessError.conflict(step.document) }
                record.entries[index].observedAfter = observed
                record.entries[index].state = .confirmed
                try journal.save(record)
                for snapshot in observed { expected[snapshot.document] = snapshot }
            }
            record.status = .applied
            try journal.save(record)
            return .applied(record.id)
        } catch {
            return await recoverRecord(&record)
        }
    }

    func recover(_ id: UUID) async -> WorkspaceEditOutcome {
        guard !isApplying else { return .recoveryRequired(id, "A workspace edit is already running.") }
        isApplying = true
        defer { isApplying = false }
        do {
            var record = try journal.record(id)
            return await recoverRecord(&record)
        } catch { return .recoveryRequired(id, "Could not read workspace edit recovery data.") }
    }

    private func applyStep(_ step: WorkspaceEditPlanStep, before: WorkspaceFileSnapshot) async throws {
        // Creating over a live document needs a disk-and-buffer ownership
        // contract distinct from unsaved text edits. Refuse it for now.
        if step.kind == .create, before.isOpen, step.before.content != step.after.content {
            throw WorkspaceEditAccessError.unsupportedTarget(step.document)
        }
        if step.kind == .rename, step.after.document != step.document,
           let destination = step.destination, let destinationBefore = step.destinationBefore {
            try await access.move(from: step.document, to: destination, expectedSource: before, expectedDestination: destinationBefore)
        } else if step.before.content != step.after.content {
            try await access.replace(before, with: step.after)
        }
    }

    private func postSnapshots(_ step: WorkspaceEditPlanStep) async throws -> [WorkspaceFileSnapshot] {
        var result = [try await access.snapshot(step.document)]
        if let destination = step.destination { result.append(try await access.snapshot(destination)) }
        return result
    }

    private func recoverRecord(_ record: inout WorkspaceEditJournal.Record) async -> WorkspaceEditOutcome {
        var unresolved: [String] = []
        for index in record.entries.indices.reversed() {
            let entry = record.entries[index]
            guard entry.state != .pending, entry.state != .restored else { continue }
            do {
                let actual = try await postSnapshots(entry.step)
                if entry.state != .confirmed, Self.isBeforeState(actual, of: entry.step) {
                    record.entries[index].state = .restored
                    try journal.save(record)
                    continue
                }
                guard Self.isPostState(actual, of: entry.step),
                      entry.observedAfter.map({ expected in zip(actual, expected).allSatisfy { Self.matches($0, $1) } }) ?? true else {
                    throw WorkspaceEditAccessError.conflict(entry.step.document)
                }
                record.entries[index].observedAfter = actual
                record.entries[index].state = .confirmed
                try journal.save(record)
                let step = entry.step
                if step.kind == .rename, step.after.document != step.document,
                   let destination = step.destination, let destinationBefore = step.destinationBefore {
                    try await access.move(from: destination, to: step.document, expectedSource: actual[1], expectedDestination: actual[0])
                    if destinationBefore.content != nil {
                        let missing = try await access.snapshot(destination)
                        guard missing.content == nil, !missing.isOpen else {
                            throw WorkspaceEditAccessError.conflict(destination)
                        }
                        try await access.replace(missing, with: destinationBefore)
                    }
                } else if step.before.content != step.after.content {
                    try await access.replace(actual[0], with: step.before)
                }
                let restored = try await postSnapshots(step)
                guard Self.isBeforeState(restored, of: step) else { throw WorkspaceEditAccessError.conflict(step.document) }
                record.entries[index].state = .restored
                // Earlier steps may target the same buffer. Our restoration
                // increments its generation, so carry that known state back.
                for prior in record.entries.indices where prior < index && record.entries[prior].state == .confirmed {
                    if let previous = record.entries[prior].observedAfter {
                        record.entries[prior].observedAfter = previous.map { old in
                            restored.first(where: { $0.document == old.document && $0.content == old.content }) ?? old
                        }
                    }
                }
                try journal.save(record)
            } catch {
                record.entries[index].state = .unknown
                unresolved.append(entry.step.document.uri)
                if let destination = entry.step.destination { unresolved.append(destination.uri) }
                try? journal.save(record)
            }
        }
        record.status = unresolved.isEmpty ? .recovered : .recoveryRequired
        do { try journal.save(record) }
        catch { return .recoveryRequired(record.id, "Could not persist recovery state for \(record.entries.map { $0.step.document.uri }.joined(separator: ", ")).") }
        return unresolved.isEmpty ? .recovered("Workspace edit was rolled back.")
            : .recoveryRequired(record.id, "Recovery remains unresolved for \(Array(Set(unresolved)).sorted().joined(separator: ", ")).")
    }

    static func matches(_ actual: WorkspaceFileSnapshot, _ expected: WorkspaceFileSnapshot) -> Bool {
        actual.document == expected.document && actual.content == expected.content
            && actual.isOpen == expected.isOpen && actual.isDirectory == expected.isDirectory
            && actual.isSymbolicLink == expected.isSymbolicLink
            && (expected.bufferGeneration != nil || expected.bufferVersion == nil || actual.bufferVersion == expected.bufferVersion)
            && (expected.bufferGeneration == nil || actual.bufferGeneration == expected.bufferGeneration)
            && (expected.fileWatchGeneration == nil || actual.fileWatchGeneration == expected.fileWatchGeneration)
            && (!expected.isOpen || actual.diskContent == expected.diskContent)
            && actual.tombstoneContent == expected.tombstoneContent
    }

    private static func isPostState(_ actual: [WorkspaceFileSnapshot], of step: WorkspaceEditPlanStep) -> Bool {
        if step.kind == .rename, step.after.document != step.document {
            return actual.count == 2 && actual[0].content == nil && actual[1].content == step.after.content
        }
        guard let source = actual.first, source.content == step.after.content else { return false }
        if step.after.content == nil, step.before.isOpen {
            // An unconfirmed deletion can lose its post-snapshot while LSP
            // shutdown suspends. Never adopt later tombstone edits as ours.
            return source.isOpen && source.diskContent == nil
                && source.tombstoneContent == (step.before.tombstoneContent ?? step.before.content)
        }
        return true
    }

    private static func isBeforeState(_ actual: [WorkspaceFileSnapshot], of step: WorkspaceEditPlanStep) -> Bool {
        guard let source = actual.first, source.content == step.before.content,
              source.isOpen == step.before.isOpen,
              source.tombstoneContent == step.before.tombstoneContent,
              !step.before.isOpen || source.diskContent == step.before.diskContent else { return false }
        guard let destination = step.destinationBefore else { return true }
        return actual.last?.content == destination.content && actual.last?.isOpen == destination.isOpen
    }
}
