import Foundation
import Testing
@testable import Alas

@MainActor
struct WorkspaceEditExecutorTests {
    @Test func retiredWatcherDeliveryDoesNotInvalidateCurrentBuffer() async throws {
        let fixture = try await LocalWorkspaceEditFixture()
        defer { fixture.remove() }
        fixture.buffer.startWatching()
        let retiredDelivery = fixture.buffer.watcherEventDeliveryForTesting()
        fixture.buffer.stopWatching()
        fixture.buffer.startWatching()
        let currentDelivery = fixture.buffer.watcherEventDeliveryForTesting()
        let initialGeneration = fixture.buffer.fileWatchGeneration
        retiredDelivery()
        #expect(fixture.buffer.fileWatchGeneration == initialGeneration)
        currentDelivery()
        #expect(fixture.buffer.fileWatchGeneration == initialGeneration + 1)
    }

    @Test func resourceLifecycleClosesBeforeReopeningMovedAndRestoredDocuments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-edit-lsp-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("let value = 1\n".utf8).write(to: root.appendingPathComponent("a.swift"))
        var transports: [FakeTransport] = []
        let lsp = WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: [
            LanguageServerConfig(language: "swift", extensions: ["swift"], command: "/usr/bin/true", args: [], env: [:], rootMarkers: [], enabled: true)
        ]), makeClient: { _, _, _, language, rootURI in
            let transport = FakeTransport()
            transport.onSend = { sent in
                if sent.contains(#""method":"initialize""#) {
                    transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"textDocumentSync":1}}}"#)
                }
            }
            transports.append(transport)
            return LSPClient(transport: transport, language: language, rootURI: rootURI)
        })
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.swift", store: EditorBufferStore(rootOverride: root.appendingPathComponent("snapshots")), worktreeId: "w", tabId: "t", lsp: lsp)
        defer { buffer.close(persistDirtySnapshot: false)
        transports.forEach { $0.finish() } }
        func settle(_ stage: String) async throws {
            var finished = false
            let task = Task { await buffer.awaitWorkspaceEditLifecycle()
            finished = true }
            defer { task.cancel() }
            for _ in 0..<150 where !finished { try await Task.sleep(nanoseconds: 20_000_000) }
            guard finished else {
                let methods = transports.flatMap(\.sent).compactMap { message -> String? in
                    let json = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
                    return json?["method"] as? String
                }
                Issue.record("Lifecycle wait timed out at \(stage); sent methods: \(methods)")
                throw CancellationError()
            }
        }
        await buffer.awaitLoadForTesting()
        try await settle("initial attachment")
        buffer.stopWatching()
        buffer.languageOverride = "swift"
        try await settle("language override")
        let destination = EditorDocumentID(host: nil, worktreeID: "w", uri: root.appendingPathComponent("b.other").lspURI)
        try FileManager.default.moveItem(at: root.appendingPathComponent("a.swift"), to: root.appendingPathComponent("b.other"))
        try buffer.rebindWorkspaceEdit(to: destination, expectedGeneration: buffer.editGeneration)
        try await settle("resource move")
        try buffer.applyWorkspaceEditContent(nil, expectedGeneration: buffer.editGeneration)
        try await settle("resource deletion")
        try buffer.applyWorkspaceEditContent(Data("let value = 1\n".utf8), expectedGeneration: buffer.editGeneration)
        try await settle("resource restoration")
        let lifecycle = try transports.flatMap(\.sent).compactMap { message -> String? in
            let json = try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
            guard let method = json?["method"] as? String,
                  method == "textDocument/didOpen" || method == "textDocument/didClose" else { return nil }
            return method
        }
        #expect(lifecycle == ["textDocument/didOpen", "textDocument/didClose", "textDocument/didOpen", "textDocument/didClose", "textDocument/didOpen"])
        #expect(buffer.effectiveLanguage == "swift")
        #expect(buffer.isWatchingForTesting)
    }

    @Test func bufferResourceMutationExcludesSaveAndMove() async throws {
        let fixture = try await LocalWorkspaceEditFixture()
        defer { fixture.remove() }
        try fixture.buffer.beginWorkspaceEditMutation()
        #expect(throws: EditorBuffer.SaveError.self) { try fixture.buffer.save() }
        #expect(throws: EditorBuffer.SaveError.self) { try fixture.buffer.moveTo(relativePath: "b") }
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == "saved")
        fixture.buffer.endWorkspaceEditMutation()
    }

    @Test func inverseMoveNeverOverwritesContentCreatedAfterMoveBack() async throws {
        let fixture = try WorkspaceEditFixture()
        defer { fixture.remove() }
        let source = try #require(fixture.access.files[fixture.b])
        let destination = EditorDocumentID(host: nil, worktreeID: "w", uri: "file:///workspace/c")
        let destinationBefore = WorkspaceFileSnapshot(document: destination, content: Data("overwritten".utf8))
        fixture.access.files[destination] = destinationBefore
        let step = WorkspaceEditPlanStep(kind: .rename, document: fixture.b, destination: destination, before: source,
                                         after: source.replacing(document: destination, content: source.content), destinationBefore: destinationBefore,
                                         annotationID: nil, annotationIDs: [], resourceOptions: nil)
        let plan = WorkspaceEditPlan(steps: [step], finalSnapshots: [:], reviewAnnotations: [:], warnings: [], requiresPreview: true)
        guard case .applied(let id) = await fixture.executor.apply(plan) else { Issue.record("Expected move")
        return }
        fixture.access.onMove = {
            fixture.access.files[destination] = WorkspaceFileSnapshot(document: destination, content: Data("later content".utf8))
        }
        guard case .recoveryRequired = await fixture.executor.recover(id) else { Issue.record("Expected unresolved inverse")
        return }
        #expect(fixture.access.files[destination]?.content == Data("later content".utf8))
        #expect(fixture.access.files[fixture.b]?.content == source.content)
        #expect(!fixture.access.calls.contains("write:c"))
    }

    @Test func localTextEditAndRecoveryKeepDirtyBufferUnsaved() async throws {
        let fixture = try await LocalWorkspaceEditFixture()
        defer { fixture.remove() }
        let before = try await fixture.access.snapshot(fixture.document)
        let step = fixture.step(kind: .text, before: before, content: Data("new dirty".utf8))
        guard case .applied(let id) = await fixture.executor.apply(fixture.plan(step)) else {
            Issue.record("Expected local text edit")
            return
        }
        #expect(fixture.buffer.storage.string == "new dirty")
        #expect(fixture.buffer.dirty)
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == "saved")
        guard case .recovered = await fixture.executor.recover(id) else { Issue.record("Expected recovery")
        return }
        #expect(fixture.buffer.storage.string == "dirty")
        #expect(fixture.buffer.originalText == "saved")
        #expect(fixture.buffer.dirty)
    }

    @Test func openDeletionRestoresDiskBaselineAndDirtyStorage() async throws {
        let fixture = try await LocalWorkspaceEditFixture()
        defer { fixture.remove() }
        let before = try await fixture.access.snapshot(fixture.document)
        guard case .applied(let id) = await fixture.executor.apply(fixture.plan(fixture.step(kind: .delete, before: before, content: nil))) else {
            Issue.record("Expected deletion")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        #expect(fixture.buffer.workspaceEditDeleted)
        #expect(fixture.buffer.storage.string == "dirty")
        guard case .recovered = await fixture.executor.recover(id) else { Issue.record("Expected deletion recovery")
        return }
        await fixture.buffer.awaitWorkspaceEditLifecycle()
        #expect(fixture.buffer.isWatchingForTesting)
        #expect(!fixture.buffer.workspaceEditDeleted)
        #expect(fixture.buffer.storage.string == "dirty")
        #expect(fixture.buffer.originalText == "saved")
        #expect(fixture.buffer.dirty)
        #expect(fixture.buffer.conflict == nil)
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == "saved")
        #expect((try FileManager.default.attributesOfItem(atPath: fixture.file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        try fixture.buffer.save()
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == "dirty")
    }

    @Test func requestGenerationRejectsEditEvenWhenTextChangesBack() async throws {
        let fixture = try await LocalWorkspaceEditFixture()
        defer { fixture.remove() }
        let generations = fixture.tabs.workspaceEditGenerations(host: nil, worktreeID: "w")
        try fixture.access.validateRequestGenerations(generations)
        fixture.buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "later")
        fixture.buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "dirty")
        #expect(throws: WorkspaceEditAccessError.self) { try fixture.access.validateRequestGenerations(generations) }
    }

    @Test func createOverwriteRefusesLiveBufferWithoutChangingDiskOrText() async throws {
        let fixture = try await LocalWorkspaceEditFixture()
        defer { fixture.remove() }
        let before = try await fixture.access.snapshot(fixture.document)
        guard case .recovered = await fixture.executor.apply(fixture.plan(fixture.step(kind: .create, before: before, content: Data()))) else {
            Issue.record("Expected conservative refusal")
            return
        }
        #expect(fixture.buffer.storage.string == "dirty")
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == "saved")
    }

    @Test func localAdapterRenamesDirtyBufferAndRestoresItsIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-edit-local-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("a")
        let destinationURL = root.appendingPathComponent("b")
        try Data("saved".utf8).write(to: sourceURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: sourceURL.path)
        let tabs = TabsManager(tabsDirectory: root.appendingPathComponent("tabs"))
        let tab = tabs.openEditor(worktreeId: "w", relativePath: "a", revealLine: nil, revealCharacter: nil)
        let buffer = tabs.buffer(worktreeId: "w", tabId: tab.id, worktreeRoot: root, relativePath: "a")
        await buffer.awaitLoadForTesting()
        buffer.stopWatching()
        defer { buffer.close(persistDirtySnapshot: false) }
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "dirty")
        buffer.languageOverride = "swift"
        let source = EditorDocumentID(host: nil, worktreeID: "w", uri: sourceURL.lspURI)
        let destination = EditorDocumentID(host: nil, worktreeID: "w", uri: destinationURL.lspURI)
        let access = HostWorkspaceEditFileAccess(tabs: tabs, rootForDocument: { _ in root })
        let before = try await access.snapshot(source)
        let missing = try await access.snapshot(destination)
        let step = WorkspaceEditPlanStep(kind: .rename, document: source, destination: destination, before: before,
                                         after: before.replacing(document: destination, content: before.content),
                                         destinationBefore: missing, annotationID: nil, annotationIDs: [], resourceOptions: nil)
        let plan = WorkspaceEditPlan(steps: [step], finalSnapshots: [:], reviewAnnotations: [:], warnings: [], requiresPreview: true)
        let journal = WorkspaceEditJournal(root: root.appendingPathComponent("journal"))
        let executor = WorkspaceEditExecutor(access: access, journal: journal)
        guard case .applied(let id) = await executor.apply(plan) else { Issue.record("Expected local resource move")
        return }
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(try String(contentsOf: destinationURL, encoding: .utf8) == "saved")
        #expect(buffer.storage.string == "dirty")
        #expect(buffer.dirty)
        #expect(buffer.languageOverride == "swift")
        #expect(tabs.workspaceEditBuffer(for: destination) === buffer)
        #expect(tabs.workspaceEditBuffer(for: source) == nil)
        if case .editor(let state) = tabs.tabs(forWorktree: "w").first {
            #expect(state.relativePath == "b")
        } else { Issue.record("Expected editor tab") }
        let recovery = await executor.recover(id)
        guard case .recovered = recovery else {
            let recorded = try journal.record(id).entries.first?.observedAfter?.last
            Issue.record("Expected inverse local resource move, got \(recovery); path=\(buffer.relativePath), edit=\(buffer.editGeneration), watch=\(buffer.fileWatchGeneration), recorded edit=\(recorded?.bufferGeneration ?? -1), recorded watch=\(recorded?.fileWatchGeneration ?? -1)")
            return
        }
        #expect(buffer.relativePath == "a")
        #expect(buffer.storage.string == "dirty")
        #expect(try String(contentsOf: sourceURL, encoding: .utf8) == "saved")
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
        #expect((try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o640)
    }

    @Test func journalPermissionsAndPruningKeepUnresolvedRecords() async throws {
        let fixture = try WorkspaceEditFixture()
        defer { fixture.remove() }
        guard case .applied(let id) = await fixture.executor.apply(fixture.plan) else { Issue.record("Expected applied")
        return }
        let pending = try fixture.journal.recordPrepared(fixture.plan)
        let manifest = fixture.root.appendingPathComponent("\(id.uuidString).json")
        #expect((try FileManager.default.attributesOfItem(atPath: manifest.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try fixture.journal.cleanSuccessfulRecords(retaining: [id])
        #expect(try fixture.journal.records().count == 2)
        try fixture.journal.cleanSuccessfulRecords(retaining: [])
        #expect(try fixture.journal.records().map(\.id) == [pending.id])
    }

    @Test func appliesTwoFileRenameWithoutSavingDirtyBuffer() async throws {
        let fixture = try WorkspaceEditFixture()
        defer { fixture.remove() }
        let outcome = await fixture.executor.apply(fixture.plan)
        guard case .applied = outcome else { Issue.record("Expected applied, got \(outcome)")
        return }
        #expect(fixture.access.files[fixture.a]?.content == Data("new dirty".utf8))
        #expect(fixture.access.files[fixture.a]?.isDirty == true)
        #expect(fixture.access.files[fixture.a]?.diskContent == Data("old saved".utf8))
        #expect(fixture.access.files[fixture.b]?.content == Data("new disk".utf8))
        #expect(fixture.access.calls == ["read:a", "read:b", "read:a", "write:a", "read:a", "read:b", "write:b", "read:b"])
        let record = try #require(fixture.journal.records().first)
        #expect(record.status == .applied)
        #expect(record.entries.map(\.state) == [.confirmed, .confirmed])
    }

    @Test func previewTimeConflictDoesNotWriteAnything() async throws {
        let fixture = try WorkspaceEditFixture()
        defer { fixture.remove() }
        fixture.access.files[fixture.b] = WorkspaceFileSnapshot(document: fixture.b, content: Data("later".utf8))
        #expect(await fixture.executor.apply(fixture.plan) == .conflict([fixture.b]))
        #expect(fixture.access.calls == ["read:a", "read:b"])
        #expect(fixture.access.files[fixture.a]?.content == Data("old dirty".utf8))
    }

    @Test func restoresConfirmedStepsInReverseOrderAfterFailure() async throws {
        let fixture = try WorkspaceEditFixture()
        defer { fixture.remove() }
        fixture.access.failBeforeWrite = fixture.b
        let outcome = await fixture.executor.apply(fixture.plan)
        guard case .recovered = outcome else { Issue.record("Expected recovery, got \(outcome)")
        return }
        #expect(fixture.access.files[fixture.a]?.content == Data("old dirty".utf8))
        #expect(fixture.access.files[fixture.b]?.content == Data("old disk".utf8))
        #expect(fixture.access.calls.filter { $0.hasPrefix("write:") } == ["write:a", "write:b", "write:a"])
    }

    @Test func preservesLaterContentWhenRecoveryConflicts() async throws {
        let fixture = try WorkspaceEditFixture()
        defer { fixture.remove() }
        fixture.access.failBeforeWrite = fixture.b
        fixture.access.onFailure = {
            fixture.access.files[fixture.a] = WorkspaceFileSnapshot(document: fixture.a, content: Data("later edit".utf8), isOpen: true, isDirty: true)
        }
        let outcome = await fixture.executor.apply(fixture.plan)
        guard case .recoveryRequired(_, let detail) = outcome else { Issue.record("Expected unresolved recovery")
        return }
        #expect(detail.contains(fixture.a.uri))
        #expect(fixture.access.files[fixture.a]?.content == Data("later edit".utf8))
        #expect(fixture.access.calls.filter { $0 == "write:a" }.count == 1)
    }
}

