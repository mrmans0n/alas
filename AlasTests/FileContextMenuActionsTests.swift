import Foundation
import Testing
@testable import Alas

struct FileContextMenuActionsTests {
    @Test func resolvesExistingLocalFileButRejectsMissingFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-context-menu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("README.md")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let existing = FileContextMenuTarget.resolve(kind: .file, worktreePath: root, relativePath: "README.md")
        let missing = FileContextMenuTarget.resolve(kind: .file, worktreePath: root, relativePath: "missing.md")

        #expect(existing.localURL == file)
        #expect(missing.localURL == nil)
    }

    @Test func remoteTargetOmitsLocalURL() {
        let root = URL(fileURLWithPath: "/srv/remote-\(UUID().uuidString)")
        RemoteHostRegistry.shared.register(root: root.path, host: "devbox")
        defer { RemoteHostRegistry.shared.unregister(root: root.path) }
        let target = FileContextMenuTarget.resolve(
            kind: .file,
            worktreePath: root,
            relativePath: "Sources/App.swift",
            fileExists: { _ in true }
        )
        #expect(target.localURL == nil)
    }

    @Test func workingTreeFileOrdersFinderAndRevisionActions() {
        let target = FileContextMenuTarget(kind: .file, localURL: URL(fileURLWithPath: "/repo/App.swift"))
        #expect(FileContextMenuConfiguration.workingTreeFile(target: target).actions == [
            .openInAlas, .open, .openWith, .viewAtHEAD, .compareWithHEAD,
            .fileHistory, .copyRelativePath, .copyFullPath, .revealInFinder
        ])
    }

    @Test func workingTreeMissingTargetKeepsNonSystemActions() {
        let target = FileContextMenuTarget(kind: .file, localURL: nil)
        #expect(FileContextMenuConfiguration.workingTreeFile(target: target).actions == [
            .openInAlas, .viewAtHEAD, .compareWithHEAD,
            .fileHistory, .copyRelativePath, .copyFullPath
        ])
    }
}
