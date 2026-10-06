import Testing
import Foundation
@testable import Alas

@MainActor
@Suite("WorkspaceLSPManager.documentStatus")
struct WorkspaceLSPManagerStatusTests {
    private let root: URL
    private let fileURL: URL

    init() throws {
        let r = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("alas-lsp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        self.root = r
        self.fileURL = r.appendingPathComponent("main.swift")
    }

    private func manager(
        withFakeEntry language: String = "swift",
        enabled: Bool = true,
        rootMarkers: [String] = [],
        makeClient: ((_ executable: URL, _ arguments: [String], _ environment: [String: String], _ language: String, _ rootURI: String, _ remoteHost: String?) -> LSPClient)? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in throw CancellationError() }
    ) -> WorkspaceLSPManager {
        let makeClient = makeClient ?? { _, _, _, language, rootURI, _ in
            readyClient(language: language, rootURI: rootURI)
        }
        let registry = LanguageServerRegistry(userDefined: [
            LanguageServerConfig(
                language: language,
                extensions: ["swift"],
                command: "/usr/bin/true",
                args: [],
                env: [:],
                rootMarkers: rootMarkers,
                enabled: enabled
            )
        ])
        return manager(registry: registry, makeClient: makeClient, sleep: sleep)
    }

    private func manager(
        registry: LanguageServerRegistry,
        makeClient: @escaping (_ executable: URL, _ arguments: [String], _ environment: [String: String], _ language: String, _ rootURI: String, _ remoteHost: String?) -> LSPClient,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in throw CancellationError() }
    ) -> WorkspaceLSPManager {
        WorkspaceLSPManager(
            registry: registry,
            makeAvailability: {
                LanguageServerAvailability(
                    environment: [:],
                    xcrunFind: { _ in nil },
                    additionalPathDirectories: [],
                    gatekeeperAssessor: { _ in .allowed }
                )
            },
            makeClient: makeClient,
            sleep: sleep
        )
    }

    private func readyClient(language: String, rootURI: String) -> LSPClient {
        LSPClient(transport: Self.replyingTransport(), language: language, rootURI: rootURI)
    }

    private static func replyingTransport(repliesToShutdown: Bool = true) -> FakeTransport {
        let transport = FakeTransport()
        transport.onSend = { sent in
            guard let id = requestId(in: sent) else { return }
            if sent.contains(#""method":"initialize""#) {
                transport.deliverFrame(
                    #"{"jsonrpc":"2.0","id":\#(id),"result":{"capabilities":{"textDocumentSync":1}}}"#
                )
            } else if repliesToShutdown, sent.contains(#""method":"shutdown""#) {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":\#(id),"result":null}"#)
            }
        }
        return transport
    }

    private static func requestId(in json: String) -> Int? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["id"] as? Int
    }

    @Test func documentStatusIsNoneBeforeOpen() {
        let mgr = manager()
        #expect(mgr.documentStatus(forFile: fileURL, worktreeRoot: root) == .none)
    }

    @Test func remoteRootProbeCommandUsesQuotedMarkerVariables() {
        let command = WorkspaceLSPManager.remoteLSPRootProbeCommand(
            fileURL: URL(fileURLWithPath: "/srv/repo/Package/Sources/App/main.swift"),
            worktreeRoot: URL(fileURLWithPath: "/srv/repo"),
            markers: ["Package.swift", "*.xcodeproj", "quote'file"]
        )

        #expect(command.contains("root='/srv/repo'"))
        #expect(command.contains("m0='Package.swift'"))
        #expect(command.contains("m1='*.xcodeproj'"))
        #expect(command.contains("m2='quote'\\''file'"))
        #expect(command.contains("find \"$dir\" -maxdepth 1 -name \"$m1\""))
        #expect(command.contains("[ -e \"$dir/$m0\" ]"))
        #expect(!command.contains("dirname --"))
    }

    @Test func stateTickStartsAtZero() {
        let mgr = manager()
        #expect(mgr.stateTick == 0)
    }

    @Test func stateTickBumpsWhenHolderInserted() async {
        let mgr = manager()
        let before = mgr.stateTick
        _ = await mgr.openDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift", text: "")
        #expect(mgr.stateTick > before)
    }

    @Test func restartHolderReopensPreviouslyOpenURIs() async {
        let mgr = manager()
        _ = await mgr.openDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift", text: "")
        #expect(mgr.documentStatus(forFile: fileURL, worktreeRoot: root) != .none)
        let beforeTick = mgr.stateTick
        await mgr.restartHolder(forLanguage: "swift", rootURL: root)
        #expect(mgr.stateTick > beforeTick)
        // After restart, the document should be tracked again (status is at
        // least .loading; depending on whether the fake binary "succeeds"
        // initialize, may be .ready or .dead — but never .none).
        #expect(mgr.documentStatus(forFile: fileURL, worktreeRoot: root) != .none)
    }

    @Test func restartHolderOnNoMatchingHolderIsNoOp() async {
        let mgr = manager()
        let beforeTick = mgr.stateTick
        await mgr.restartHolder(forLanguage: "swift", rootURL: root)
        #expect(mgr.stateTick == beforeTick)
    }

    @Test func blockedByGatekeeperIsReprobedNotCached() {
        // After the user clicks Allow on the blocked nudge, the Gatekeeper
        // assessor flips from .rejected to .allowed. The manager must not
        // serve a stale .blockedByGatekeeper from its per-language cache,
        // or the status badge keeps the binary "blocked" until something
        // else clears it.
        final class Box { var result: GatekeeperAssessor.Result = .rejected }
        let box = Box()
        let registry = LanguageServerRegistry(userDefined: [
            LanguageServerConfig(
                language: "swift",
                extensions: ["swift"],
                command: "/usr/bin/true",
                args: [],
                env: [:],
                rootMarkers: [],
                enabled: true
            )
        ])
        let mgr = WorkspaceLSPManager(
            registry: registry,
            makeAvailability: {
                LanguageServerAvailability(
                    environment: [:],
                    xcrunFind: { _ in nil },
                    additionalPathDirectories: [],
                    gatekeeperAssessor: { _ in box.result }
                )
            }
        )
        #expect(mgr.availabilityStatus(forLanguage: "swift") == .blockedByGatekeeper(realPath: "/usr/bin/true"))
        box.result = .allowed
        #expect(mgr.availabilityStatus(forLanguage: "swift") == .available)
    }

    @Test func availableStatusIsCached() {
        final class Box { var calls = 0 }
        let box = Box()
        let registry = LanguageServerRegistry(userDefined: [
            LanguageServerConfig(
                language: "swift",
                extensions: ["swift"],
                command: "/usr/bin/true",
                args: [],
                env: [:],
                rootMarkers: [],
                enabled: true
            )
        ])
        let mgr = WorkspaceLSPManager(
            registry: registry,
            makeAvailability: {
                LanguageServerAvailability(
                    environment: [:],
                    xcrunFind: { _ in nil },
                    additionalPathDirectories: [],
                    gatekeeperAssessor: { _ in
                        box.calls += 1
                        return .allowed
                    }
                )
            }
        )
        _ = mgr.availabilityStatus(forLanguage: "swift")
        _ = mgr.availabilityStatus(forLanguage: "swift")
        #expect(box.calls == 1)
    }

    @Test func notInstalledStatusIsCachedUntilInvalidated() {
        final class Box { var calls = 0 }
        let box = Box()
        let registry = LanguageServerRegistry(userDefined: [
            LanguageServerConfig(
                language: "swift",
                extensions: ["swift"],
                command: "sourcekit-lsp",
                args: [],
                env: [:],
                rootMarkers: [],
                enabled: true
            )
        ])
        let mgr = WorkspaceLSPManager(
            registry: registry,
            makeAvailability: {
                LanguageServerAvailability(
                    environment: ["PATH": ""],
                    xcrunFind: { _ in
                        box.calls += 1
                        return nil
                    },
                    additionalPathDirectories: [],
                    gatekeeperAssessor: { _ in .allowed }
                )
            }
        )

        _ = mgr.availabilityStatus(forLanguage: "swift")
        _ = mgr.availabilityStatus(forLanguage: "swift")
        #expect(box.calls == 1)

        mgr.invalidateAvailabilityCache(forLanguage: "swift")
        _ = mgr.availabilityStatus(forLanguage: "swift")
        #expect(box.calls == 2)
    }

    @Test func nonXcrunNotInstalledStatusIsReprobed() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-lsp-availability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("rust-analyzer")
        let registry = LanguageServerRegistry(userDefined: [
            LanguageServerConfig(
                language: "rust",
                extensions: ["rs"],
                command: "rust-analyzer",
                args: [],
                env: [:],
                rootMarkers: [],
                enabled: true
            )
        ])
        let mgr = WorkspaceLSPManager(
            registry: registry,
            makeAvailability: {
                LanguageServerAvailability(
                    environment: ["PATH": dir.path],
                    xcrunFind: { _ in nil },
                    additionalPathDirectories: [],
                    gatekeeperAssessor: { _ in .allowed }
                )
            }
        )

        #expect(mgr.availabilityStatus(forLanguage: "rust") == .notInstalled)
        #expect(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        #expect(mgr.availabilityStatus(forLanguage: "rust") == .available)
    }

    @Test func openDocumentRemediatesGatekeeperBlockBeforeSpawning() async {
        final class Box {
            let path = "/usr/bin/true"
            var blocked = true
            var remediated: [String] = []
        }
        let box = Box()
        let registry = LanguageServerRegistry(userDefined: [
            LanguageServerConfig(
                language: "swift",
                extensions: ["swift"],
                command: box.path,
                args: [],
                env: [:],
                rootMarkers: [],
                enabled: true
            )
        ])
        let mgr = WorkspaceLSPManager(
            registry: registry,
            makeAvailability: {
                LanguageServerAvailability(
                    environment: [:],
                    xcrunFind: { _ in nil },
                    additionalPathDirectories: [],
                    gatekeeperAssessor: { _ in box.blocked ? .rejected : .allowed },
                    gatekeeperRemediator: { path, _ in
                        box.remediated.append(path)
                        box.blocked = false
                        return .allowed
                    }
                )
            },
            makeClient: { _, _, _, language, rootURI, _ in
                readyClient(language: language, rootURI: rootURI)
            }
        )

        _ = await mgr.openDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift", text: "")

        #expect(box.remediated == [box.path])
        #expect(mgr.documentStatus(forFile: fileURL, worktreeRoot: root) != .none)
    }

    @Test func openDocumentPostsBlockedNotificationWhenRemediationFails() async {
        let box = BlockedNotificationBox()
        let registry = LanguageServerRegistry(userDefined: [
            LanguageServerConfig(
                language: "swift",
                extensions: ["swift"],
                command: box.path,
                args: [],
                env: [:],
                rootMarkers: [],
                enabled: true
            )
        ])
        let token = NotificationCenter.default.addObserver(
            forName: .lspBlockedByGatekeeper,
            object: nil,
            queue: nil
        ) { note in
            box.notificationRealPath = note.userInfo?["realPath"] as? String
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let mgr = WorkspaceLSPManager(
            registry: registry,
            makeAvailability: {
                LanguageServerAvailability(
                    environment: [:],
                    xcrunFind: { _ in nil },
                    additionalPathDirectories: [],
                    gatekeeperAssessor: { _ in .rejected },
                    gatekeeperRemediator: { _, _ in .failed("nope") }
                )
            }
        )

        _ = await mgr.openDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift", text: "")

        #expect(box.notificationRealPath == box.path)
        #expect(mgr.documentStatus(forFile: fileURL, worktreeRoot: root) == .none)
    }

    @Test func concurrentOpenDocumentsJoinHolderInsertedAfterRemediation() async {
        let box = PairedRemediationBox()
        let otherFileURL = root.appendingPathComponent("other.swift")
        let registry = LanguageServerRegistry(userDefined: [
            LanguageServerConfig(
                language: "swift",
                extensions: ["swift"],
                command: box.path,
                args: [],
                env: [:],
                rootMarkers: [],
                enabled: true
            )
        ])
        let mgr = WorkspaceLSPManager(
            registry: registry,
            makeAvailability: {
                LanguageServerAvailability(
                    environment: [:],
                    xcrunFind: { _ in nil },
                    additionalPathDirectories: [],
                    gatekeeperAssessor: { _ in box.blocked ? .rejected : .allowed },
                    gatekeeperRemediator: { _, _ in await box.waitForBothRemediationAttempts() }
                )
            },
            makeClient: { _, _, _, language, rootURI, _ in
                readyClient(language: language, rootURI: rootURI)
            }
        )

        async let first: LSPClient? = mgr.openDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift", text: "")
        async let second: LSPClient? = mgr.openDocument(worktreeRoot: root, fileURL: otherFileURL, languageId: "swift", text: "")
        _ = await (first, second)

        #expect(mgr.documentStatus(forFile: fileURL, worktreeRoot: root) != .none)
        #expect(mgr.documentStatus(forFile: otherFileURL, worktreeRoot: root) != .none)
    }

    @Test func closeDuringRemediationCancelsPendingOpen() async {
        let box = ParkedRemediationBox()
        let registry = LanguageServerRegistry(userDefined: [
            LanguageServerConfig(
                language: "swift",
                extensions: ["swift"],
                command: box.path,
                args: [],
                env: [:],
                rootMarkers: [],
                enabled: true
            )
        ])
        let mgr = WorkspaceLSPManager(
            registry: registry,
            makeAvailability: {
                LanguageServerAvailability(
                    environment: [:],
                    xcrunFind: { _ in nil },
                    additionalPathDirectories: [],
                    gatekeeperAssessor: { _ in box.blocked ? .rejected : .allowed },
                    gatekeeperRemediator: { _, _ in await box.remediate() }
                )
            }
        )

        async let opened: LSPClient? = mgr.openDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift", text: "")
        await box.waitUntilRemediationIsParked()
        await mgr.closeDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift")
        box.blocked = false
        box.finishRemediation(.allowed)
        _ = await opened

        #expect(mgr.documentStatus(forFile: fileURL, worktreeRoot: root) == .none)
    }

    @Test func closeDuringRemediationCancelsPendingOpenAfterRegistryChange() async {
        let box = ParkedRemediationBox()
        let initialRegistry = LanguageServerRegistry(userDefined: [
            LanguageServerConfig(
                language: "swift",
                extensions: ["swift"],
                command: box.path,
                args: [],
                env: [:],
                rootMarkers: [],
                enabled: true
            )
        ])
        let mgr = WorkspaceLSPManager(
            registry: initialRegistry,
            makeAvailability: {
                LanguageServerAvailability(
                    environment: [:],
                    xcrunFind: { _ in nil },
                    additionalPathDirectories: [],
                    gatekeeperAssessor: { _ in box.blocked ? .rejected : .allowed },
                    gatekeeperRemediator: { _, _ in await box.remediate() }
                )
            }
        )

        async let opened: LSPClient? = mgr.openDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift", text: "")
        await box.waitUntilRemediationIsParked()
        mgr.updateRegistry(LanguageServerRegistry(userDefined: [
            LanguageServerConfig(
                language: "swift",
                extensions: ["swift"],
                command: "/usr/bin/false",
                args: [],
                env: [:],
                rootMarkers: [],
                enabled: true
            )
        ]))
        await mgr.closeDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift")
        box.blocked = false
        box.finishRemediation(.allowed)
        _ = await opened

        #expect(mgr.documentStatus(forFile: fileURL, worktreeRoot: root) == .none)
    }

    @Test func editorOpenReplacesTemporaryDiffTextAndTemporaryCloseKeepsEditorOpen() async {
        let transport = FakeTransport()
        transport.onSend = { sent in
            if sent.contains(#""method":"initialize""#) {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"textDocumentSync":1}}}"#)
            }
        }
        let mgr = manager(
            withFakeEntry: "swift",
            makeClient: { _, _, _, language, rootURI, _ in
                LSPClient(transport: transport, language: language, rootURI: rootURI)
            }
        )

        _ = await mgr.openTemporaryDocument(
            worktreeRoot: root,
            fileURL: fileURL,
            languageId: "swift",
            text: "let disk = 1\n"
        )
        _ = await mgr.openDocument(
            worktreeRoot: root,
            fileURL: fileURL,
            languageId: "swift",
            text: "let unsaved = 2\n"
        )

        let didOpen = transport.sent.filter { $0.contains(#""method":"textDocument/didOpen""#) }
        let didChange = transport.sent.filter { $0.contains(#""method":"textDocument/didChange""#) }
        #expect(didOpen.count == 1)
        #expect(didOpen.first?.contains(#""text":"let disk = 1\n""#) == true)
        #expect(didChange.count == 1)
        #expect(didChange.first?.contains(#""text":"let unsaved = 2\n""#) == true)

        await mgr.closeTemporaryDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift")
        #expect(!transport.sent.contains { $0.contains(#""method":"textDocument/didClose""#) })

        await mgr.closeDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift")
        #expect(transport.sent.contains { $0.contains(#""method":"textDocument/didClose""#) })
        transport.finish()
    }

    @Test func editorCloseRestoresTemporaryDiffTextWhenTemporaryRetainRemains() async {
        let transport = FakeTransport()
        transport.onSend = { sent in
            if sent.contains(#""method":"initialize""#) {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"textDocumentSync":1}}}"#)
            }
        }
        let mgr = manager(
            withFakeEntry: "swift",
            makeClient: { _, _, _, language, rootURI, _ in
                LSPClient(transport: transport, language: language, rootURI: rootURI)
            }
        )

        _ = await mgr.openTemporaryDocument(
            worktreeRoot: root,
            fileURL: fileURL,
            languageId: "swift",
            text: "let disk = 1\n"
        )
        _ = await mgr.openDocument(
            worktreeRoot: root,
            fileURL: fileURL,
            languageId: "swift",
            text: "let unsaved = 2\n"
        )
        await mgr.closeDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift")

        let didChange = transport.sent.filter { $0.contains(#""method":"textDocument/didChange""#) }
        #expect(didChange.count == 2)
        #expect(didChange[0].contains(#""text":"let unsaved = 2\n""#))
        #expect(didChange[1].contains(#""text":"let disk = 1\n""#))
        #expect(!transport.sent.contains { $0.contains(#""method":"textDocument/didClose""#) })
        #expect(mgr.documentStatus(forFile: fileURL, worktreeRoot: root) == .ready)

        await mgr.closeTemporaryDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift")
        #expect(transport.sent.contains { $0.contains(#""method":"textDocument/didClose""#) })
        transport.finish()
    }

    @Test func editorCloseBeforeDidOpenRestoresPendingTemporaryDiffText() async {
        final class InitializeGate {
            var continuation: CheckedContinuation<Void, Never>?
            var didInitialize = false

            func markInitialized() {
                didInitialize = true
                continuation?.resume()
                continuation = nil
            }

            func waitUntilInitializeSent() async {
                if didInitialize { return }
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                }
            }
        }
        let gate = InitializeGate()
        let transport = FakeTransport()
        transport.onSend = { sent in
            if sent.contains(#""method":"initialize""#) {
                gate.markInitialized()
            }
        }
        let mgr = manager(
            withFakeEntry: "swift",
            makeClient: { _, _, _, language, rootURI, _ in
                LSPClient(transport: transport, language: language, rootURI: rootURI)
            }
        )

        async let temporary: LSPClient? = mgr.openTemporaryDocument(
            worktreeRoot: root,
            fileURL: fileURL,
            languageId: "swift",
            text: "let disk = 1\n"
        )
        await gate.waitUntilInitializeSent()
        async let editor: LSPClient? = mgr.openDocument(
            worktreeRoot: root,
            fileURL: fileURL,
            languageId: "swift",
            text: "let unsaved = 2\n"
        )
        try? await Task.sleep(nanoseconds: 10_000_000)
        let closeEditor = Task {
            await mgr.closeDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift")
        }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000)

        transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"textDocumentSync":1}}}"#)
        _ = await (temporary, editor)
        await closeEditor.value

        let didOpen = transport.sent.filter { $0.contains(#""method":"textDocument/didOpen""#) }
        #expect(didOpen.count == 1)
        #expect(didOpen.first?.contains(#""text":"let disk = 1\n""#) == true)

        await mgr.closeTemporaryDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift")
        transport.finish()
    }

    @Test func isDocumentOpenRequiresEditorOwnedRefWhenTemporaryRetainExists() async {
        let transport = FakeTransport()
        transport.onSend = { sent in
            if sent.contains(#""method":"initialize""#) {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"textDocumentSync":1}}}"#)
            }
        }
        let mgr = manager(
            withFakeEntry: "swift",
            makeClient: { _, _, _, language, rootURI, _ in
                LSPClient(transport: transport, language: language, rootURI: rootURI)
            }
        )

        _ = await mgr.openTemporaryDocument(
            worktreeRoot: root,
            fileURL: fileURL,
            languageId: "swift",
            text: "let disk = 1\n"
        )
        #expect(mgr.isDocumentOpen(fileURL: fileURL, worktreeRoot: root) == false)

        _ = await mgr.openDocument(
            worktreeRoot: root,
            fileURL: fileURL,
            languageId: "swift",
            text: "let unsaved = 2\n"
        )
        #expect(mgr.isDocumentOpen(fileURL: fileURL, worktreeRoot: root) == true)

        await mgr.closeDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift")
        #expect(mgr.isDocumentOpen(fileURL: fileURL, worktreeRoot: root) == false)
        #expect(mgr.documentStatus(forFile: fileURL, worktreeRoot: root) == .ready)

        await mgr.closeTemporaryDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift")
        #expect(mgr.documentStatus(forFile: fileURL, worktreeRoot: root) == .none)
        transport.finish()
    }

    private static let initializeReply = #"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"textDocumentSync":1}}}"#

    @Test func crashAfterReadyMarksStatusCrashed() async throws {
        let transport = FakeTransport()
        transport.onSend = { sent in
            if sent.contains(#""method":"initialize""#) { transport.deliverFrame(Self.initializeReply) }
        }
        let mgr = manager(makeClient: { _, _, _, language, rootURI, _ in
            LSPClient(transport: transport, language: language, rootURI: rootURI)
        })
        _ = await mgr.openDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift", text: "")
        let status = try #require(mgr.serverStatus(forFile: fileURL, worktreeRoot: root))
        #expect(status.phase == .ready)
        let tick = mgr.stateTick

        transport.deliverStderr("fatal: boom\n")
        transport.deliverExit(134)

        try await eventually("crashed phase") { if case .crashed = status.phase { true } else { false } }
        guard case .crashed(let detail) = status.phase else { return }
        #expect(detail.exitCode == 134)
        #expect(detail.outputTail == ["fatal: boom"])
        #expect(mgr.stateTick > tick)
        #expect(mgr.documentStatus(forFile: fileURL, worktreeRoot: root) == .dead)
    }

    @Test func streamEndWithoutExitStatusMarksStatusCrashed() async throws {
        let transport = FakeTransport()
        transport.onSend = { sent in
            if sent.contains(#""method":"initialize""#) { transport.deliverFrame(Self.initializeReply) }
        }
        let mgr = manager(makeClient: { _, _, _, language, rootURI, _ in
            LSPClient(transport: transport, language: language, rootURI: rootURI)
        })
        _ = await mgr.openDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift", text: "")
        let status = try #require(mgr.serverStatus(forFile: fileURL, worktreeRoot: root))
        #expect(status.phase == .ready)

        transport.finish()

        try await eventually("crashed phase") { if case .crashed = status.phase { true } else { false } }
        guard case .crashed(let detail) = status.phase else { return }
        #expect(detail.exitCode == nil)
        #expect(mgr.documentStatus(forFile: fileURL, worktreeRoot: root) == .dead)
    }

    @Test func exitDuringInitializeRecordsExitAndInitializeError() async throws {
        let transport = FakeTransport()
        transport.onSend = { sent in
            if sent.contains(#""method":"initialize""#) {
                transport.deliverStderr("dyld: missing libfoo\n")
                transport.deliverExit(2)
            }
        }
        let mgr = manager(makeClient: { _, _, _, language, rootURI, _ in
            LSPClient(transport: transport, language: language, rootURI: rootURI)
        })
        let client = await mgr.openDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift", text: "")
        #expect(client == nil)
        let status = try #require(mgr.serverStatus(forFile: fileURL, worktreeRoot: root))
        try await eventually("exit code and initialize error") {
            guard case .crashed(let detail) = status.phase else { return false }
            return detail.exitCode == 2 && detail.initializeError != nil
        }
        guard case .crashed(let detail) = status.phase else { return }
        #expect(detail.outputTail == ["dyld: missing libfoo"])
    }

    @Test func progressAfterReadyShowsIndexingWithoutTickingState() async throws {
        let transport = FakeTransport()
        transport.onSend = { sent in
            if sent.contains(#""method":"initialize""#) { transport.deliverFrame(Self.initializeReply) }
        }
        let mgr = manager(makeClient: { _, _, _, language, rootURI, _ in
            LSPClient(transport: transport, language: language, rootURI: rootURI, progressCoalescing: .zero)
        })
        _ = await mgr.openDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift", text: "")
        let status = try #require(mgr.serverStatus(forFile: fileURL, worktreeRoot: root))
        let tick = mgr.stateTick

        transport.deliverFrame(#"{"jsonrpc":"2.0","method":"$/progress","params":{"token":"idx","value":{"kind":"begin","title":"Indexing","percentage":10}}}"#)
        let indexing = LSPServerStatus.Phase.indexing([
            LSPClient.ProgressTask(token: "idx", title: "Indexing", message: nil, percentage: 10)
        ])
        try await eventually("indexing") { status.phase == indexing }
        transport.deliverFrame(#"{"jsonrpc":"2.0","method":"$/progress","params":{"token":"idx","value":{"kind":"end"}}}"#)
        try await eventually("ready") { status.phase == .ready }
        #expect(mgr.stateTick == tick)
        transport.finish()
    }

    @Test func leaseOutlivesDocumentsAndGraceShutdownIsCancelledByRetaining() async throws {
        let transport = Self.replyingTransport()
        let gate = GraceGate()
        let mgr = manager(
            makeClient: { _, _, _, language, rootURI, _ in
                LSPClient(transport: transport, language: language, rootURI: rootURI)
            },
            sleep: { await gate.sleep($0) }
        )
        _ = await mgr.openDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift", text: "")
        guard case .serving(let first) = await mgr.retainServer(worktreeRoot: root, fileURL: fileURL, languageId: "swift") else {
            Issue.record("expected a lease")
            return
        }
        #expect(first.status === mgr.serverStatus(forFile: fileURL, worktreeRoot: root))
        await mgr.closeDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift")
        #expect(transport.terminateCount == 0)

        first.release()
        try await eventually("first grace") { gate.requested == [WorkspaceLSPManager.idleGrace] }
        guard case .serving(let second) = await mgr.retainServer(worktreeRoot: root, fileURL: fileURL, languageId: "swift") else {
            Issue.record("expected a lease")
            return
        }
        #expect(second.status === first.status)
        gate.fire()
        second.release()
        try await eventually("second grace") { gate.requested.count == 2 }
        #expect(transport.terminateCount == 0)

        gate.fire()
        try await eventually("grace shutdown") { transport.terminateCount == 1 }
        transport.finish()
    }

    @Test func restartRespawnsLeaseOnlyServerWithSameStatus() async throws {
        final class Spawns { var transports: [FakeTransport] = [] }
        let spawns = Spawns()
        let mgr = manager(makeClient: { _, _, _, language, rootURI, _ in
            let transport = Self.replyingTransport()
            spawns.transports.append(transport)
            return LSPClient(transport: transport, language: language, rootURI: rootURI)
        })
        guard case .serving(let lease) = await mgr.retainServer(worktreeRoot: root, fileURL: fileURL, languageId: "swift") else {
            Issue.record("expected a lease")
            return
        }
        try await eventually("ready") { lease.status.phase == .ready }

        await mgr.restart(status: lease.status)

        #expect(spawns.transports.count == 2)
        #expect(spawns.transports[0].terminateCount == 1)
        try await eventually("ready after restart") { lease.status.phase == .ready }
        #expect(spawns.transports[1].terminateCount == 0)
        spawns.transports.forEach { $0.finish() }
    }

    @Test func retainReportsDisabledLanguageWithoutSpawning() async {
        let mgr = manager(enabled: false, makeClient: { _, _, _, language, rootURI, _ in
            Issue.record("a disabled language must not spawn a server")
            return readyClient(language: language, rootURI: rootURI)
        })
        let result = await mgr.retainServer(worktreeRoot: root, fileURL: fileURL, languageId: "swift")
        guard case .unavailable(let language, let reason) = result else {
            Issue.record("expected unavailable")
            return
        }
        #expect(language == "swift")
        #expect(reason == .disabled)
    }

    /// Builds a manager whose second spawn runs `spawns.onRespawn`: at that
    /// moment the previous holder is gone and the replacement is not inserted yet.
    private func respawnObservingManager(spawns: SpawnLog, gate: GraceGate) -> WorkspaceLSPManager {
        manager(
            makeClient: { _, _, _, language, rootURI, _ in
                let transport = Self.replyingTransport()
                spawns.transports.append(transport)
                if spawns.transports.count == 2 { spawns.onRespawn?() }
                return LSPClient(transport: transport, language: language, rootURI: rootURI)
            },
            sleep: { await gate.sleep($0) }
        )
    }

    @Test func leaseReleasedWhileRestartRespawnsDoesNotLeakTheServer() async throws {
        let spawns = SpawnLog()
        let gate = GraceGate()
        let mgr = respawnObservingManager(spawns: spawns, gate: gate)
        guard case .serving(let first) = await mgr.retainServer(worktreeRoot: root, fileURL: fileURL, languageId: "swift"),
              case .serving(let second) = await mgr.retainServer(worktreeRoot: root, fileURL: fileURL, languageId: "swift")
        else {
            Issue.record("expected two leases")
            return
        }
        try await eventually("ready") { second.status.phase == .ready }
        spawns.onRespawn = { first.release() }

        await mgr.restart(status: first.status)

        try #require(spawns.transports.count == 2)
        try await eventually("ready after restart") { second.status.phase == .ready }
        #expect(gate.requested.isEmpty)
        second.release()
        try await eventually("grace after last release") { gate.requested == [WorkspaceLSPManager.idleGrace] }
        gate.fire()
        try await eventually("grace shutdown") { spawns.transports[1].terminateCount == 1 }
        spawns.transports.forEach { $0.finish() }
    }

    @Test func lastLeaseReleasedWhileRestartRespawnsStillGetsGraceShutdown() async throws {
        let spawns = SpawnLog()
        let gate = GraceGate()
        let mgr = respawnObservingManager(spawns: spawns, gate: gate)
        guard case .serving(let lease) = await mgr.retainServer(worktreeRoot: root, fileURL: fileURL, languageId: "swift") else {
            Issue.record("expected a lease")
            return
        }
        try await eventually("ready") { lease.status.phase == .ready }
        spawns.onRespawn = { lease.release() }

        await mgr.restart(status: lease.status)

        try #require(spawns.transports.count == 2)
        try await eventually("grace for the replacement") { gate.requested == [WorkspaceLSPManager.idleGrace] }
        gate.fire()
        try await eventually("grace shutdown") { spawns.transports[1].terminateCount == 1 }
        spawns.transports.forEach { $0.finish() }
    }

    @Test func leaseReleasedWhileDeadServerIsDiscardedDoesNotKeepReplacementAlive() async throws {
        let spawns = SpawnLog()
        let gate = GraceGate()
        let mgr = respawnObservingManager(spawns: spawns, gate: gate)
        guard case .serving(let lease) = await mgr.retainServer(worktreeRoot: root, fileURL: fileURL, languageId: "swift") else {
            Issue.record("expected a lease")
            return
        }
        try await eventually("ready") { lease.status.phase == .ready }
        spawns.onRespawn = { lease.release() }
        spawns.transports[0].deliverExit(1)
        try await eventually("crashed") { if case .crashed = lease.status.phase { true } else { false } }

        _ = await mgr.openDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift", text: "")
        try #require(spawns.transports.count == 2)
        await mgr.closeDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift")

        #expect(spawns.transports[1].terminateCount == 1)
        #expect(gate.requested.isEmpty)
        spawns.transports.forEach { $0.finish() }
    }

    @Test func retainDuringFinalCloseShutdownGetsAFreshServer() async throws {
        let spawns = SpawnLog()
        let gate = GraceGate()
        let mgr = manager(
            makeClient: { _, _, _, language, rootURI, _ in
                // The first server never answers `shutdown`, so the close below suspends mid-teardown.
                let transport = Self.replyingTransport(repliesToShutdown: !spawns.transports.isEmpty)
                spawns.transports.append(transport)
                return LSPClient(transport: transport, language: language, rootURI: rootURI)
            },
            sleep: { await gate.sleep($0) }
        )
        _ = await mgr.openDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift", text: "")
        let stuck = spawns.transports[0]
        let closing = Task { await mgr.closeDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift") }
        try await eventually("shutdown requested") { stuck.sent.contains { $0.contains(#""method":"shutdown""#) } }

        guard case .serving(let lease) = await mgr.retainServer(worktreeRoot: root, fileURL: fileURL, languageId: "swift") else {
            Issue.record("expected a lease")
            return
        }
        try #require(spawns.transports.count == 2)
        try await eventually("fresh server ready") { lease.status.phase == .ready }

        let shutdownRequest = try #require(stuck.sent.first { $0.contains(#""method":"shutdown""#) })
        let shutdownID = try #require(Self.requestId(in: shutdownRequest))
        stuck.deliverFrame(#"{"jsonrpc":"2.0","id":\#(shutdownID),"result":null}"#)
        await closing.value
        #expect(stuck.terminateCount == 1)
        #expect(spawns.transports[1].terminateCount == 0)

        lease.release()
        try await eventually("grace for the fresh server") { gate.requested == [WorkspaceLSPManager.idleGrace] }
        gate.fire()
        try await eventually("fresh server stopped") { spawns.transports[1].terminateCount == 1 }
        spawns.transports.forEach { $0.finish() }
    }

    @Test func leaseSetDerivesInputsWithoutTouchingDiskAndRetainsOnlyRegularFiles() async throws {
        let present = "present.swift"
        try Data().write(to: root.appendingPathComponent(present))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir.swift"), withIntermediateDirectories: true)
        let spawns = SpawnLog()
        let mgr = manager(makeClient: { _, _, _, language, rootURI, _ in
            let transport = Self.replyingTransport()
            spawns.transports.append(transport)
            return LSPClient(transport: transport, language: language, rootURI: rootURI)
        })
        let inputs = LSPServerLeaseSet.inputs(
            worktreeRoot: root,
            relativePaths: ["missing.swift", "dir.swift", present, "notes.txt"],
            registry: mgr.activeRegistry
        )
        #expect(inputs.map(\.relativePath) == ["missing.swift", "dir.swift", present])

        let leaseSet = LSPServerLeaseSet()
        await leaseSet.update(inputs: Array(inputs.prefix(2)), manager: mgr)
        #expect(leaseSet.chips.isEmpty)
        #expect(spawns.transports.isEmpty)

        await leaseSet.update(inputs: inputs, manager: mgr)
        #expect(leaseSet.chips.count == 1)
        #expect(spawns.transports.count == 1)
        leaseSet.release()
        spawns.transports.forEach { $0.finish() }
    }

    @Test func leaseResolvesNestedPackageRootFromRootMarkers() async throws {
        let package = root.appendingPathComponent("Packages/Core", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try Data().write(to: package.appendingPathComponent("Package.swift"))
        let nestedFile = package.appendingPathComponent("Sources/Core.swift")
        let spawns = SpawnLog()
        let mgr = manager(rootMarkers: ["Package.swift"], makeClient: { _, _, _, language, rootURI, _ in
            let transport = Self.replyingTransport()
            spawns.transports.append(transport)
            return LSPClient(transport: transport, language: language, rootURI: rootURI)
        })

        guard case .serving(let lease) = await mgr.retainServer(worktreeRoot: root, fileURL: nestedFile, languageId: "swift") else {
            Issue.record("expected a lease")
            return
        }

        #expect(lease.status.root == package.standardizedFileURL.path)
        spawns.transports.forEach { $0.finish() }
    }

    @Test func restartRespawnsLeaseOnlyServerThroughAnEnabledAlias() async throws {
        func registry(typescriptEnabled: Bool) -> LanguageServerRegistry {
            LanguageServerRegistry(userDefined: [
                LanguageServerConfig(language: "typescript", extensions: ["ts"], command: "/usr/bin/true", args: [], env: [:], rootMarkers: [], enabled: typescriptEnabled),
                LanguageServerConfig(language: "javascript", extensions: ["js"], command: "/usr/bin/true", args: [], env: [:], rootMarkers: [], enabled: true),
            ])
        }
        let spawns = SpawnLog()
        let mgr = manager(registry: registry(typescriptEnabled: true), makeClient: { _, _, _, language, rootURI, _ in
            let transport = Self.replyingTransport()
            spawns.transports.append(transport)
            return LSPClient(transport: transport, language: language, rootURI: rootURI)
        })
        // Both aliases resolve to one server: same root, command, args and env.
        guard case .serving(let typescriptLease) = await mgr.retainServer(worktreeRoot: root, fileURL: root.appendingPathComponent("a.ts"), languageId: "typescript"),
              case .serving(let javascriptLease) = await mgr.retainServer(worktreeRoot: root, fileURL: root.appendingPathComponent("a.js"), languageId: "javascript")
        else {
            Issue.record("expected two leases")
            return
        }
        #expect(typescriptLease.status === javascriptLease.status)
        try await eventually("ready") { typescriptLease.status.phase == .ready }

        mgr.updateRegistry(registry(typescriptEnabled: false))
        await mgr.restart(status: typescriptLease.status)

        #expect(spawns.transports.count == 2)
        try await eventually("ready after restart") { javascriptLease.status.phase == .ready }
        #expect(spawns.transports[0].terminateCount == 1)
        spawns.transports.forEach { $0.finish() }
    }
}

@MainActor
private final class SpawnLog {
    var transports: [FakeTransport] = []
    var onRespawn: (@MainActor () -> Void)?
}

/// Stands in for `Task.sleep` in the idle-grace timer: records requested
/// durations and suspends until `fire()`.
@MainActor
private final class GraceGate {
    private(set) var requested: [Duration] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: Duration) async {
        requested.append(duration)
        await withCheckedContinuation { waiters.append($0) }
    }

    func fire() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// Captures the `realPath` carried by `.lspBlockedByGatekeeper`. The
/// notification observer block is `@Sendable` and may run off the test's own
/// task, so the recorded value is lock-backed rather than a bare `var`.
/// Invariant: `storedRealPath` is only ever read or written while `lock` is held.
private final class BlockedNotificationBox: @unchecked Sendable {
    let path = "/usr/bin/true"
    private let lock = NSLock()
    private var storedRealPath: String?

    var notificationRealPath: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedRealPath
        }
        set {
            lock.lock()
            storedRealPath = newValue
            lock.unlock()
        }
    }
}

/// Parks remediation attempts until two of them have arrived, then unblocks the
/// gatekeeper and resumes both. The availability hooks that drive it run
/// outside the test's actor, hence the lock.
/// Invariant: `storedBlocked` and `continuations` are only touched while `lock`
/// is held, and continuations are always resumed after the lock is released.
private final class PairedRemediationBox: @unchecked Sendable {
    let path = "/usr/bin/true"
    private let lock = NSLock()
    private var storedBlocked = true
    private var continuations: [CheckedContinuation<GatekeeperRemediator.Outcome, Never>] = []

    var blocked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedBlocked
    }

    func waitForBothRemediationAttempts() async -> GatekeeperRemediator.Outcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            continuations.append(continuation)
            guard continuations.count == 2 else {
                lock.unlock()
                return
            }
            storedBlocked = false
            let parked = continuations
            continuations.removeAll()
            lock.unlock()
            for parkedContinuation in parked {
                parkedContinuation.resume(returning: .allowed)
            }
        }
    }
}

/// Parks a single remediation attempt so the test can interleave a close (or a
/// registry swap) before letting it finish. Driven from the availability hooks,
/// which run outside the test's actor, hence the lock.
/// Invariant: `storedBlocked`, `remediation` and `parked` are only touched while
/// `lock` is held, and continuations are always resumed after the lock is released.
private final class ParkedRemediationBox: @unchecked Sendable {
    let path = "/usr/bin/true"
    private let lock = NSLock()
    private var storedBlocked = true
    private var remediation: CheckedContinuation<GatekeeperRemediator.Outcome, Never>?
    private var parked: CheckedContinuation<Void, Never>?

    var blocked: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedBlocked
        }
        set {
            lock.lock()
            storedBlocked = newValue
            lock.unlock()
        }
    }

    func remediate() async -> GatekeeperRemediator.Outcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            remediation = continuation
            let waiter = parked
            parked = nil
            lock.unlock()
            waiter?.resume()
        }
    }

    func waitUntilRemediationIsParked() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if remediation != nil {
                lock.unlock()
                continuation.resume()
                return
            }
            parked = continuation
            lock.unlock()
        }
    }

    func finishRemediation(_ outcome: GatekeeperRemediator.Outcome) {
        lock.lock()
        let continuation = remediation
        remediation = nil
        lock.unlock()
        continuation?.resume(returning: outcome)
    }
}