@MainActor
private struct LocalWorkspaceEditFixture {
    let root: URL
    let file: URL
    let tabs: TabsManager
    let buffer: EditorBuffer
    let document: EditorDocumentID
    let access: HostWorkspaceEditFileAccess
    let executor: WorkspaceEditExecutor

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-edit-local-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        file = root.appendingPathComponent("a")
        try Data("saved".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        tabs = TabsManager(tabsDirectory: root.appendingPathComponent("tabs"))
        let tab = tabs.openEditor(worktreeId: "w", relativePath: "a", revealLine: nil, revealCharacter: nil)
        buffer = tabs.buffer(worktreeId: "w", tabId: tab.id, worktreeRoot: root, relativePath: "a")
        await buffer.awaitLoadForTesting()
        buffer.stopWatching()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "dirty")
        document = EditorDocumentID(host: nil, worktreeID: "w", uri: file.lspURI)
        let directory = root
        access = HostWorkspaceEditFileAccess(tabs: tabs, rootForDocument: { _ in directory })
        executor = WorkspaceEditExecutor(access: access, journal: WorkspaceEditJournal(root: root.appendingPathComponent("journal")))
    }

    func step(kind: WorkspaceEditPlanStep.Kind, before: WorkspaceFileSnapshot, content: Data?) -> WorkspaceEditPlanStep {
        WorkspaceEditPlanStep(kind: kind, document: document, destination: nil, before: before, after: before.replacing(content: content),
                              destinationBefore: nil, annotationID: nil, annotationIDs: [], resourceOptions: nil)
    }

    func plan(_ step: WorkspaceEditPlanStep) -> WorkspaceEditPlan {
        WorkspaceEditPlan(steps: [step], finalSnapshots: [:], reviewAnnotations: [:], warnings: [], requiresPreview: true)
    }

    func remove() {
        buffer.close(persistDirtySnapshot: false)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
final class MemoryWorkspaceEditAccess: WorkspaceEditFileAccess {
    enum Fault: Error { case disconnected, rejected }
    var files: [EditorDocumentID: WorkspaceFileSnapshot]
    var calls: [String] = []
    var failBeforeWrite: EditorDocumentID?
    var disconnectAfterWrite: EditorDocumentID?
    var disconnected = false
    var onFailure: (() -> Void)?
    var onMove: (() -> Void)?

    init(_ files: [EditorDocumentID: WorkspaceFileSnapshot]) { self.files = files }

    func snapshot(_ document: EditorDocumentID) async throws -> WorkspaceFileSnapshot {
        calls.append("read:\(URL(string: document.uri)!.lastPathComponent)")
        if disconnected { throw Fault.disconnected }
        return files[document] ?? WorkspaceFileSnapshot(document: document, content: nil)
    }

    func replace(_ before: WorkspaceFileSnapshot, with after: WorkspaceFileSnapshot) async throws {
        calls.append("write:\(URL(string: before.document.uri)!.lastPathComponent)")
        if failBeforeWrite == before.document { onFailure?()
        throw Fault.rejected }
        guard files[before.document]?.content == before.content else { throw Fault.rejected }
        files[before.document] = after
        if disconnectAfterWrite == before.document { disconnected = true
        throw Fault.disconnected }
    }

    func move(from: EditorDocumentID, to: EditorDocumentID, expectedSource: WorkspaceFileSnapshot, expectedDestination: WorkspaceFileSnapshot) async throws {
        calls.append("move:\(from.uri):\(to.uri)")
        guard files[from]?.content == expectedSource.content,
              files[to]?.content == expectedDestination.content else { throw Fault.rejected }
        files[from] = WorkspaceFileSnapshot(document: from, content: nil)
        files[to] = expectedSource.replacing(document: to, content: expectedSource.content)
        onMove?()
    }
}

@MainActor
struct WorkspaceEditFixture {
    let a: EditorDocumentID
    let b: EditorDocumentID
    let access: MemoryWorkspaceEditAccess
    let journal: WorkspaceEditJournal
    let executor: WorkspaceEditExecutor
    let plan: WorkspaceEditPlan
    let root: URL

    init(host: String? = nil) throws {
        a = EditorDocumentID(host: host, worktreeID: "w", uri: "file:///workspace/a")
        b = EditorDocumentID(host: host, worktreeID: "w", uri: "file:///workspace/b")
        let first = WorkspaceFileSnapshot(document: a, content: Data("old dirty".utf8), bufferVersion: 1, isOpen: true, isDirty: true, diskContent: Data("old saved".utf8))
        let second = WorkspaceFileSnapshot(document: b, content: Data("old disk".utf8))
        let context = EditorRequestContext(document: a, version: 1, serverGeneration: UUID(), range: LSPRange(start: .init(line: 0, character: 0), end: .init(line: 0, character: 0)))
        let range = LSPRange(start: .init(line: 0, character: 0), end: .init(line: 0, character: 3))
        plan = try WorkspaceEditPlanner.plan(edit: LSPWorkspaceEdit(documentChanges: [
            .textDocument(document: .init(uri: a.uri, version: 1), edits: [.init(range: range, newText: "new")]),
            .textDocument(document: .init(uri: b.uri, version: nil), edits: [.init(range: range, newText: "new")]),
        ]), context: context, snapshots: [a: first, b: second])
        access = MemoryWorkspaceEditAccess([a: first, b: second])
        root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-edit-test-\(UUID())")
        journal = WorkspaceEditJournal(root: root)
        executor = WorkspaceEditExecutor(access: access, journal: journal)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
