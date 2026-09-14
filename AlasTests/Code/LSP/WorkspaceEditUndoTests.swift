import AppKit
import SwiftUI
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct WorkspaceEditUndoTests {
    @Test func nativeInverseRemainsDisabledAfterPathRebindUntilJournalConfirmation() async throws {
        let f = try await UndoFixture()
        defer { f.remove() }
        let a = f.documents[0]
        let d = EditorDocumentID(host: nil, worktreeID: "w", uri: f.root.appendingPathComponent("d.txt").lspURI)
        let source = try await f.access.snapshot(a)
        let missing = try await f.access.snapshot(d)
        let plan = WorkspaceEditPlan(steps: [
            .init(kind: .rename, document: a, destination: d, before: source, after: source.replacing(document: d, content: source.content), destinationBefore: missing, annotationID: nil, annotationIDs: [], resourceOptions: nil)
        ], finalSnapshots: [:], reviewAnnotations: [:], warnings: [], requiresPreview: true)
        guard case .applied(let id) = await f.undo.executor.apply(plan) else { Issue.record("Apply failed")
            return
        }
        let access = PausingUndoAccess(base: f.access)
        let undo = WorkspaceEditUndoCoordinator(access: access, journal: f.journal, bufferForDocument: { f.tabs.workspaceEditBuffer(for: $0) })
        undo.register(operationID: id, affectedDocuments: [a, d])
        access.pauseAfterMove = true
        defer { access.resume() }
        f.a.undoManager.undo()
        var paused = access.paused.stream.makeAsyncIterator()
        _ = await paused.next()
        #expect(f.a.relativePath == "a.txt")
        #expect(undo.isRunning)
        #expect(f.a.undoManager.workspaceActionInFlight)
        #expect(!f.a.undoManager.canRedo)
        f.a.undoManager.redo()
        #expect(f.a.relativePath == "a.txt")
        access.resume()
        try await awaitWorkspaceMarker(undo, buffer: f.a, id: id, redo: true)
        #expect(await undo.redo(operationID: id) == .applied(id))
        #expect(f.a.relativePath == "d.txt")
    }

    @Test func closingUnchangedInitiatorDoesNotBlockAnotherParticipantUndo() async throws {
        let f = try await UndoFixture()
        defer { f.remove() }
        let target = f.documents[1]
        let before = try await f.access.snapshot(target)
        let after = before.replacing(content: Data("changed".utf8))
        let step = WorkspaceEditPlanStep(kind: .text, document: target, destination: nil, before: before, after: after, destinationBefore: nil, annotationID: nil, annotationIDs: [], resourceOptions: nil)
        let plan = WorkspaceEditPlan(steps: [step], finalSnapshots: [target: after], reviewAnnotations: [:], warnings: [], requiresPreview: false)
        guard case .applied(let id) = await f.undo.executor.apply(plan) else { Issue.record("Apply failed")
        return }
        f.undo.register(operationID: id, affectedDocuments: [target], initiatingDocument: f.documents[0])
        f.tabs.discardBuffer(worktreeId: "w", tabId: "a")
        #expect(f.undo.retainedJournalIDs.contains(id))
        f.view(for: f.b).undoManager?.undo()
        for _ in 0..<200 where f.undo.lastOutcome == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(f.undo.lastOutcome == .applied(id))
        #expect(f.b.storage.string == "old")
    }

    @Test func pendingRecoverySurvivesLaterOutcomesAndConfirmationNeverRetargets() async throws {
        let f = try WorkspaceEditFixture(host: "ssh-host")
        defer { f.remove() }
        let owner = try await UndoFixture()
        defer { owner.remove() }
        let undo = WorkspaceEditUndoCoordinator(access: f.access, journal: f.journal, bufferForDocument: {
            $0 == owner.documents[0] ? owner.a : $0 == owner.documents[1] ? owner.b : nil
        })
        let original = f.access.files
        guard case .applied(let first) = await f.executor.apply(f.plan) else { Issue.record("Apply failed")
        return }
        undo.register(operationID: first, affectedDocuments: [f.a, f.b], initiatingDocument: owner.documents[0])
        let applied = f.access.files
        // A second independent user transaction has the same confirmed bytes.
        f.access.files = original
        guard case .applied(let second) = await f.executor.apply(f.plan) else { Issue.record("Apply failed")
        return }
        undo.register(operationID: second, affectedDocuments: [f.a, f.b], initiatingDocument: owner.documents[1])
        f.access.disconnectAfterWrite = f.b
        guard case .recoveryRequired = await undo.undo(operationID: first) else { Issue.record("Expected first recovery")
        return }
        #expect(undo.recoveryOperationID == first)
        f.access.disconnected = false
        f.access.files = applied
        guard case .recoveryRequired = await undo.undo(operationID: second) else { Issue.record("Expected second recovery")
        return }
        #expect(undo.pendingRecoveryCount == 2)
        #expect(undo.recoveryOperationID == first)
        #expect(await undo.undo(operationID: UUID()) == .conflict([]))
        #expect(undo.lastOutcome == .conflict([]))
        #expect(undo.displayedOperationID == first)
        #expect(undo.affectedPaths == ["/workspace/a", "/workspace/b"])
        let calls = f.access.calls.count
        #expect(await undo.recoverPresentedOperation(operationID: second) == .conflict([]))
        #expect(f.access.calls.count == calls)
        f.access.disconnected = false
        f.access.disconnectAfterWrite = nil
        guard case .recovered = await undo.recoverPresentedOperation(operationID: first) else { Issue.record("Expected recovery")
        return }
        #expect(undo.pendingRecoveryCount == 1)
        #expect(undo.recoveryOperationID == second)
        let afterRecovery = f.access.calls.count
        #expect(await undo.recoverPresentedOperation(operationID: first) == .conflict([]))
        #expect(f.access.calls.count == afterRecovery)
        guard case .recovered = await undo.recoverPresentedOperation(operationID: second) else { Issue.record("Expected second recovery")
        return }
        #expect(undo.pendingRecoveryCount == 0)
        undo.disposeHistory()
        #expect(undo.retainedJournalIDs.isEmpty)
    }

    @Test func closedOnlyEditUsesUnchangedInitiatingEditorUndoAndRetiresOnFinalClose() async throws {
        let f = try await UndoFixture()
        defer { f.remove() }
        let target = f.documents[2]
        let context = EditorRequestContext(document: f.documents[0], version: 1, serverGeneration: UUID(), range: .init(start: .init(line: 0, character: 0), end: .init(line: 0, character: 0)))
        let before = try await f.access.snapshot(target)
        let after = before.replacing(content: Data("closed edit".utf8))
        let step = WorkspaceEditPlanStep(kind: .text, document: target, destination: nil, before: before, after: after, destinationBefore: nil, annotationID: nil, annotationIDs: [], resourceOptions: nil)
        let plan = WorkspaceEditPlan(steps: [step], finalSnapshots: [target: after], reviewAnnotations: [:], warnings: [], requiresPreview: true)
        let view = f.view(for: f.a)
        let feature = RenameFeature(textView: view, tabs: f.tabs, root: f.root, synchronize: { _ in nil }, isCurrent: { _ in true })
        let model = feature.makePreviewModel(plan: plan, context: context)
        #expect(await model.apply())
        #expect(f.a.storage.string == "old")
        #expect(!f.a.dirty)
        #expect(f.a.undoManager.canUndo)
        #expect(!f.b.undoManager.canUndo)
        f.type("later", in: f.a)
        view.undoManager?.undo()
        #expect(f.a.storage.string == "old")
        #expect(try String(contentsOf: f.root.appendingPathComponent("c.txt"), encoding: .utf8) == "closed edit")
        view.undoManager?.undo()
        for _ in 0..<200 where f.undo.lastOutcome == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(f.undo.affectedPaths == [f.root.appendingPathComponent("c.txt").path])
        #expect(try String(contentsOf: f.root.appendingPathComponent("c.txt"), encoding: .utf8) == "old")
        #expect(!f.a.dirty)
        f.tabs.discardBuffer(worktreeId: "w", tabId: "a")
        #expect(f.undo.retainedJournalIDs.isEmpty)
        #expect(try f.journal.records().isEmpty)
    }

    @Test func successWithoutLiveUndoOwnerRetiresImmediately() async throws {
        let f = try WorkspaceEditFixture()
        defer { f.remove() }
        guard case .applied(let id) = await f.executor.apply(f.plan) else { Issue.record("Apply failed")
        return }
        let undo = WorkspaceEditUndoCoordinator(access: f.access, journal: f.journal, bufferForDocument: { _ in nil })
        undo.register(operationID: id, affectedDocuments: [f.a, f.b])
        #expect(undo.retainedJournalIDs.isEmpty)
        #expect(try f.journal.records().isEmpty)
    }

    @Test func closingLastParticipantRetiresHistoryButViewDetachDoesNot() async throws {
        let f = try await UndoFixture()
        defer { f.remove() }
        let id = try await f.rename()
        let view = f.view(for: f.a)
        view.bindUndo(to: nil)
        #expect(f.undo.retainedJournalIDs.contains(id))
        f.tabs.discardBuffer(worktreeId: "w", tabId: "a")
        #expect(f.undo.retainedJournalIDs.contains(id))
        f.tabs.discardBuffer(worktreeId: "w", tabId: "b")
        #expect(f.undo.retainedJournalIDs.isEmpty)
        #expect(try f.journal.records().isEmpty)
    }

    @Test func replacingSharedRedoBranchRetiresItsJournal() async throws {
        let f = try await UndoFixture()
        defer { f.remove() }
        let id = try await f.rename()
        #expect(await f.undo.undo(operationID: id) == .applied(id))
        _ = try await f.rename()
        #expect(!f.undo.retainedJournalIDs.contains(id))
        #expect(try f.journal.records().count == 1)
    }

    @Test func normalBufferUndoPublishesConflictPathsInRecoveryView() async throws {
        let f = try await UndoFixture()
        defer { f.remove() }
        let id = try await f.rename()
        try Data("outside".utf8).write(to: f.root.appendingPathComponent("c.txt"))
        let view = f.view(for: f.a)
        let recovery = NSHostingController(rootView: WorkspaceEditRecoveryView(coordinator: f.undo))
        _ = recovery.view
        view.undoManager?.undo()
        for _ in 0..<200 where f.undo.lastOutcome == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(f.undo.lastOperationID == id)
        #expect(f.undo.lastOutcome == .conflict([f.documents[2]]))
        #expect(f.undo.affectedPaths == [f.root.appendingPathComponent("c.txt").path])
        #expect(f.undo.statusMessage != nil)
        #expect(f.undo.recoveryOperationID == nil)
    }

    @Test func clearingLastParticipantHistoryRetiresSuccessfulJournals() async throws {
        let f = try await UndoFixture()
        defer { f.remove() }
        let id = try await f.rename()
        f.a.undoManager.removeAllActions()
        #expect(f.undo.retainedJournalIDs.contains(id))
        f.b.undoManager.removeAllActions()
        #expect(f.undo.retainedJournalIDs.isEmpty)
        #expect(try f.journal.records().isEmpty)
    }

    @Test func localRedoPrecedesAnEarlierSharedBoundary() async throws {
        let f = try await UndoFixture()
        defer { f.remove() }
        f.type("earlier", in: f.a)
        let id = try await f.rename()
        f.a.undoManager.undo()
        try await awaitWorkspaceMarker(f.undo, buffer: f.a, id: id, redo: true)
        f.a.undoManager.undo()
        #expect(f.a.storage.string == "old")
        #expect(f.a.undoManager.redoActionName == "Typing")
        f.a.undoManager.redo()
        #expect(f.a.storage.string == "earlier")
        #expect(f.b.storage.string == "old")
        f.a.undoManager.redo()
        try await awaitWorkspaceMarker(f.undo, buffer: f.a, id: id, redo: false)
        #expect(f.a.storage.string == "new")
        #expect(f.b.storage.string == "new")
    }

    @Test func typingCoalescesUntilCaretMovementAndGroupsBackwardDeletion() async throws {
        let f = try await UndoFixture()
        defer { f.remove() }
        let view = f.view(for: f.a)
        view.insertText("x", replacementRange: NSRange(location: 3, length: 0))
        view.insertText("y", replacementRange: NSRange(location: 4, length: 0))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.setSelectedRange(NSRange(location: 5, length: 0))
        view.insertText("z", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.undoManager?.undo()
        #expect(f.a.storage.string == "oldxy")
        view.undoManager?.undo()
        #expect(f.a.storage.string == "old")
        view.undoManager?.redo()
        #expect(f.a.storage.string == "oldxy")
        view.undoManager?.redo()
        #expect(f.a.storage.string == "oldxyz")
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.deleteBackward(nil)
        view.deleteBackward(nil)
        #expect(f.a.storage.string == "oldx")
        view.undoManager?.undo()
        #expect(f.a.storage.string == "oldxyz")
        view.undoManager?.redo()
        #expect(f.a.storage.string == "oldx")
    }

    @Test(arguments: [false, true], [false, true])
    func cleanParticipatingTabReopenChecksContentBeforeRestoringMarker(outsideEdit: Bool, undoneBeforeClose: Bool) async throws {
        let f = try await UndoFixture()
        defer { f.remove() }
        let a = f.documents[0]
        let d = EditorDocumentID(host: nil, worktreeID: "w", uri: f.root.appendingPathComponent("d.txt").lspURI)
        let source = try await f.access.snapshot(a)
        let missing = try await f.access.snapshot(d)
        let plan = WorkspaceEditPlan(steps: [
            .init(kind: .rename, document: a, destination: d, before: source, after: source.replacing(document: d, content: source.content), destinationBefore: missing, annotationID: nil, annotationIDs: [], resourceOptions: nil)
        ], finalSnapshots: [:], reviewAnnotations: [:], warnings: [], requiresPreview: true)
        guard case .applied(let id) = await f.undo.executor.apply(plan) else { Issue.record("Apply failed")
        return }
        // The other live participant retains reachability while this tab closes.
        f.undo.register(operationID: id, affectedDocuments: [a, d, f.documents[1]])
        if undoneBeforeClose { #expect(await f.undo.undo(operationID: id) == .applied(id)) }
        #expect(!f.a.dirty)
        let closedDocument = undoneBeforeClose ? a : d
        let closedPath = undoneBeforeClose ? "a.txt" : "d.txt"
        f.tabs.discardBuffer(worktreeId: "w", tabId: "a")
        if outsideEdit { try Data("outside".utf8).write(to: f.root.appendingPathComponent(closedPath)) }
        let reopened = f.tabs.buffer(worktreeId: "w", tabId: "reopened", worktreeRoot: f.root, relativePath: closedPath)
        await reopened.awaitLoadForTesting()
        defer { reopened.close(persistDirtySnapshot: false) }
        #expect(reopened !== f.a)
        if outsideEdit {
            #expect(!reopened.undoManager.canUndo)
            #expect(!reopened.undoManager.canRedo)
            let outcome = undoneBeforeClose ? await f.undo.redo(operationID: id) : await f.undo.undo(operationID: id)
            #expect(outcome == .conflict([closedDocument]))
            #expect(reopened.storage.string == "outside")
            #expect(!f.a.undoManager.canUndo && !f.a.undoManager.canRedo)
            #expect(undoneBeforeClose ? f.b.undoManager.canRedo : f.b.undoManager.canUndo)
        } else {
            #expect(undoneBeforeClose ? reopened.undoManager.canRedo : reopened.undoManager.canUndo)
            if undoneBeforeClose { reopened.undoManager.redo() } else { reopened.undoManager.undo() }
            let inversePath = undoneBeforeClose ? "d.txt" : "a.txt"
            try await awaitWorkspaceMarker(f.undo, buffer: reopened, id: id, redo: !undoneBeforeClose)
            #expect(reopened.relativePath == inversePath)
            #expect(try String(contentsOf: f.root.appendingPathComponent(inversePath), encoding: .utf8) == "old")
            if undoneBeforeClose { reopened.undoManager.undo() } else { reopened.undoManager.redo() }
            try await awaitWorkspaceMarker(f.undo, buffer: reopened, id: id, redo: undoneBeforeClose)
            #expect(reopened.relativePath == closedPath)
            #expect(try String(contentsOf: f.root.appendingPathComponent(closedPath), encoding: .utf8) == "old")
        }
    }

    @Test func normalRedoReachesSharedBoundaryAfterUndoingLaterTyping() async throws {
        let f = try await UndoFixture()
        defer { f.remove() }
        let id = try await f.rename()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 800, height: 600))
        layout.addTextContainer(container)
        f.a.storage.addLayoutManager(layout)
        let view = CodeTextView(frame: .zero, textContainer: container)
        view.bindUndo(to: f.a)
        #expect(view.tryToPerform(NSSelectorFromString("undo:"), with: nil))
        try await awaitWorkspaceMarker(f.undo, buffer: f.a, id: id, redo: true)
        #expect(f.a.storage.string == "old")
        view.insertText("later", replacementRange: NSRange(location: 0, length: 3))
        #expect(f.a.storage.string == "later")
        #expect(view.tryToPerform(NSSelectorFromString("undo:"), with: nil))
        #expect(f.a.storage.string == "old")
        #expect(view.undoManager?.redoActionName == "Workspace Edit")
        #expect(view.tryToPerform(NSSelectorFromString("redo:"), with: nil))
        try await awaitWorkspaceMarker(f.undo, buffer: f.a, id: id, redo: false)
        #expect(f.a.storage.string == "new")
        #expect(f.b.storage.string == "new")
        #expect(try String(contentsOf: f.root.appendingPathComponent("c.txt"), encoding: .utf8) == "new")
    }

    @Test func oneAsyncInverseRunsAtATime() async throws {
        let f = try WorkspaceEditFixture(host: "ssh-host")
        defer { f.remove() }
        let owner = try await UndoFixture()
        defer { owner.remove() }
        guard case .applied(let id) = await f.executor.apply(f.plan) else { Issue.record("Apply failed")
        return }
        let access = PausingUndoAccess(base: f.access)
        let undo = WorkspaceEditUndoCoordinator(access: access, journal: f.journal, bufferForDocument: { $0 == owner.documents[0] ? owner.a : nil })
        undo.register(operationID: id, affectedDocuments: [f.a, f.b], initiatingDocument: owner.documents[0])
        access.pauseNextSnapshot = true
        let first = Task { await undo.undo(operationID: id) }
        defer { access.resume()
        first.cancel() }
        for _ in 0..<100 where access.continuation == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(undo.isRunning)
        #expect(await undo.undo(operationID: id) == .conflict([f.a, f.b]))
        #expect(f.access.files[f.b]?.content == Data("new disk".utf8))
        undo.bufferWillClose(owner.a)
        #expect(undo.retainedJournalIDs.contains(id))
        access.resume()
        #expect(await first.value == .applied(id))
        #expect(f.access.files[f.b]?.content == Data("old disk".utf8))
        #expect(undo.retainedJournalIDs.isEmpty)
    }

    @Test func unconfirmedJournalCannotArmUndo() throws {
        let f = try WorkspaceEditFixture()
        defer { f.remove() }
        let record = try f.journal.recordPrepared(f.plan)
        let undo = WorkspaceEditUndoCoordinator(access: f.access, journal: f.journal, bufferForDocument: { _ in nil })
        undo.register(operationID: record.id, affectedDocuments: [f.a, f.b])
        #expect(undo.retainedJournalIDs.isEmpty)
        #expect(f.access.calls.isEmpty)
    }

    @Test func compoundResourceUndoAndRedoPreserveBufferIdentity() async throws {
        let f = try await UndoFixture()
        defer { f.remove() }
        let a = f.documents[0]
        let d = EditorDocumentID(host: nil, worktreeID: "w", uri: f.root.appendingPathComponent("d.txt").lspURI)
        let source = try await f.access.snapshot(a)
        let missing = try await f.access.snapshot(d)
        let emptySource = source.removingResource(keepingBuffer: false)
        let plan = WorkspaceEditPlan(steps: [
            .init(kind: .rename, document: a, destination: d, before: source, after: source.replacing(document: d, content: source.content), destinationBefore: missing, annotationID: nil, annotationIDs: [], resourceOptions: nil),
            .init(kind: .create, document: a, destination: nil, before: emptySource, after: emptySource.replacing(content: Data()), destinationBefore: nil, annotationID: nil, annotationIDs: [], resourceOptions: nil)
        ], finalSnapshots: [:], reviewAnnotations: [:], warnings: [], requiresPreview: true)
        guard case .applied(let id) = await f.undo.executor.apply(plan) else { Issue.record("Resource apply failed")
        return }
        f.undo.register(operationID: id, affectedDocuments: [a, d])
        #expect(f.a.relativePath == "d.txt")
        #expect(await f.undo.undo(operationID: id) == .applied(id))
        #expect(f.a.relativePath == "a.txt")
        #expect(f.a.storage.string == "old")
        #expect(try String(contentsOf: f.root.appendingPathComponent("a.txt"), encoding: .utf8) == "old")
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("d.txt").path))
        f.type("later", in: f.a)
        #expect(await f.undo.redo(operationID: id) == .conflict([a]))
        f.a.undoManager.undo()
        #expect(await f.undo.redo(operationID: id) == .applied(id))
        #expect(f.a.relativePath == "d.txt")
        #expect(try Data(contentsOf: f.root.appendingPathComponent("a.txt")).isEmpty)
    }

    @Test func editableExternalBufferKeepsUndoAfterViewReplacement() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("undo-external-\(UUID()).txt")
        try Data("old".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let buffer = EditorBuffer(externalAbsoluteURL: file, editable: true)
        defer { buffer.close(persistDirtySnapshot: false) }
        func view() -> CodeTextView {
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: 800, height: 600))
            layout.addTextContainer(container)
            buffer.storage.addLayoutManager(layout)
            let view = CodeTextView(frame: .zero, textContainer: container)
            view.bindUndo(to: buffer)
            return view
        }
        let first = view()
        first.insertText("new", replacementRange: NSRange(location: 0, length: 3))
        first.bindUndo(to: nil)
        let second = view()
        #expect(second.validateUserInterfaceItem(NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "")))
        second.undoManager?.undo()
        #expect(buffer.storage.string == "old")
        second.undoManager?.redo()
        #expect(buffer.storage.string == "new")
        #expect(try String(contentsOf: file, encoding: .utf8) == "old")
    }

    @Test func worktreeOwnsOneUndoCoordinatorAcrossBufferReopen() async throws {
        let f = try await UndoFixture()
        defer { f.remove() }
        let first = f.tabs.workspaceEditUndoCoordinator(forWorktreeId: "w", worktreeRoot: f.root)
        f.tabs.discardBuffer(worktreeId: "w", tabId: "a")
        let reopened = f.tabs.buffer(worktreeId: "w", tabId: "reopened-a", worktreeRoot: f.root, relativePath: "a.txt")
        await reopened.awaitLoadForTesting()
        defer { reopened.close(persistDirtySnapshot: false) }
        #expect(f.tabs.workspaceEditUndoCoordinator(forWorktreeId: "w", worktreeRoot: f.root) === first)
        #expect(f.tabs.workspaceEditUndoCoordinator(forWorktreeId: "other", worktreeRoot: f.root) !== first)
        #expect(!reopened.undoManager.canUndo)
    }

    @Test func workspaceUndoWaitsForLaterTypingAndChangesUnopenedDisk() async throws {
        let f = try await UndoFixture()
        defer { f.remove() }
        let id = try await f.rename()
        f.type("new later", in: f.a)
        #expect(await f.undo.undo(operationID: id) == .conflict([f.documents[0]]))
        #expect(f.a.storage.string == "new later")
        f.a.undoManager.undo()
        #expect(f.a.storage.string == "new")
        #expect(await f.undo.undo(operationID: id) == .applied(id))
        #expect(f.a.storage.string == "old")
        #expect(f.b.storage.string == "old")
        #expect(try String(contentsOf: f.root.appendingPathComponent("c.txt"), encoding: .utf8) == "old")
        #expect(await f.undo.redo(operationID: id) == .applied(id))
        #expect(f.a.storage.string == "new")
        #expect(f.b.storage.string == "new")
        #expect(try String(contentsOf: f.root.appendingPathComponent("c.txt"), encoding: .utf8) == "new")
    }

    @Test func duplicateMarkersCannotReplayAndDiskConflictKeepsUndoAvailable() async throws {
        let f = try await UndoFixture()
        defer { f.remove() }
        let id = try await f.rename()
        try Data("outside".utf8).write(to: f.root.appendingPathComponent("c.txt"))
        #expect(await f.undo.undo(operationID: id) == .conflict([f.documents[2]]))
        #expect(f.a.undoManager.canUndo)
        #expect(f.a.storage.string == "new")
        try Data("new".utf8).write(to: f.root.appendingPathComponent("c.txt"))
        f.a.undoManager.undo()
        f.b.undoManager.undo()
        try await awaitWorkspaceMarker(f.undo, buffer: f.a, id: id, redo: true)
        #expect(f.a.storage.string == "old")
        #expect(f.b.storage.string == "old")
        #expect(try f.journal.records().filter { $0.status == .applied }.count == 2)
        #expect(await f.undo.undo(operationID: id) != .applied(id))
        f.b.undoManager.redo()
        try await awaitWorkspaceMarker(f.undo, buffer: f.b, id: id, redo: false)
        #expect(f.a.storage.string == "new")
        #expect(f.b.storage.string == "new")
    }

    @Test func closedTabRemainsRecoverableWithoutOverwritingDiscardedText() async throws {
        let f = try await UndoFixture()
        defer { f.remove() }
        let id = try await f.rename()
        f.tabs.discardBuffer(worktreeId: "w", tabId: "a")
        #expect(await f.undo.undo(operationID: id) == .conflict([f.documents[0]]))
        #expect(f.b.storage.string == "new")
        #expect(try String(contentsOf: f.root.appendingPathComponent("a.txt"), encoding: .utf8) == "old")
        #expect(f.b.undoManager.canUndo)
        let reopened = f.tabs.buffer(worktreeId: "w", tabId: "reopened", worktreeRoot: f.root, relativePath: "a.txt")
        await reopened.awaitLoadForTesting()
        defer { reopened.close(persistDirtySnapshot: false) }
        #expect(!reopened.undoManager.canUndo)
        #expect(await f.undo.undo(operationID: id) == .conflict([f.documents[0]]))
        #expect(reopened.storage.string == "old")
    }

    @Test func unknownSSHUndoRetainsOriginalMarkerAndRecoveryJournal() async throws {
        let f = try WorkspaceEditFixture(host: "ssh-host")
        defer { f.remove() }
        let owner = try await UndoFixture()
        defer { owner.remove() }
        guard case .applied(let id) = await f.executor.apply(f.plan) else { Issue.record("Apply failed")
        return }
        let undo = WorkspaceEditUndoCoordinator(access: f.access, journal: f.journal, bufferForDocument: { $0 == owner.documents[0] ? owner.a : nil })
        undo.register(operationID: id, affectedDocuments: [f.a, f.b], initiatingDocument: owner.documents[0])
        f.access.disconnectAfterWrite = f.b
        let view = owner.view(for: owner.a)
        let recovery = NSHostingController(rootView: WorkspaceEditRecoveryView(coordinator: undo))
        _ = recovery.view
        view.undoManager?.undo()
        for _ in 0..<200 where undo.lastOutcome == nil { try await Task.sleep(for: .milliseconds(10)) }
        guard case .recoveryRequired(let recoveryID, _) = undo.lastOutcome else { Issue.record("Expected unknown SSH result")
        return }
        #expect(recoveryID != id)
        #expect(undo.retainedJournalIDs.contains(id))
        #expect(undo.retainedJournalIDs.contains(recoveryID))
        #expect(undo.lastOperationID == id)
        #expect(undo.recoveryOperationID == id)
        #expect(undo.statusMessage != nil)
        let writes = f.access.calls.filter { $0.hasPrefix("write:") }.count
        guard case .recoveryRequired = await undo.undo(operationID: id) else { Issue.record("Expected retained unknown result")
        return }
        #expect(f.access.calls.filter { $0.hasPrefix("write:") }.count == writes)
        undo.bufferWillClose(owner.a)
        #expect(undo.retainedJournalIDs.contains(id))
        #expect(undo.retainedJournalIDs.contains(recoveryID))
        f.access.disconnected = false
        f.access.disconnectAfterWrite = nil
        guard case .recovered = await undo.recover(operationID: id) else { Issue.record("Expected explicit recovery after reconnect")
        return }
        #expect(f.access.files[f.b]?.content == Data("new disk".utf8))
        // With no live buffer markers, recovered history is now retired.
        #expect(undo.retainedJournalIDs.isEmpty)
        #expect(await undo.undo(operationID: id) == .conflict([]))
    }

    @Test func formattingAndEarlierTypingKeepTheirOwnUndoGroups() async throws {
        let f = try await UndoFixture()
        defer { f.remove() }
        f.type("typed", in: f.a)
        let config = AppConfig.Code(fontFamily: "SF Mono", fontSize: 13, formatOnSave: true, showLineNumbers: true, languageServers: [], dismissedInstallNudges: [], userDefinedRecipes: [:])
        try await f.a.formatAndSave(config: config, lsp: UndoTestFormatter())
        #expect(try String(contentsOf: f.root.appendingPathComponent("a.txt"), encoding: .utf8) == "formatted")
        f.a.undoManager.undo()
        #expect(f.a.storage.string == "typed")
        f.a.undoManager.undo()
        #expect(f.a.storage.string == "old")
        f.a.undoManager.redo()
        f.a.undoManager.redo()
        #expect(f.a.storage.string == "formatted")
    }

    @Test func typingUndoSurvivesReusedViewAndDetach() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-undo-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("old".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("other".utf8).write(to: root.appendingPathComponent("b.txt"))
        let appState = AppState()
        let a = appState.tabs.buffer(worktreeId: "undo-test", tabId: "a", worktreeRoot: root, relativePath: "a.txt")
        let b = appState.tabs.buffer(worktreeId: "undo-test", tabId: "b", worktreeRoot: root, relativePath: "b.txt")
        await a.awaitLoadForTesting()
        await b.awaitLoadForTesting()
        defer { a.close(persistDirtySnapshot: false)
        b.close(persistDirtySnapshot: false) }
        let theme = try ThemeStore().current
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 800, height: 600))
        layout.addTextContainer(container)
        let view = CodeTextView(frame: .zero, textContainer: container)
        let coordinator = CodeEditorCoordinator(appState: appState)
        coordinator.attach(textView: view, buffer: a, layoutManager: layout, worktreeId: "undo-test", worktreeRoot: root, tabId: "a", revealLine: nil, revealCharacter: nil, theme: theme)
        for (offset, character) in ["n", "e", "w"].enumerated() {
            view.insertText(character, replacementRange: NSRange(location: 3 + offset, length: 0))
        }
        #expect(a.storage.string == "oldnew")
        view.allowsUndo = true
        coordinator.updateIfNeeded(worktreeId: "undo-test", worktreeRoot: root, relativePath: "b.txt", tabId: "b", revealLine: nil, revealCharacter: nil, theme: theme)
        coordinator.updateIfNeeded(worktreeId: "undo-test", worktreeRoot: root, relativePath: "a.txt", tabId: "a", revealLine: nil, revealCharacter: nil, theme: theme)
        #expect(view.undoManager?.canUndo == true)
        #expect(view.tryToPerform(NSSelectorFromString("undo:"), with: nil))
        #expect(a.storage.string == "old")
        #expect(b.storage.string == "other")
        coordinator.detach()
        coordinator.attach(textView: view, buffer: a, layoutManager: layout, worktreeId: "undo-test", worktreeRoot: root, tabId: "a", revealLine: nil, revealCharacter: nil, theme: theme)
        view.undoManager?.redo()
        #expect(a.storage.string == "oldnew")
        coordinator.detach()
    }
}

