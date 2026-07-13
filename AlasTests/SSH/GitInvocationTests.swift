import Foundation
import Testing
@testable import Alas

struct GitInvocationTests {
    @Test func localInvocationUsesGitCWithoutProcessWorkingDirectory() {
        let inv = GitInvocation.build(
            gitArgs: ["status", "--porcelain=v2"],
            cwd: URL(fileURLWithPath: "/Users/n/repo"),
            host: nil
        )
        #expect(inv.executable == "/usr/bin/env")
        #expect(inv.args == ["git", "-C", "/Users/n/repo", "status", "--porcelain=v2"])
        #expect(inv.cwd == nil)
        #expect(inv.env?["GIT_OPTIONAL_LOCKS"] == "0")
        #expect(inv.env?["LC_ALL"] == "C")
    }

    @Test func localInvocationWithoutCwdKeepsOriginalArguments() {
        let inv = GitInvocation.build(gitArgs: ["--version"], cwd: nil, host: nil)

        #expect(inv.args == ["git", "--version"])
        #expect(inv.cwd == nil)
    }

    @Test func remoteInvocationRunsSSHBatch() {
        let inv = GitInvocation.build(gitArgs: ["status"], cwd: URL(fileURLWithPath: "/srv/repo"), host: "devbox")
        #expect(inv.executable == "/usr/bin/ssh")
        #expect(inv.args.contains("BatchMode=yes"))
        #expect(inv.args.dropLast().last == "devbox")
        #expect(inv.cwd == nil)
        #expect(inv.env == nil)
    }

    @Test func remoteScriptSetsGitEnvOnRemoteSide() throws {
        let inv = GitInvocation.build(gitArgs: ["status"], cwd: URL(fileURLWithPath: "/srv/repo"), host: "devbox")
        let script = try #require(inv.args.last)
        #expect(script.hasPrefix("/bin/sh -c "))
        #expect(script.contains("cd '\\''/srv/repo'\\'' && "))
        #expect(script.contains("GIT_OPTIONAL_LOCKS=0"))
        #expect(script.contains("LC_ALL=C"))
        #expect(script.contains("git '\\''status'\\''"))
    }

    @Test func remoteArgsComposeThroughBothQuotingLayers() throws {
        let inv = GitInvocation.build(
            gitArgs: ["commit", "-m", "fix: don't break"],
            cwd: URL(fileURLWithPath: "/srv/repo"),
            host: "devbox"
        )
        let command = "env GIT_OPTIONAL_LOCKS=0 LC_ALL=C git 'commit' '-m' "
            + SSHCommand.shellQuote("fix: don't break")
        #expect(try #require(inv.args.last) == SSHCommand.remoteScript(cwd: "/srv/repo", command: command))
    }

    @Test func remoteWithoutCwdStillRunsRemotely() throws {
        let inv = GitInvocation.build(gitArgs: ["--version"], cwd: nil, host: "devbox")
        #expect(inv.executable == "/usr/bin/ssh")
        #expect(!(try #require(inv.args.last)).contains("cd "))
    }
}
