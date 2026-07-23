import Foundation
import Testing
@testable import Alas

struct RunScriptLaunchTests {
    private func script(
        executable: Bool,
        onExit: RunScriptOnExit = .keep,
        cwd: String? = nil
    ) -> RunScript {
        RunScript(
            scope: .repo, fileName: "dev server.sh",
            fileURL: URL(fileURLWithPath: "/wt/.alas/scripts/dev server.sh"),
            displayName: "Dev Server", onExit: onExit, cwd: cwd, isExecutable: executable
        )
    }

    // `AppState.shellQuote` only wraps a value in single quotes when it
    // contains characters outside `[A-Za-z0-9_/.@%+=,:-]`; plain paths like
    // "/wt" or "/repo" and bare words like "main"/"alas" are emitted
    // unquoted. Only the script filename (which has a space) gets quoted.
    @Test func executableScriptRunsDirectlyWithEnvAndCd() throws {
        let suffix = try AppState.runScriptStartupScript(
            script: script(executable: true),
            worktreeRoot: URL(fileURLWithPath: "/wt"),
            branch: "main", projectName: "alas", repoRoot: "/repo"
        )
        #expect(suffix.hasPrefix("cd /wt\n"))
        #expect(suffix.contains("'/wt/.alas/scripts/dev server.sh'"))
        #expect(suffix.contains("ALAS_WORKTREE_ROOT=/wt"))
        #expect(suffix.contains("ALAS_REPO_ROOT=/repo"))
        #expect(suffix.contains("ALAS_BRANCH=main"))
        #expect(suffix.contains("ALAS_PROJECT_NAME=alas"))
        #expect(!suffix.contains("exit \"$status\""))
    }

    @Test func nonExecutableScriptRunsViaSh() throws {
        let suffix = try AppState.runScriptStartupScript(
            script: script(executable: false),
            worktreeRoot: URL(fileURLWithPath: "/wt"),
            branch: "main", projectName: "alas", repoRoot: "/repo"
        )
        #expect(suffix.contains("/bin/sh '/wt/.alas/scripts/dev server.sh'"))
    }

    @Test func closeOnExitAppendsExit() throws {
        let suffix = try AppState.runScriptStartupScript(
            script: script(executable: true, onExit: .close),
            worktreeRoot: URL(fileURLWithPath: "/wt"),
            branch: "main", projectName: "alas", repoRoot: "/repo"
        )
        #expect(suffix.hasSuffix("status=$?\nexit \"$status\""))
    }

    @Test func cwdJoinsWorktreeRoot() throws {
        let suffix = try AppState.runScriptStartupScript(
            script: script(executable: true, cwd: "apps/web"),
            worktreeRoot: URL(fileURLWithPath: "/wt"),
            branch: "main", projectName: "alas", repoRoot: "/repo"
        )
        #expect(suffix.hasPrefix("cd /wt/apps/web\n"))
    }
}
