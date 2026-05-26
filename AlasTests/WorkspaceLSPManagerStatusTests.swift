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
        return WorkspaceLSPManager(registry: registry)
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
}
