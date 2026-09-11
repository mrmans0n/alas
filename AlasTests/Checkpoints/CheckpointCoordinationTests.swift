import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("Checkpoint coordination")
struct CheckpointCoordinationTests {
    @Test func unsavedRelativePathsIncludeLiveDirtyBuffersAndHotExitSnapshots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-coordination-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "saved".write(to: root.appendingPathComponent("live.swift"), atomically: true, encoding: .utf8)

        let buffers = EditorBufferStore(rootOverride: root.appendingPathComponent("buffers"))
        let manager = TabsManager(bufferStore: buffers)
        let live = manager.openEditor(worktreeId: "worktree", relativePath: "live.swift", revealLine: nil, revealCharacter: nil)
        let buffer = manager.buffer(worktreeId: "worktree", tabId: live.id, worktreeRoot: root, relativePath: "live.swift")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "dirty ")

        let restored = manager.openEditor(worktreeId: "worktree", relativePath: "restored.swift", revealLine: nil, revealCharacter: nil)
        try buffers.write(.init(relativePath: "restored.swift", content: "draft", originalText: "", originalMtime: .now, lineEnding: .lf), worktreeId: "worktree", tabId: restored.id)

        #expect(manager.unsavedRelativePaths(forWorktree: "worktree") == ["live.swift", "restored.swift"])
    }
}
