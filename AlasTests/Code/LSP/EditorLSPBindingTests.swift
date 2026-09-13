import Foundation
import Testing
@testable import Alas

@MainActor
struct EditorLSPBindingTests {
    @Test func documentIdentitySeparatesEqualURIsOnDifferentHosts() {
        let local = EditorDocumentID(host: "host-a", worktreeID: "worktree", uri: "file:///srv/repo/main.swift")
        let remote = EditorDocumentID(host: "host-b", worktreeID: "worktree", uri: "file:///srv/repo/main.swift")

        #expect(local != remote)
    }

    @Test func contextBecomesStaleAfterServerRestart() {
        let document = EditorDocumentID(host: nil, worktreeID: "worktree", uri: "file:///tmp/main.swift")
        let range = LSPRange(
            start: LSPPosition(line: 0, character: 0),
            end: LSPPosition(line: 0, character: 1)
        )
        let before = EditorRequestContext(document: document, version: 1, serverGeneration: UUID(), range: range)
        let after = EditorRequestContext(document: document, version: 1, serverGeneration: UUID(), range: range)

        #expect(before != after)
    }

    @Test func capturedContextIsRejectedAfterHolderRestart() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alas-binding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("main.swift")
        let manager = WorkspaceLSPManager(
            registry: LanguageServerRegistry(userDefined: [
                LanguageServerConfig(
                    language: "swift", extensions: ["swift"], command: "/usr/bin/true",
                    args: [], env: [:], rootMarkers: [], enabled: true
                )
            ]),
            makeAvailability: { LanguageServerAvailability(
                environment: [:], xcrunFind: { _ in nil }, additionalPathDirectories: [],
                gatekeeperAssessor: { _ in .allowed }
            ) },
            makeClient: { _, _, _, language, rootURI in
                let transport = FakeTransport()
                transport.onSend = { message in
                    guard let id = Self.requestID(in: message) else { return }
                    if message.contains(#""method":"initialize""#) {
                        transport.deliverFrame(#"{"jsonrpc":"2.0","id":\#(id),"result":{"capabilities":{}}}"#)
                    } else if message.contains(#""method":"shutdown""#) {
                        transport.deliverFrame(#"{"jsonrpc":"2.0","id":\#(id),"result":null}"#)
                    }
                }
                return LSPClient(transport: transport, language: language, rootURI: rootURI)
            }
        )

        _ = await manager.openDocument(worktreeRoot: root, fileURL: file, languageId: "swift", text: "let value = 1")
        let range = LSPRange(start: .init(line: 0, character: 0), end: .init(line: 0, character: 1))
        let context = try #require(await manager.requestContext(
            forFile: file, worktreeRoot: root, worktreeID: "worktree", range: range
        ))
        #expect(manager.isCurrent(context))

