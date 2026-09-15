import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite("Code actions", .serialized)
struct CodeActionsFeatureTests {
    @Test @MainActor func cancellingCompletionFollowupCancelsItsOutstandingServerCommand() async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        let commands = AsyncStream<Void>.makeStream()
        defer { commands.continuation.finish() }
        transport.onSend = { sent in
            guard let frame = try? LSPJSONValue.decode(from: Data(sent.utf8)) else { return }
            if frame["method"] == .string("workspace/executeCommand") { commands.continuation.yield(()) }
        }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///fixture")
        let context = EditorRequestContext(document: .init(host: nil, worktreeID: "fixture", uri: "file:///fixture/a.swift"), version: 1, serverGeneration: UUID(), range: .init(start: .init(line: 0, character: 0), end: .init(line: 0, character: 0)))
        let view = CodeTextView(frame: .zero, textContainer: nil)
        let feature = CodeActionsFeature(textView: view, tabs: TabsManager(), root: URL(fileURLWithPath: "/fixture"), synchronize: { _ in (client, context) }, isCurrent: { _ in true }, diagnostics: { [] })
        let command = try LSPCommand(wireValue: .object(["title": .string("Follow up"), "command": .string("followup")]))
        let execution = Task { await feature.performCompletionCommand(command, client: client, context: context) }
        var iterator = commands.stream.makeAsyncIterator()
        _ = await iterator.next()
        feature.cancel()
        await execution.value
        #expect(transport.sent.contains { $0.contains("$/cancelRequest") })
        // A cancelled follow-up must release its session rather than holding
        // this client until the server eventually answers the old command.
        let token = try await client.beginCommandSession { _ in .cancelled }
        await client.endCommandSession(token)
    }

    @Test(arguments: ["unavailable", "unsupported", "empty", "failure", "cancel"])
    @MainActor func mountedPickerShowsImmediateLoadingAndDistinctResults(state: String) async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        transport.onSend = { sent in
            guard let frame = try? LSPJSONValue.decode(from: Data(sent.utf8)), let id = frame["id"] else { return }
            var response: [String: LSPJSONValue] = ["id": id]
            if frame["method"] == .string("initialize") {
                response["result"] = .object(["capabilities": .object(["codeActionProvider": .bool(state != "unsupported")])])
            } else if state == "failure" {
                response["error"] = .object(["code": .number("-32603"), "message": .string("Action fixture failure")])
            } else { response["result"] = .array([]) }
            transport.deliverFrame(String(decoding: try! LSPJSONValue.object(response).encodedData(), as: UTF8.self))
        }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///fixture")
        try await client.initialize()
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: nil)
        view.string = "symbol"
        let notifications = InAppNotificationStore()
        view.notificationStore = notifications
        view.notificationWorktreeID = "fixture"
        let window = NSWindow(contentRect: view.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil)
        window.contentView = nil }
        let context = EditorRequestContext(document: .init(host: nil, worktreeID: "fixture", uri: "file:///fixture/a.swift"), version: 1, serverGeneration: UUID(), range: .init(start: .init(line: 0, character: 0), end: .init(line: 0, character: 0)))
        let started = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish() }
        var resume: CheckedContinuation<(LSPClient, EditorRequestContext)?, Never>?
        let feature = CodeActionsFeature(textView: view, tabs: TabsManager(), root: URL(fileURLWithPath: "/fixture"), synchronize: { _ in
            await withCheckedContinuation { resume = $0
            started.continuation.yield(()) }
        }, isCurrent: { _ in true }, diagnostics: { [] })
        defer { feature.cancel() }
        func picker() throws -> CodeActionPicker {
            let popover = try #require(Mirror(reflecting: feature).children.first { $0.label == "popover" }?.value as? NSPopover)
            return try #require(popover.contentViewController as? NSHostingController<CodeActionPicker>).rootView
        }
        feature.show(range: .init(location: 0, length: 0))
        let original = try picker()
        #expect(original.model.isLoading)
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        if state == "cancel" {
            original.cancel()
            resume?.resume(returning: (client, context))
            feature.show(range: .init(location: 1, length: 0))
            let replacement = try picker()
            _ = await iterator.next()
            original.cancel()
            original.organizeImports()
            #expect(try picker().model === replacement.model)
            #expect(replacement.model.isLoading)
            resume?.resume(returning: nil)
            for _ in 0..<200 where notifications.entries.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            #expect(notifications.entries.first?.message == "Language server unavailable")
            #expect(notifications.entries.first?.severity == .error)
            return
        }
        resume?.resume(returning: state == "unavailable" ? nil : (client, context))
        for _ in 0..<200 where notifications.entries.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let result = try #require(notifications.entries.first)
        #expect(result.severity == (state == "empty" ? .information : .error))
        #expect(Mirror(reflecting: feature).children.first { $0.label == "popover" }?.value as? NSPopover == nil)
        switch state {
        case "unavailable": #expect(result.message == "Language server unavailable")
        case "unsupported": #expect(result.message.contains("not supported"))
        case "failure": #expect(result.message.contains("Action fixture failure"))
        default: #expect(result.message == "No code actions available")
        }
    }

    @Test @MainActor func lateSheetCompletionCannotAcceptTheNextPreview() async throws {
        let fixture = try WorkspaceEditFixture()
        defer { fixture.remove() }
        var closes: [() -> Void] = []
        var completions: [@MainActor @Sendable () -> Void] = []
        let started = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish() }
        let presentation = CodeActionEditPresentation { _, _, close, completion in
            closes.append(close)
            completions.append(completion)
            started.continuation.yield(())
            return {}
        }
        let parent = NSWindow()
        let first = WorkspaceEditPreviewModel(plan: fixture.plan) { _ in .applied(UUID()) }
        let a = Task { await presentation.present(first, parent: parent, forcePreview: true) }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(await first.apply())
        closes[0]()
        #expect(await a.value)

        var secondApplyCount = 0
        let second = WorkspaceEditPreviewModel(plan: fixture.plan) { _ in
            secondApplyCount += 1
            return .applied(UUID())
        }
        let b = Task { await presentation.present(second, parent: parent, forcePreview: true) }
        _ = await iterator.next()
        completions[0]()
        closes[0]()
        #expect(presentation.isPresenting)
        #expect(secondApplyCount == 0)
        presentation.cancel()
        #expect(await b.value == false)
        #expect(!second.didApply)
    }

    @Test(arguments: ["native", "explicit", "task"])
    @MainActor func cancellationNeverAcceptsAnAppliedModel(source: String) async throws {
        let fixture = try WorkspaceEditFixture()
        defer { fixture.remove() }
        let started = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish() }
        var completion: (@MainActor @Sendable () -> Void)?
        let presentation = CodeActionEditPresentation { _, _, _, cancelled in
            completion = cancelled
            started.continuation.yield(())
            return {}
        }
        let model = WorkspaceEditPreviewModel(plan: fixture.plan) { _ in .applied(UUID()) }
        let parent = NSWindow()
        let task = Task { await presentation.present(model, parent: parent, forcePreview: true) }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(await model.apply())
        switch source {
        case "native": completion?()
        case "explicit": presentation.cancel()
        default: task.cancel()
        }
        #expect(await task.value == false)
        #expect(!presentation.isPresenting)
    }

    @Test(arguments: ["none", "untouchedBefore", "untouchedAfter", "editedAfter"])
    @MainActor func postPreviewRebindingValidatesCapturedBuffers(change: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("action-generation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tabs = TabsManager(tabsDirectory: root.appendingPathComponent("tabs"))
        var buffers: [EditorBuffer] = []
        for path in ["a", "b"] {
            try Data("old".utf8).write(to: root.appendingPathComponent(path))
            let tab = tabs.openEditor(worktreeId: "w", relativePath: path, revealLine: nil, revealCharacter: nil)
            let buffer = tabs.buffer(worktreeId: "w", tabId: tab.id, worktreeRoot: root, relativePath: path)
            await buffer.awaitLoadForTesting()
            buffer.stopWatching()
            buffers.append(buffer)
        }
        defer { buffers.forEach { $0.close(persistDirtySnapshot: false) } }
        let a = EditorDocumentID(host: nil, worktreeID: "w", uri: root.appendingPathComponent("a").lspURI)
        let captured = tabs.workspaceEditGenerations(host: nil, worktreeID: "w")
        let access = HostWorkspaceEditFileAccess(tabs: tabs, rootForDocument: { _ in root })
        let before = try await access.snapshot(a)
        let range = LSPRange(start: .init(line: 0, character: 0), end: .init(line: 0, character: 3))
        let edit = LSPWorkspaceEdit(changes: [a.uri: [.init(range: range, newText: "new")]])
        let after = before.replacing(content: Data("new".utf8))
        let step = WorkspaceEditPlanStep(kind: .text, document: a, destination: nil, before: before, after: after,
                                         destinationBefore: nil, annotationID: nil, annotationIDs: [], resourceOptions: nil)
        let plan = WorkspaceEditPlan(steps: [step], finalSnapshots: [a: after], reviewAnnotations: [:], warnings: [], requiresPreview: true)
        let journal = WorkspaceEditJournal(root: root.appendingPathComponent("journal"))
        let executor = WorkspaceEditExecutor(access: access, journal: journal)
        let action = try LSPCodeAction(wireValue: .object([
            "title": .string("Fix"), "edit": LSPJSONValue.decode(from: JSONEncoder().encode(edit)),
            "command": .object(["title": .string("Run"), "command": .string("run")])
        ]))
        var commandRan = false
        let result = try await CodeActionsFeature.perform(action, isCurrent: { true }, apply: { _ in
            // The initiating file is unchanged while another open buffer is edited during preview.
            if change == "untouchedBefore" {
                buffers[1].storage.replaceCharacters(in: NSRange(location: 0, length: 3), with: "user text")
            }
            guard case .applied(let id) = await executor.apply(plan) else { return .cancelled }
            let record = try! journal.record(id)
            let observed = record.entries.flatMap { $0.observedAfter ?? [] }
            let applied = Dictionary(uniqueKeysWithValues: observed.map { ($0.document, $0) })
            if change == "untouchedAfter" {
                buffers[1].storage.replaceCharacters(in: NSRange(location: 0, length: 3), with: "later user text")
            } else if change == "editedAfter" {
                // Restoring identical text must not hide intervening edits to an applied buffer.
                buffers[0].storage.replaceCharacters(in: NSRange(location: 0, length: 3), with: "temporary")
                buffers[0].storage.replaceCharacters(in: NSRange(location: 0, length: 9), with: "new")
            }
            do {
                let actual = try await access.snapshot(a)
                _ = try CodeActionsFeature.validatedGenerations(captured: captured,
                    current: tabs.workspaceEditGenerations(host: nil, worktreeID: "w"), applied: applied, actual: [a: actual])
                return .init(applied: true)
            } catch { return .init(applied: false, failureReason: "Captured buffer changed") }
        }, execute: { _ in commandRan = true })
        #expect(buffers[0].storage.string == "new")
        #expect(result.applied == (change == "none"))
        #expect(commandRan == (change == "none"))
        #expect(change == "none" || result.failureReason != nil)
    }

    @Test func retainsDisabledActionReason() throws {
        let action = try JSONDecoder().decode(LSPCodeAction.self, from: Data(#"{"title":"Extract method","disabled":{"reason":"Select an expression"}}"#.utf8))
        #expect(action.disabled?.reason == "Select an expression")
    }

    @Test func preservesUnionAndOpaqueData() throws {
        let raw = Data(#"[{"title":"Run","command":"server.run","arguments":[90071992547409931234567890]},{"title":"Fix","kind":"quickfix","isPreferred":true,"diagnostics":[{"message":"m","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"data":{"key":1e1000}}],"data":{"token":90071992547409931234567890,"null":null}}]"#.utf8)
        let actions = try LSPCodeAction.decodeList(raw)
        #expect(actions[0].isCommand)
        #expect(actions[0].command?.command == "server.run")
        #expect(!actions[1].isCommand)
        #expect(actions[1].isPreferred == true)
        #expect(try actions[1].wireValue.encodedData().contains(Data("90071992547409931234567890".utf8)))
        #expect(try actions[1].wireValue.encodedData().contains(Data("1e1000".utf8)))
    }

    @Test func resolvePreservesOpaqueTokens() async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        let action = try #require(LSPCodeAction.decodeList(Data(#"[{"title":"Fix","data":{"token":1e1000}}]"#.utf8)).first)
        transport.onSend = { sent in
            #expect(sent.contains("1e1000"))
            transport.deliverFrame(#"{"id":1,"result":{"title":"Fix","data":{"token":1e1000}}}"#)
        }
        let resolved = try await client.resolveCodeAction(action)
        #expect(resolved.data == action.data)
    }

    @Test @MainActor func cancelledEditPreventsCommand() async throws {
        let action = try #require(LSPCodeAction.decodeList(Data(#"[{"title":"Fix","edit":{"changes":{}},"command":{"title":"Run","command":"run"}}]"#.utf8)).first)
        var ran = false
        let result = try await CodeActionsFeature.perform(action, isCurrent: { true }, apply: { _ in .init(applied: false, failureReason: "Cancelled") }, execute: { _ in ran = true })
        #expect(!result.applied)
        #expect(!ran)
    }

    @Test @MainActor func editPrecedesCommandAndStaleContextStopsIt() async throws {
        let action = try #require(LSPCodeAction.decodeList(Data(#"[{"title":"Fix","edit":{"changes":{}},"command":{"title":"Run","command":"run","arguments":[null,1e1000]}}]"#.utf8)).first)
        var events: [String] = []
        let result = try await CodeActionsFeature.perform(action, isCurrent: { true }, apply: { _ in
            events.append("edit")
            return .init(applied: true)
        }, execute: { _ in events.append("command") })
        #expect(result.applied)
        #expect(events == ["edit", "command"])
        var current = true
        events = []
        let stale = try await CodeActionsFeature.perform(action, isCurrent: { current }, apply: { _ in
            current = false
            return .init(applied: true)
        }, execute: { _ in events.append("command") })
        #expect(!stale.applied)
        #expect(events.isEmpty)
    }

    @Test func diagnosticMetadataSurvivesPublishAndActionRequest() async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        let stream = await client.subscribeDiagnostics()
        // Fail promptly if the typed diagnostic decoder still rejects opaque numeric values.
        let fixture = Data(#"{"message":"m","data":{"token":1e1000},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}}"#.utf8)
        _ = try #require(try? JSONDecoder().decode(LSPDiagnostic.self, from: fixture))
        transport.deliverFrame(#"{"method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/a","diagnostics":[{"message":"m","code":12,"tags":[1],"data":{"token":1e1000},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}}]}}"#)
        var iterator = stream.makeAsyncIterator()
        let batch = try #require(await iterator.next())
        transport.onSend = { sent in
            #expect(sent.contains(#""code":12"#))
            #expect(sent.contains("1e1000"))
            #expect(sent.contains("source.organizeImports"))
            transport.deliverFrame(#"{"id":1,"result":[]}"#)
        }
        _ = try await client.codeActions(uri: batch.uri, range: batch.diagnostics[0].range, diagnostics: batch.diagnostics, only: ["source.organizeImports"])
    }

    @Test @MainActor func closingPreviewCancelsItsApplicationTask() async throws {
        let fixture = try WorkspaceEditFixture()
        defer { fixture.remove() }
        let started = AsyncStream<Void>.makeStream()
        let model = WorkspaceEditPreviewModel(plan: fixture.plan) { _ in
            started.continuation.yield(())
            do { try await Task.sleep(nanoseconds: 60_000_000_000) }
            catch { return .recovered("Cancelled") }
            Issue.record("Application did not receive cancellation")
            return .applied(UUID())
        }
        let task = Task { await model.apply() }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        model.cancel()
        #expect(await task.value == false)
        #expect(!model.didApply)
        #expect(await model.apply() == false)
        started.continuation.finish()
    }
}
