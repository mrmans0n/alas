import Testing
import Foundation
@testable import Alas

struct EnvBuilderTests {
    @Test func injectsAlasVars() {
        let project = ProjectConfig(id: "p", name: "owner/repo", path: "/tmp/repo",
                                    color: "#000", addedAt: Date())
        let wt = Worktree(id: "w", projectId: "p", name: "main", branch: "main",
                          path: URL(fileURLWithPath: "/tmp/wt"),
                          status: .clean, lastActivity: Date())
        let env = EnvBuilder.build(project: project, worktree: wt, sessionId: "s-1",
                                   hookDir: URL(fileURLWithPath: "/tmp/hooks"),
                                   inheritParent: false, parent: ["PATH": "/x"])
        #expect(env["ALAS_REPO"] == "owner/repo")
        #expect(env["ALAS_BRANCH"] == "main")
        #expect(env["ALAS_WORKTREE"] == "/tmp/wt")
        #expect(env["ALAS_SESSION_ID"] == "s-1")
        #expect(env["ALAS_HOOK_DIR"] == "/tmp/hooks")
        #expect(env["PATH"] == nil)
    }

    @Test func mergesParentWhenInherit() {
        let project = ProjectConfig(id: "p", name: "x/y", path: "/r", color: "#0", addedAt: Date())
        let wt = Worktree(id: "w", projectId: "p", name: "m", branch: "m",
                          path: URL(fileURLWithPath: "/wt"),
                          status: .clean, lastActivity: Date())
        let env = EnvBuilder.build(project: project, worktree: wt, sessionId: "s",
                                   hookDir: URL(fileURLWithPath: "/h"),
                                   inheritParent: true, parent: ["PATH": "/x", "HOME": "/h"])
        #expect(env["PATH"] == "/x")
        #expect(env["HOME"] == "/h")
        #expect(env["ALAS_REPO"] == "x/y")
    }

    @Test func stripsTerminalVarsFromInheritedParent() {
        let project = ProjectConfig(id: "p", name: "x/y", path: "/r", color: "#0", addedAt: Date())
        let wt = Worktree(id: "w", projectId: "p", name: "m", branch: "m",
                          path: URL(fileURLWithPath: "/wt"),
                          status: .clean, lastActivity: Date())
        let env = EnvBuilder.build(
            project: project, worktree: wt, sessionId: "s",
            hookDir: URL(fileURLWithPath: "/h"),
            inheritParent: true,
            parent: [
                "PATH": "/x",
                "TERM": "dumb",
                "TERM_PROGRAM": "MyIDE",
                "COLORTERM": "truecolor",
                "TERMINFO": "/some/path",
            ]
        )
        #expect(env["PATH"] == "/x")
        #expect(env["TERM"] == nil)
        #expect(env["TERM_PROGRAM"] == nil)
        #expect(env["COLORTERM"] == nil)
        #expect(env["TERMINFO"] == nil)
    }
}
