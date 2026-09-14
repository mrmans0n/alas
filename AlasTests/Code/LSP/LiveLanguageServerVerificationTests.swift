import AppKit
import Testing
@testable import Alas

/// Opt-in evidence collection against an explicitly selected, already installed
/// local server. This suite never installs tools or connects to an SSH host.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ALAS_LSP_VERIFY"] == "1"))
struct LiveLanguageServerVerificationTests {
    @Test func installedServer() async throws {
        let env = ProcessInfo.processInfo.environment
        let language = try #require(env["ALAS_LSP_VERIFY_LANGUAGE"])
        let executable = try #require(env["ALAS_LSP_VERIFY_EXECUTABLE"])
        let output = URL(fileURLWithPath: try #require(env["ALAS_LSP_VERIFY_OUTPUT"]))
        #expect(FileManager.default.isExecutableFile(atPath: executable))
        let fixture = try Fixture(language: language)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transport = RecordingTransport(executable: executable, traceURL: output.appendingPathExtension("wire.jsonl"))
        let client = LSPClient(transport: transport, language: language, rootURI: fixture.root.lspURI)
        var results: [String: String] = [:]
        defer {
            transport.terminate()
            let report: [String: Any] = ["language": language, "executable": executable,
                                       "fixtureRoot": fixture.root.path,
                                       "path": env["PATH"] ?? "",
                                       "fixture": fixture.source, "closedFixture": fixture.otherSource,
                                       "results": results, "messages": transport.messages]
            do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output) }
            catch { Issue.record("Cannot write live verification report: \(error)") }
        }
        let manager = WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: [LanguageServerConfig(language: language, extensions: [fixture.file.pathExtension], command: executable, args: [], env: [:], rootMarkers: [], enabled: true)]), makeClient: { _, _, _, _, _ in client })
        let tabs = TabsManager(bufferStore: EditorBufferStore(rootOverride: fixture.root.appendingPathComponent("buffers")), lsp: manager, tabsDirectory: fixture.root.appendingPathComponent("tabs"), workspaceEditJournal: WorkspaceEditJournal(root: fixture.root.appendingPathComponent("journal")))
        let buffer = tabs.buffer(worktreeId: "live", tabId: "source", worktreeRoot: fixture.root, relativePath: fixture.relativePath)
        defer { buffer.close(persistDirtySnapshot: false) }
        let initializationWatchdog = Task {
            do { try await Task.sleep(for: .seconds(8))
            await client.shutdown() } catch {}
        }
        defer { initializationWatchdog.cancel() }
        await buffer.awaitLoadForTesting()
        await buffer.awaitWorkspaceEditLifecycle()
        initializationWatchdog.cancel()
        buffer.stopWatching()
        guard await client.isReady else {
            results["initialize"] = "failed: manager could not open the document"
            Issue.record("Installed server initialization did not become ready")
            return
        }
        results["initialize"] = "ready"
        let caps = await client.capabilities
        let dirty = fixture.source + "// unsaved verification note\n"
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: buffer.storage.length), with: dirty)
        await manager.didChange(worktreeRoot: fixture.root, fileURL: fixture.file, languageId: language, text: dirty)
        // Allow the disposable project's initial metadata/index work to settle.
        try await Task.sleep(for: .seconds(3))
        let uri = fixture.file.lspURI
        let declaration = LSPPosition(line: 0, character: fixture.declarationColumn)
        let call = LSPPosition(line: 1, character: fixture.callColumn)
        let range = LSPRange(start: .init(line: 0, character: 0), end: .init(line: 2, character: 0))
        func probe(_ name: String, supported: Bool, _ body: @escaping @Sendable () async throws -> String) async {
            guard supported else { results[name] = "unsupported"
            return }
            let start = ContinuousClock.now
            do { results[name] = "\(try await bounded(body)); elapsed=\(start.duration(to: .now))" }
            catch { results[name] = "failed: \(error); elapsed=\(start.duration(to: .now))" }
        }
        await probe("hover", supported: caps.supports(.hover)) { try await client.hover(uri: uri, position: call) == nil ? "exercised-empty" : "exercised-result" }
        await probe("definition", supported: caps.supports(.definition)) { "locations=\(try await client.definition(uri: uri, position: call).count)" }
        await probe("references", supported: caps.supports(.references)) { "locations=\(try await client.references(uri: uri, position: declaration, includeDeclaration: true).count)" }
        await probe("typeDefinition", supported: caps.supports(.typeDefinition)) { "locations=\(try await client.typeDefinition(uri: uri, position: call).count)" }
        await probe("implementation", supported: caps.supports(.implementation)) { "locations=\(try await client.implementation(uri: uri, position: call).count)" }
        await probe("quickFix", supported: caps.supports(.codeActions)) { "actions=\(try await client.codeActions(uri: uri, range: range, diagnostics: [], only: ["quickfix"]).count)" }
        await probe("refactor", supported: caps.supports(.codeActions)) { "actions=\(try await client.codeActions(uri: uri, range: range, diagnostics: [], only: ["refactor"]).count)" }
        await probe("formatting", supported: caps.supports(.formatDocument)) { "edits=\(try await client.formatting(uri: uri, options: .init(tabSize: 4, insertSpaces: true)).count)" }
        await probe("completion", supported: transport.supports("completionProvider")) {
            let value = try await client.completion(uri: uri, position: .init(line: 1, character: call.character + 2), context: nil)
            return "items=\(value.items.count), snippets=\(value.items.filter { $0.insertTextFormat == .snippet }.count), imports=\(value.items.filter { $0.additionalTextEdits?.isEmpty == false }.count)"
        }
        await probe("signatureHelp", supported: caps.supports(.signatureHelp)) { "signatures=\(try await client.signatureHelp(uri: uri, position: .init(line: 1, character: call.character + 6), context: nil)?.signatures.count ?? 0)" }
        await probe("semanticTokens", supported: caps.semanticTokens != nil) { "integers=\(try await client.semanticTokens(uri: uri, range: range).count)" }
        await probe("inlayHints", supported: caps.supports(.toggleInlayHints)) { "hints=\(try await client.inlayHints(uri: uri, range: range).count)" }
        if caps.supports(.rename) {
            do {
                let renameContext = try #require(await manager.requestContext(forFile: fixture.file, worktreeRoot: fixture.root, worktreeID: "live", range: range))
                if await client.supportsPrepareRename {
                    let prepared = try await bounded { try await client.prepareRename(uri: uri, position: declaration) }
                    results["prepareRename"] = prepared == nil ? "exercised-empty" : "exercised-result"
                } else { results["prepareRename"] = "unsupported" }
                if let edit = try await bounded({ try await client.rename(uri: uri, position: declaration, newName: "welcome") }) {
                    results["rename"] = String(decoding: try JSONEncoder().encode(edit), as: UTF8.self)
                    do { results["renameApplication"] = try await applyRename(edit, fixture: fixture, dirty: dirty, tabs: tabs, buffer: buffer, manager: manager, context: renameContext) }
                    catch { results["renameApplication"] = "failed: \(error)" }
                } else { results["rename"] = "exercised-empty" }
            } catch { results["rename"] = "failed: \(error)" }
        } else { results["rename"] = "unsupported" }
        // A deliberately invalid document tests actual diagnostic publication.
        await manager.didChange(worktreeRoot: fixture.root, fileURL: fixture.file, languageId: language, text: dirty + "\nthis is invalid syntax !!!\n")
        try await Task.sleep(for: .seconds(2))
        results["diagnostics"] = "published=\(transport.diagnosticCount)"
        // Close the document through its owner before terminating the client.
        // Buffer cleanup must never send didClose after a raw-client shutdown.
        await manager.closeDocument(worktreeRoot: fixture.root, fileURL: fixture.file, languageId: language)
    }

    private func applyRename(_ edit: LSPWorkspaceEdit, fixture: Fixture, dirty: String, tabs: TabsManager, buffer: EditorBuffer, manager: WorkspaceLSPManager, context: EditorRequestContext) async throws -> String {
        let document = context.document
        let documents = try RenameFeature.documents(in: edit, context: context)
        let access = HostWorkspaceEditFileAccess(tabs: tabs, rootForDocument: { _ in fixture.root })
        var before: [EditorDocumentID: WorkspaceFileSnapshot] = [:]
        for id in documents { before[id] = try await access.snapshot(id) }
        let plan = try WorkspaceEditPlanner.plan(edit: edit, context: context, snapshots: before)
        let undo = tabs.workspaceEditUndoCoordinator(forWorktreeId: "live", worktreeRoot: fixture.root)
        let preview = WorkspaceEditPreviewModel(plan: plan) {
            guard manager.isCurrent(context) else { return .conflict([document]) }
            return await undo.executor.apply($0)
        }
        #expect(buffer.storage.string == dirty)
        guard await preview.apply(), let operation = preview.appliedOperationID else { return "failed preview/apply: \(preview.errorMessage ?? "unknown")" }
        undo.register(operationID: operation, affectedDocuments: documents)
        #expect(buffer.storage.string.contains("welcome"))
        #expect(buffer.storage.string.hasSuffix("// unsaved verification note\n"))
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == fixture.source)
        for id in documents where id != document {
            #expect(try Data(contentsOf: URL(string: id.uri)!) == Data(fixture.otherSource.replacingOccurrences(of: "greet", with: "welcome").utf8))
        }
        let applied = buffer.storage.string
        // Workspace undo is owned by TabsManager without a mounted text view.
        #expect(await undo.undo(operationID: operation) == .applied(operation))
        #expect(buffer.storage.string == dirty)
        for id in documents where id != document {
            #expect(try Data(contentsOf: URL(string: id.uri)!) == before[id]?.content)
        }
        #expect(await undo.redo(operationID: operation) == .applied(operation))
        #expect(buffer.storage.string == applied)
        for id in documents where id != document {
            #expect(try Data(contentsOf: URL(string: id.uri)!) == Data(fixture.otherSource.replacingOccurrences(of: "greet", with: "welcome").utf8))
        }
        #expect(await undo.undo(operationID: operation) == .applied(operation))
        // A changed closed file while a second preview is open must reject all edits.
        let closed = documents.first { $0 != document }
        var checkedClosedConflict = false
        if let closed, let url = URL(string: closed.uri), edit.documentChanges == nil {
            var current: [EditorDocumentID: WorkspaceFileSnapshot] = [:]
            for id in documents { current[id] = try await access.snapshot(id) }
            let refreshedContext = try #require(await manager.requestContext(forFile: fixture.file, worktreeRoot: fixture.root, worktreeID: "live", range: context.range))
            let stalePlan = try WorkspaceEditPlanner.plan(edit: edit, context: refreshedContext, snapshots: current)
            let stalePreview = WorkspaceEditPreviewModel(plan: stalePlan) { await undo.executor.apply($0) }
            try Data("// external edit\n".utf8).write(to: url)
            #expect(await stalePreview.apply() == false)
            #expect(buffer.storage.string == dirty)
            #expect(try String(contentsOf: url, encoding: .utf8) == "// external edit\n")
            checkedClosedConflict = true
        }
        return "documents=\(documents.count), version=\(context.version), preview=\(plan.requiresPreview), dirty-buffer/apply/undo/redo passed, closed-file conflict=\(checkedClosedConflict ? "passed" : "unrun")"
    }

    private nonisolated func bounded<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: body)
            group.addTask { try await Task.sleep(for: .seconds(8))
            throw LSPError.requestTimedOut }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private struct Fixture: Sendable {
        let root: URL
        let relativePath: String
        let source: String
        let otherSource: String
        let declarationColumn: Int
        let callColumn: Int
        var file: URL { root.appendingPathComponent(relativePath) }
        init(language: String) throws {
            // SourceKit can emit both aliased and canonical temporary paths.
            // Use an ignored fixture inside this checkout with one path spelling.
            let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            root = checkout.appendingPathComponent(".build/live-lsp-verification/\(language)-\(UUID())")
            let manifest: (String, String)
            let otherPath: String
            switch language {
            case "swift":
                relativePath = "Sources/Fixture/Main.swift"
                otherPath = "Sources/Fixture/Other.swift"
                source = "public func greet(_ value: Int) -> Int { value + 1 }\npublic let answer = greet(1)\n"
                otherSource = "public let other = greet(2)\n"
                manifest = ("Package.swift", "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"Fixture\", products: [.library(name: \"Fixture\", targets: [\"Fixture\"])], targets: [.target(name: \"Fixture\")])\n")
            case "rust":
                relativePath = "src/lib.rs"
                otherPath = "src/other.rs"
                source = "pub fn greet(value: i32) -> i32 { value + 1 }\npub fn answer() -> i32 { greet(1) }\nmod other;\n"
                otherSource = "pub fn other() -> i32 { crate::greet(2) }\n"
                manifest = ("Cargo.toml", "[package]\nname = \"fixture\"\nversion = \"0.1.0\"\nedition = \"2021\"\n")
            default:
                relativePath = "main.ts"
                otherPath = "other.ts"
                source = "export function greet(value: number): number { return value + 1; }\nexport const answer = greet(1);\n"
                otherSource = "import { greet } from './main';\nexport const other = greet(2);\n"
                manifest = ("tsconfig.json", "{\"compilerOptions\":{\"strict\":true},\"include\":[\"*.ts\"]}")
            }
            declarationColumn = (source.components(separatedBy: "\n")[0] as NSString).range(of: "greet").location + 1
            callColumn = (source.components(separatedBy: "\n")[1] as NSString).range(of: "greet").location + 1
            for (path, content) in [(relativePath, source), (otherPath, otherSource), manifest] {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(content.utf8).write(to: url)
            }
            #expect(root.standardizedFileURL.path == root.path)
            #expect(root.resolvingSymlinksInPath().path == root.path)
        }
    }
}

