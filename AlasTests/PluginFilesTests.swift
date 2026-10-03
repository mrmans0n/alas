import Foundation
import Testing
@testable import Alas

struct PluginFilesTests {
    /// Paths stay relative and inside the worktree, through symlinks too, and never reach anything named `.git`.
    @Test(arguments: [
        ("a/b.txt", "wt/a/b.txt"),
        ("new/dir/c.txt", "wt/new/dir/c.txt"),
        ("inner/c.txt", "wt/a/c.txt"),
        ("", "wt"),
        ("/etc/passwd", nil),
        ("../x", nil),
        ("a/../../x", nil),
        ("out", nil),
        ("out/x", nil),
        ("dangling", nil),
        (".git", nil),
        (".GIT/config", nil),
        ("a/.git/b", nil),
        ("gitlink/config", nil),
    ] as [(String, String?)])
    func resolveKeepsPathsInsideTheWorktree(path: String, resolvesTo: String?) throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "plugin-resolve-\(UUID().uuidString)")
        let root = base.appending(path: "wt")
        defer { try? FileManager.default.removeItem(at: base) }
        let files = FileManager.default
        try files.createDirectory(at: root.appending(path: "a/.git"), withIntermediateDirectories: true)
        try files.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
        try files.createDirectory(at: base.appending(path: "outside"), withIntermediateDirectories: true)
        try files.createSymbolicLink(atPath: root.appending(path: "out").path, withDestinationPath: base.appending(path: "outside").path)
        try files.createSymbolicLink(atPath: root.appending(path: "gitlink").path, withDestinationPath: ".git")
        try files.createSymbolicLink(atPath: root.appending(path: "inner").path, withDestinationPath: "a")
        try files.createSymbolicLink(atPath: root.appending(path: "dangling").path, withDestinationPath: base.appending(path: "nowhere").path)

        let resolved = try? PluginFiles.resolve(path, in: root).get()
        #expect(resolved.map { $0.path.hasSuffix("/" + (resolvesTo ?? "\0")) } ?? (resolvesTo == nil))
    }
}