        await manager.restartHolder(forFile: file, worktreeRoot: root, languageId: "swift")
        #expect(!manager.isCurrent(context))
    }

    @Test func bindingRejectsCapturedRequestAfterHolderRestart() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alas-binding-buffer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("main.swift")
        try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
        let manager = Self.makeReadyManager()
        let buffer = EditorBuffer(
            worktreeRoot: root,
            relativePath: "main.swift",
            store: EditorBufferStore(rootOverride: root.appendingPathComponent("state")),
            worktreeId: "worktree",
            tabId: "tab",
            lsp: manager
        )
        defer { buffer.close(persistDirtySnapshot: false) }
        await buffer.awaitLoadForTesting()

        let deadline = Date().addingTimeInterval(2)
        while !manager.isDocumentOpen(fileURL: file, worktreeRoot: root), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let binding = EditorLSPBinding(manager: manager, buffer: buffer, worktreeID: "worktree")
        let request = try #require(await binding.synchronizeRequest(
            range: NSRange(location: 0, length: 0), language: "swift"
        ))
        #expect(binding.isCurrent(request.1))

        await manager.restartHolder(forFile: file, worktreeRoot: root, languageId: "swift")
        #expect(!binding.isCurrent(request.1))
    }

    @Test func remoteDocumentHasOneOpenChangeRequestCloseLifecycle() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alas-remote-lsp-\(UUID().uuidString)")
        let file = root.appendingPathComponent("main.swift")
        let host = "lsp-test-host"
        RemoteHostRegistry.shared.register(root: root.path, host: host)
        defer { RemoteHostRegistry.shared.unregister(root: root.path) }

        var transport: FakeTransport?
        let manager = WorkspaceLSPManager(
            registry: LanguageServerRegistry(userDefined: [
                LanguageServerConfig(
                    language: "swift", extensions: ["swift"], command: "/usr/bin/true",
                    args: [], env: [:], rootMarkers: [], enabled: true
                )
            ]),
            makeAvailability: { LanguageServerAvailability() },
            remoteLSPAvailable: { command, requestedHost, _ in
                command == "/usr/bin/true" && requestedHost == host
            },
            makeClient: { _, _, _, language, rootURI in
                let fake = FakeTransport()
                fake.onSend = { message in
                    guard let id = Self.requestID(in: message) else { return }
                    if message.contains(#""method":"initialize""#) {
                        fake.deliverFrame(#"{"jsonrpc":"2.0","id":\#(id),"result":{"capabilities":{}}}"#)
                    } else if message.contains(#""method":"textDocument/hover""#) {
                        fake.deliverFrame(#"{"jsonrpc":"2.0","id":\#(id),"result":null}"#)
                    } else if message.contains(#""method":"shutdown""#) {
                        fake.deliverFrame(#"{"jsonrpc":"2.0","id":\#(id),"result":null}"#)
                    }
                }
                transport = fake
                return LSPClient(transport: fake, language: language, rootURI: rootURI)
            }
        )
        defer { transport?.finish() }

        let client = try #require(await manager.openDocument(
            worktreeRoot: root, fileURL: file, languageId: "swift", text: "let value = 1"
        ))
        await manager.didChange(
            worktreeRoot: root, fileURL: file, languageId: "swift", text: "let value = 2"
        )
        let context = try #require(await manager.requestContext(
            forFile: file,
            worktreeRoot: root,
            worktreeID: "remote-worktree",
            range: LSPRange(start: .init(line: 0, character: 0), end: .init(line: 0, character: 1))
        ))
        #expect(context.document.host == host)
        _ = try await client.hover(uri: file.lspURI, position: context.range.start)
        await manager.closeDocument(worktreeRoot: root, fileURL: file, languageId: "swift")

        let sent = try #require(transport?.sent)
        let methods = sent.compactMap { message -> String? in
            guard let range = message.range(of: #""method":""#) else { return nil }
            let method = message[range.upperBound...]
            return method.split(separator: "\"").first.map(String.init)
        }
        #expect(methods == [
            "initialize", "initialized", "textDocument/didOpen", "textDocument/didChange",
            "textDocument/hover", "textDocument/didClose", "shutdown", "exit"
        ])
    }

    private static func requestID(in json: String) -> Int? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["id"] as? Int
    }

    private static func makeReadyManager() -> WorkspaceLSPManager {
        WorkspaceLSPManager(
            registry: LanguageServerRegistry(userDefined: [
                LanguageServerConfig(
                    language: "swift", extensions: ["swift"], command: "/usr/bin/true",
                    args: [], env: [:], rootMarkers: [], enabled: true
                )
            ]),
            makeAvailability: { LanguageServerAvailability(
                environment: [:], xcrunFind: { _ in nil }, additionalPathDirectories: [],
                gatekeeperAssessor: { _ in .allowed }
            ) },
            makeClient: { _, _, _, language, rootURI in
                let transport = FakeTransport()
                transport.onSend = { message in
                    guard let id = Self.requestID(in: message) else { return }
                    if message.contains(#""method":"initialize""#) {
                        transport.deliverFrame(#"{"jsonrpc":"2.0","id":\#(id),"result":{"capabilities":{}}}"#)
                    } else if message.contains(#""method":"shutdown""#) {
                        transport.deliverFrame(#"{"jsonrpc":"2.0","id":\#(id),"result":null}"#)
                    }
                }
                return LSPClient(transport: transport, language: language, rootURI: rootURI)
            }
        )
    }
}
