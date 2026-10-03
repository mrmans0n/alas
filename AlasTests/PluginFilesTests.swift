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

    /// A remote worktree's files go to the helper only for a plugin that declares `remote`; others keep API 10's refusal.
    @Test(arguments: [
        (.local(URL(fileURLWithPath: "/wt")), false, PluginFileRoute.local(URL(fileURLWithPath: "/wt"))),
        (.remote(host: "devbox", root: "/srv/wt"), true, .remote(host: "devbox", root: "/srv/wt")),
        (.remote(host: "devbox", root: "/srv/wt"), false, .refused("worktree w is on remote host devbox; plugins can't run commands or use files there yet")),
        (nil, true, .refused("unknown worktree w")),
    ] as [(PluginWorktreeLocation?, Bool, PluginFileRoute)])
    func fileRequestsRouteByWhereTheWorktreeIs(location: PluginWorktreeLocation?, remote: Bool, expected: PluginFileRoute) {
        #expect(PluginFiles.route(location, worktree: "w", remote: remote) == expected)
    }

    /// Remote failures answer with a reason and never stop the plugin; the helper's own refusals pass through.
    @Test(arguments: [
        (PluginRemoteFileProblem.helperMissing, "the Alas helper is not installed on remote host devbox; plugins need it to use files there"),
        (PluginRemoteFileProblem.unreachable, "remote host devbox is unreachable"),
        (RemoteHelperClientError.notRunning, "remote host devbox is unreachable"),
        (RemoteHelperClientError.unavailable("ssh exited"), "remote host devbox is unreachable"),
        (RemoteHelperClientError.jsonrpc(JSONRPCError(code: -32601, message: "method not found", data: nil)),
         "the Alas helper on remote host devbox is out of date; plugins need a newer one to use files there"),
        (RemoteHelperClientError.jsonrpc(JSONRPCError(code: -32027, message: ".GIT/config is inside .git", data: nil)), ".GIT/config is inside .git"),
    ] as [(any Error, String)])
    func remoteFailuresSayWhy(error: any Error, message: String) {
        #expect(PluginFiles.remoteFailure(error, host: "devbox") == .refused(message))
    }

    /// A folder lists sorted without `.git`; past the read bound it stops reading and says so.
    @Test(arguments: [(10, ["a", "b", "c"], false), (3, ["a", "b", "c"], false), (2, nil, true)] as [(Int, [String]?, Bool)])
    func listStopsReadingAtItsBound(readLimit: Int, names: [String]?, truncated: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "plugin-list-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
        for name in ["c", "a", "b"] { try Data().write(to: root.appending(path: name)) }

        let result = try PluginFiles.list("", in: root, readLimit: readLimit).get()
        #expect(result.truncated == truncated)
        if let names { #expect(result.entries.map(\.name) == names) } else { #expect(result.entries.count == readLimit) }
    }
}
