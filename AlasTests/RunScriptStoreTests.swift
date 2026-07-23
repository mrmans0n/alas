import Foundation
import Testing
@testable import Alas

struct RunScriptStoreTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-script-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ contents: String, to dir: URL, name: String, executable: Bool = false) throws {
        let url = dir.appendingPathComponent(name)
        try contents.data(using: .utf8)!.write(to: url)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    @Test func discoversBothScopesSortedByDisplayName() throws {
        let worktree = try makeTempDir()
        let globalDir = try makeTempDir()
        let repoScripts = worktree.appendingPathComponent(".alas/scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: repoScripts, withIntermediateDirectories: true)
        try write("# alas-name: Zeta\n", to: repoScripts, name: "z.sh", executable: true)
        try write("# alas-name: Alpha\n", to: repoScripts, name: "a.sh")
        try write("echo hi\n", to: globalDir, name: "deploy.sh")

        let scripts = RunScriptStore.scripts(worktreeRoot: worktree, globalDir: globalDir)
        #expect(scripts.map(\.displayName) == ["Alpha", "Zeta", "deploy"])
        #expect(scripts.map(\.scope) == [.repo, .repo, .global])
        #expect(scripts[1].isExecutable)
        #expect(!scripts[0].isExecutable)
    }

    @Test func missingDirectoriesYieldEmpty() throws {
        let worktree = try makeTempDir()
        let scripts = RunScriptStore.scripts(
            worktreeRoot: worktree,
            globalDir: worktree.appendingPathComponent("nope", isDirectory: true)
        )
        #expect(scripts.isEmpty)
    }

    @Test func skipsHiddenFilesAndSubdirectories() throws {
        let worktree = try makeTempDir()
        let repoScripts = worktree.appendingPathComponent(".alas/scripts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repoScripts.appendingPathComponent("subdir", isDirectory: true),
            withIntermediateDirectories: true
        )
        try write("x", to: repoScripts, name: ".hidden.sh")
        try write("x", to: repoScripts, name: "visible.sh")

        let scripts = RunScriptStore.scripts(
            worktreeRoot: worktree,
            globalDir: worktree.appendingPathComponent("nope", isDirectory: true)
        )
        #expect(scripts.map(\.fileName) == ["visible.sh"])
    }
}
