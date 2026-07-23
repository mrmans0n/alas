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
                                   socketPath: "/tmp/alas.sock",
                                   inheritParent: false, parent: ["PATH": "/x"])
        #expect(env["ALAS_REPO"] == "owner/repo")
        #expect(env["ALAS_BRANCH"] == "main")
        #expect(env["ALAS_WORKTREE"] == "/tmp/wt")
        #expect(env["ALAS_SESSION_ID"] == "s-1")
        #expect(env["ALAS_SOCKET_PATH"] == "/tmp/alas.sock")
        #expect(env["PATH"] == nil)
    }

    @Test func mergesParentWhenInherit() {
        let project = ProjectConfig(id: "p", name: "x/y", path: "/r", color: "#0", addedAt: Date())
        let wt = Worktree(id: "w", projectId: "p", name: "m", branch: "m",
                          path: URL(fileURLWithPath: "/wt"),
                          status: .clean, lastActivity: Date())
        let env = EnvBuilder.build(project: project, worktree: wt, sessionId: "s",
                                   socketPath: nil,
                                   inheritParent: true, parent: ["PATH": "/x", "HOME": "/h"])
        #expect(env["PATH"] == "/x")
        #expect(env["HOME"] == "/h")
        #expect(env["ALAS_REPO"] == "x/y")
    }

    /// Codex review (#102): inherited ALAS_SOCKET_PATH must be stripped when
    /// we have no socket of our own, otherwise hooks installed in this new
    /// session would dispatch events to a stale/parent Alas instance and
    /// drive false state there.
    @Test func stripsInheritedSocketPathWhenNoServerAvailable() {
        let project = ProjectConfig(id: "p", name: "x/y", path: "/r", color: "#0", addedAt: Date())
        let wt = Worktree(id: "w", projectId: "p", name: "m", branch: "m",
                          path: URL(fileURLWithPath: "/wt"),
                          status: .clean, lastActivity: Date())
        let env = EnvBuilder.build(
            project: project, worktree: wt, sessionId: "s",
            socketPath: nil,
            inheritParent: true,
            parent: ["ALAS_SOCKET_PATH": "/tmp/some-other-alas.sock"]
        )
        #expect(env["ALAS_SOCKET_PATH"] == nil)
    }

    @Test func ownSocketPathOverridesInheritedOne() {
        let project = ProjectConfig(id: "p", name: "x/y", path: "/r", color: "#0", addedAt: Date())
        let wt = Worktree(id: "w", projectId: "p", name: "m", branch: "m",
                          path: URL(fileURLWithPath: "/wt"),
                          status: .clean, lastActivity: Date())
        let env = EnvBuilder.build(
            project: project, worktree: wt, sessionId: "s",
            socketPath: "/tmp/ours.sock",
            inheritParent: true,
            parent: ["ALAS_SOCKET_PATH": "/tmp/some-other-alas.sock"]
        )
        #expect(env["ALAS_SOCKET_PATH"] == "/tmp/ours.sock")
    }

    @Test func stripsTerminalVarsFromInheritedParent() {
        let project = ProjectConfig(id: "p", name: "x/y", path: "/r", color: "#0", addedAt: Date())
        let wt = Worktree(id: "w", projectId: "p", name: "m", branch: "m",
                          path: URL(fileURLWithPath: "/wt"),
                          status: .clean, lastActivity: Date())
        let env = EnvBuilder.build(
            project: project, worktree: wt, sessionId: "s",
            socketPath: nil,
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

    /// Ghostty starts with the Alas process environment and overlays the
    /// dictionary returned by EnvBuilder. Omitting ZMX_SESSION therefore does
    /// not remove a value inherited when Alas was launched from a zmx terminal;
    /// an explicit empty override is required to make zmx perform a normal
    /// multi-client attach. ZMX_SESSION_PREFIX remains inherited user config.
    @Test func shadowsZmxSessionButKeepsPrefixFromInheritedParent() {
        let project = ProjectConfig(id: "p", name: "x/y", path: "/r", color: "#0", addedAt: Date())
        let wt = Worktree(id: "w", projectId: "p", name: "m", branch: "m",
                          path: URL(fileURLWithPath: "/wt"),
                          status: .clean, lastActivity: Date())
        let env = EnvBuilder.build(
            project: project, worktree: wt, sessionId: "s",
            socketPath: nil,
            inheritParent: true,
            parent: [
                "PATH": "/x",
                "ZMX_SESSION": "alas-foo",
                "ZMX_SESSION_PREFIX": "team-",
            ]
        )
        #expect(env["PATH"] == "/x")
        #expect(env["ZMX_SESSION"] == "")
        #expect(env["ZMX_SESSION_PREFIX"] == "team-")
    }

    @Test func remoteSessionDoesNotAddZmxSessionOverride() {
        let project = ProjectConfig(
            id: "p", name: "x/y", path: "/r", color: "#0", addedAt: Date(), host: "devbox"
        )
        let wt = Worktree(id: "w", projectId: "p", name: "m", branch: "m",
                          path: URL(fileURLWithPath: "/wt"),
                          status: .clean, lastActivity: Date())
        let env = EnvBuilder.build(
            project: project, worktree: wt, sessionId: "s",
            socketPath: nil,
            inheritParent: true,
            parent: ["ZMX_SESSION": "alas-parent"]
        )
        #expect(env["ZMX_SESSION"] == nil)
    }

    @Test func zmxDirIsEmittedWhenProvided() {
        let project = ProjectConfig(id: "p", name: "x/y", path: "/r", color: "#0", addedAt: Date())
        let wt = Worktree(id: "w", projectId: "p", name: "m", branch: "m",
                          path: URL(fileURLWithPath: "/wt"),
                          status: .clean, lastActivity: Date())
        let env = EnvBuilder.build(
            project: project, worktree: wt, sessionId: "s",
            socketPath: nil,
            inheritParent: false,
            parent: [:],
            zmxDir: "/tmp/alas-zmx-501"
        )
        #expect(env["ZMX_DIR"] == "/tmp/alas-zmx-501")
    }

    @Test func zmxDirIsAbsentWhenNotProvided() {
        let project = ProjectConfig(id: "p", name: "x/y", path: "/r", color: "#0", addedAt: Date())
        let wt = Worktree(id: "w", projectId: "p", name: "m", branch: "m",
                          path: URL(fileURLWithPath: "/wt"),
                          status: .clean, lastActivity: Date())
        let env = EnvBuilder.build(
            project: project, worktree: wt, sessionId: "s",
            socketPath: nil,
            inheritParent: false,
            parent: [:],
            zmxDir: nil
        )
        #expect(env["ZMX_DIR"] == nil)
    }

    @Test func alasSessionIdEqualsCallerSuppliedValue() {
        let project = ProjectConfig(id: "p", name: "x/y", path: "/r", color: "#0", addedAt: Date())
        let wt = Worktree(id: "w", projectId: "p", name: "m", branch: "m",
                          path: URL(fileURLWithPath: "/wt"),
                          status: .clean, lastActivity: Date())
        let env = EnvBuilder.build(
            project: project, worktree: wt, sessionId: "leaf-UUID-ABC",
            socketPath: nil,
            inheritParent: false,
            parent: [:],
            zmxDir: nil
        )
        #expect(env["ALAS_SESSION_ID"] == "leaf-UUID-ABC")
    }
}
