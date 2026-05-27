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

    private func manager(withFakeEntry language: String = "swift") -> WorkspaceLSPManager {
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
            }
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
}