@MainActor
private func awaitWorkspaceMarker(_ undo: WorkspaceEditUndoCoordinator, buffer: EditorBuffer, id: UUID, redo: Bool) async throws {
    for _ in 0..<100 {
        if !undo.isRunning, !buffer.undoManager.workspaceActionInFlight, buffer.undoManager.isAtMarker(id, redo: redo) { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try #require(!undo.isRunning && !buffer.undoManager.workspaceActionInFlight && buffer.undoManager.isAtMarker(id, redo: redo), "Workspace inverse must finish and publish its reciprocal marker")
}

@MainActor
private struct UndoFixture {
    let root: URL
    let tabs: TabsManager
    let a: EditorBuffer
    let b: EditorBuffer
    let documents: [EditorDocumentID]
    let access: HostWorkspaceEditFileAccess
    let journal: WorkspaceEditJournal
    let undo: WorkspaceEditUndoCoordinator

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-undo-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["a", "b", "c"] { try Data("old".utf8).write(to: root.appendingPathComponent("\(name).txt")) }
        journal = WorkspaceEditJournal(root: root.appendingPathComponent("journal"))
        tabs = TabsManager(bufferStore: EditorBufferStore(rootOverride: root.appendingPathComponent("buffers")), tabsDirectory: root.appendingPathComponent("tabs"), workspaceEditJournal: journal)
        a = tabs.buffer(worktreeId: "w", tabId: "a", worktreeRoot: root, relativePath: "a.txt")
        b = tabs.buffer(worktreeId: "w", tabId: "b", worktreeRoot: root, relativePath: "b.txt")
        await a.awaitLoadForTesting()
        await b.awaitLoadForTesting()
        a.stopWatching()
        b.stopWatching()
        let directory = root
        access = HostWorkspaceEditFileAccess(tabs: tabs, rootForDocument: { _ in directory })
        undo = tabs.workspaceEditUndoCoordinator(forWorktreeId: "w", worktreeRoot: root)
        documents = ["a", "b", "c"].map { EditorDocumentID(host: nil, worktreeID: "w", uri: directory.appendingPathComponent("\($0).txt").lspURI) }
    }

    func rename() async throws -> UUID {
        var snapshots: [EditorDocumentID: WorkspaceFileSnapshot] = [:]
        for doc in documents { snapshots[doc] = try await access.snapshot(doc) }
        let plan = WorkspaceEditPlan(steps: documents.map {
            let before = snapshots[$0]!
            return WorkspaceEditPlanStep(kind: .text, document: $0, destination: nil, before: before, after: before.replacing(content: Data("new".utf8)), destinationBefore: nil, annotationID: nil, annotationIDs: [], resourceOptions: nil)
        }, finalSnapshots: [:], reviewAnnotations: [:], warnings: [], requiresPreview: false)
        let outcome = await WorkspaceEditExecutor(access: access, journal: journal).apply(plan)
        guard case .applied(let id) = outcome else { throw UndoFixtureError.applyFailed }
        undo.register(operationID: id, affectedDocuments: Set(documents))
        return id
    }

    func type(_ value: String, in buffer: EditorBuffer) {
        let range = NSRange(location: 0, length: buffer.storage.length)
        buffer.registerTextUndo(range: range, replacement: value)
        buffer.storage.replaceCharacters(in: range, with: value)
    }

    func view(for buffer: EditorBuffer) -> CodeTextView {
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 800, height: 600))
        layout.addTextContainer(container)
        buffer.storage.addLayoutManager(layout)
        let view = CodeTextView(frame: .zero, textContainer: container)
        view.bindUndo(to: buffer)
        return view
    }

    func remove() {
        a.close(persistDirtySnapshot: false)
        b.close(persistDirtySnapshot: false)
        try? FileManager.default.removeItem(at: root)
    }
}

