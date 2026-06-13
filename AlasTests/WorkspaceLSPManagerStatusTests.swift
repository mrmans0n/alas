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
        makeClient: @escaping (_ executable: URL, _ arguments: [String], _ environment: [String: String], _ language: String, _ rootURI: String) -> LSPClient = { executable, arguments, environment, language, rootURI in
            LSPClient(
                transport: LSPTransport(executable: executable, arguments: arguments, environment: environment),
                language: language,
                rootURI: rootURI
            )
        }
    ) -> WorkspaceLSPManager {
        let registry = LanguageServerRegistry(userDefined: [
            LanguageServerConfig(
                language: language,
                extensions: ["swift"],
                command: "/usr/bin/true",
                args: [],
                env: [:],
                rootMarkers: [],
                enabled: true
            )
        ])
        return WorkspaceLSPManager(
            registry: registry,
            makeAvailability: {
                LanguageServerAvailability(
                    environment: [:],
                    xcrunFind: { _ in nil },
                    additionalPathDirectories: [],
                    gatekeeperAssessor: { _ in .allowed }
                )
            },
            makeClient: makeClient
        )
    }

    @Test func documentStatusIsNoneBeforeOpen() {
        let mgr = manager()
        #expect(mgr.documentStatus(forFile: fileURL, worktreeRoot: root) == .none)
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
            }
        )

        _ = await mgr.openDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift", text: "")

        #expect(box.remediated == [box.path])
        #expect(mgr.documentStatus(forFile: fileURL, worktreeRoot: root) != .none)
    }

    @Test func openDocumentPostsBlockedNotificationWhenRemediationFails() async {
        final class Box {
            let path = "/usr/bin/true"
            var notificationRealPath: String?
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
        final class Box {
            let path = "/usr/bin/true"
            var blocked = true
            var continuations: [CheckedContinuation<GatekeeperRemediator.Outcome, Never>] = []

            func waitForBothRemediationAttempts() async -> GatekeeperRemediator.Outcome {
                await withCheckedContinuation { continuation in
                    continuations.append(continuation)
                    guard continuations.count == 2 else { return }
                    blocked = false
                    let parked = continuations
                    continuations.removeAll()
                    for continuation in parked {
                        continuation.resume(returning: .allowed)
                    }
                }
            }
        }
        let box = Box()
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
            }
        )

        async let first: LSPClient? = mgr.openDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift", text: "")
        async let second: LSPClient? = mgr.openDocument(worktreeRoot: root, fileURL: otherFileURL, languageId: "swift", text: "")
        _ = await (first, second)

        #expect(mgr.documentStatus(forFile: fileURL, worktreeRoot: root) != .none)
        #expect(mgr.documentStatus(forFile: otherFileURL, worktreeRoot: root) != .none)
    }

    @Test func closeDuringRemediationCancelsPendingOpen() async {
        final class Box {
            let path = "/usr/bin/true"
            var blocked = true
            var remediation: CheckedContinuation<GatekeeperRemediator.Outcome, Never>?
            var parked: CheckedContinuation<Void, Never>?

            func remediate() async -> GatekeeperRemediator.Outcome {
                await withCheckedContinuation { continuation in
                    remediation = continuation
                    parked?.resume()
                    parked = nil
                }
            }

            func waitUntilRemediationIsParked() async {
                if remediation != nil { return }
                await withCheckedContinuation { continuation in
                    parked = continuation
                }
            }
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
                    gatekeeperRemediator: { _, _ in await box.remediate() }
                )
            }
        )

        async let opened: LSPClient? = mgr.openDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift", text: "")
        await box.waitUntilRemediationIsParked()
        await mgr.closeDocument(worktreeRoot: root, fileURL: fileURL, languageId: "swift")
        box.blocked = false
        box.remediation?.resume(returning: .allowed)
        box.remediation = nil
        _ = await opened

        #expect(mgr.documentStatus(forFile: fileURL, worktreeRoot: root) == .none)
    }

    @Test func closeDuringRemediationCancelsPendingOpenAfterRegistryChange() async {
        final class Box {
            let path = "/usr/bin/true"
            var blocked = true
            var remediation: CheckedContinuation<GatekeeperRemediator.Outcome, Never>?
            var parked: CheckedContinuation<Void, Never>?

            func remediate() async -> GatekeeperRemediator.Outcome {
                await withCheckedContinuation { continuation in
                    remediation = continuation
                    parked?.resume()
                    parked = nil
                }
            }

            func waitUntilRemediationIsParked() async {
                if remediation != nil { return }
                await withCheckedContinuation { continuation in
                    parked = continuation
                }
            }
        }
        let box = Box()
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
        box.remediation?.resume(returning: .allowed)
        box.remediation = nil
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
            makeClient: { _, _, _, language, rootURI in
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
            makeClient: { _, _, _, language, rootURI in
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

    @Test func isDocumentOpenRequiresEditorOwnedRefWhenTemporaryRetainExists() async {
        let transport = FakeTransport()
        transport.onSend = { sent in
            if sent.contains(#""method":"initialize""#) {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"textDocumentSync":1}}}"#)
            }
        }
        let mgr = manager(
            withFakeEntry: "swift",
            makeClient: { _, _, _, language, rootURI in
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
}