private final class RecordingTransport: LSPTransporting, @unchecked Sendable {
    private let base: LSPTransport
    private let lock = NSLock()
    private var recorded: [[String: Any]] = []
    private var pump: Task<Void, Never>?
    private let trace: FileHandle?
    let incoming: AsyncStream<LSPTransport.Incoming>
    private let continuation: AsyncStream<LSPTransport.Incoming>.Continuation
    var messages: [[String: Any]] { lock.withLock { recorded } }
    var diagnosticCount: Int {
        messages.filter { $0["method"] as? String == "textDocument/publishDiagnostics" }.reduce(0) { $0 + (($1["params"] as? [String: Any])?["diagnostics"] as? [Any] ?? []).count }
    }
    func supports(_ provider: String) -> Bool {
        messages.contains { message in
            guard let value = (message["result"] as? [String: Any])?["capabilities"] as? [String: Any], let capability = value[provider] else { return false }
            return (capability as? Bool) != false
        }
    }
    init(executable: String, traceURL: URL) {
        base = LSPTransport(executable: URL(fileURLWithPath: executable), arguments: [], environment: nil)
        FileManager.default.createFile(atPath: traceURL.path, contents: nil)
        trace = try? FileHandle(forWritingTo: traceURL)
        let stream = AsyncStream<LSPTransport.Incoming>.makeStream()
        incoming = stream.stream
        continuation = stream.continuation
    }
    func start() throws {
        pump = Task { [weak self, base] in
            for await event in base.incoming {
                guard let self else { return }
                if case .frame(let data) = event, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    lock.withLock { recorded.append(value) }
                    recordTrace("receive", data: data)
                } else if case .stderr(let data) = event {
                    lock.withLock { recorded.append(["stderr": String(decoding: data, as: UTF8.self)]) }
                    recordTrace("stderr", data: data)
                } else if case .exited(let status) = event {
                    recordTrace("exit", data: Data(String(status).utf8))
                }
                continuation.yield(event)
            }
            self?.continuation.finish()
        }
        try base.start()
    }
    private func recordTrace(_ direction: String, data: Data) {
        lock.withLock {
            let value: [String: Any] = ["direction": direction, "time": Date().timeIntervalSince1970, "body": String(decoding: data, as: UTF8.self)]
            if var encoded = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                encoded.append(10)
                try? trace?.write(contentsOf: encoded)
            }
        }
    }
    func send(_ data: Data) throws {
        recordTrace("send", data: data)
        try base.send(data)
    }
    func terminate() { base.terminate()
    pump?.cancel()
    continuation.finish() }
}