private enum UndoFixtureError: Error { case applyFailed }

@MainActor
private final class UndoTestFormatter: DocumentFormatter {
    func language(forFileExtension ext: String) -> String? { "swift" }
    func formatting(for fileURL: URL, languageId: String, options: LSPFormattingOptions) async -> [LSPTextEdit]? {
        [.init(range: .init(start: .init(line: 0, character: 0), end: .init(line: 0, character: 5)), newText: "formatted")]
    }
    func didChange(worktreeRoot: URL, fileURL: URL, languageId: String, text: String, edits: [EditorTextEdit]?) async {}
}

@MainActor
private final class PausingUndoAccess: WorkspaceEditFileAccess {
    let base: any WorkspaceEditFileAccess
    var pauseNextSnapshot = false
    var pauseAfterMove = false
    let paused = AsyncStream<Void>.makeStream()
    var continuation: CheckedContinuation<Void, Never>?
    init(base: any WorkspaceEditFileAccess) { self.base = base }
    func resume() { continuation?.resume()
    continuation = nil }
    func snapshot(_ document: EditorDocumentID) async throws -> WorkspaceFileSnapshot {
        if pauseNextSnapshot {
            pauseNextSnapshot = false
            await withCheckedContinuation {
                continuation = $0
                paused.continuation.yield(())
            }
        }
        return try await base.snapshot(document)
    }
    func replace(_ before: WorkspaceFileSnapshot, with after: WorkspaceFileSnapshot) async throws {
        try await base.replace(before, with: after)
    }
    func move(from: EditorDocumentID, to: EditorDocumentID, expectedSource: WorkspaceFileSnapshot, expectedDestination: WorkspaceFileSnapshot) async throws {
        try await base.move(from: from, to: to, expectedSource: expectedSource, expectedDestination: expectedDestination)
        if pauseAfterMove {
            pauseAfterMove = false
            pauseNextSnapshot = true
        }
    }
}
