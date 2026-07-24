import Foundation
import Testing
@testable import Alas

struct RunScriptCreationTests {
    @Test func presentationDescribesRepoAndGlobalScopes() {
        let repo = RunScriptCreationPresentation(
            scope: .repo,
            projectId: "project",
            worktreeId: "worktree",
            repositoryName: "Alas"
        )
        let global = RunScriptCreationPresentation(
            scope: .global,
            projectId: "project",
            worktreeId: "worktree",
            repositoryName: "Alas"
        )

        #expect(repo.subtitle == "Create a script in .alas/scripts/ for Alas.")
        #expect(global.subtitle == "Create a script available in every local worktree.")
    }

    @Test func normalizedNameTrimsAndRejectsWhitespace() {
        #expect(RunScriptCreator.normalizedName("  Dev Server \n") == "Dev Server")
        #expect(RunScriptCreator.normalizedName(" \n\t") == nil)
    }

    @Test func createWritesSelectedMetadataAndExecutablePermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try RunScriptCreator.create(
            scope: .repo,
            name: " Dev Server ",
            onExit: .close,
            worktreeRoot: root,
            globalDir: root.appendingPathComponent("global")
        )

        #expect(url == root.appendingPathComponent(".alas/scripts/dev-server.sh"))
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("# alas-name: Dev Server"))
        #expect(contents.contains("# alas-on-exit: close"))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    }

    @Test func createUsesInjectedGlobalDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let global = root.appendingPathComponent("global", isDirectory: true)

        let url = try RunScriptCreator.create(
            scope: .global,
            name: "Build",
            onExit: .keep,
            worktreeRoot: root.appendingPathComponent("worktree"),
            globalDir: global
        )

        #expect(url == global.appendingPathComponent("build.sh"))
    }

    @Test func duplicateReturnsFileExistsWithoutOverwriting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try RunScriptCreator.create(
            scope: .repo,
            name: "Build",
            onExit: .keep,
            worktreeRoot: root,
            globalDir: root.appendingPathComponent("global")
        )

        #expect(throws: RunScriptCreationError.fileExists("build.sh")) {
            try RunScriptCreator.create(
                scope: .repo,
                name: "Build",
                onExit: .close,
                worktreeRoot: root,
                globalDir: root.appendingPathComponent("global")
            )
        }
        let contents = try String(
            contentsOf: root.appendingPathComponent(".alas/scripts/build.sh"),
            encoding: .utf8
        )
        #expect(contents.contains("# alas-on-exit: keep"))
    }
}
