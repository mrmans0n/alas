import Foundation
import Testing
@testable import Alas

struct RemoteTerminalLaunchTests {
    @Test func remoteLaunchBuildsInteractiveSSHSurface() {
        let launch = TerminalService.remoteLaunch(
            host: "devbox",
            worktreePath: "/srv/repo",
            zmxSessionName: "alas-aaaa-bbbb",
            keepAlive: true,
            startupSuffix: nil
        )
        #expect(launch.executable == "/usr/bin/ssh")
        #expect(launch.args.first == "-tt")
        #expect((launch.args.last ?? "").contains("alas-aaaa-bbbb"))
    }

    @Test func keepAliveOffSkipsZmx() {
        let launch = TerminalService.remoteLaunch(
            host: "devbox",
            worktreePath: "/srv/repo",
            zmxSessionName: "alas-aaaa-bbbb",
            keepAlive: false,
            startupSuffix: nil
        )
        #expect(!(launch.args.last ?? "").contains("zmx"))
    }

    @Test func agentSuffixRidesInsideScript() {
        let launch = TerminalService.remoteLaunch(
            host: "devbox",
            worktreePath: "/srv/repo",
            zmxSessionName: "alas-aaaa-bbbb",
            keepAlive: true,
            startupSuffix: "claude"
        )
        #expect((launch.args.last ?? "").contains("claude"))
    }

    @Test func launchScriptUsesProvidedRemoteCwd() {
        let launch = TerminalService.remoteLaunch(
            host: "devbox",
            worktreePath: "/srv/repo/subdir",
            zmxSessionName: "alas-aaaa-bbbb",
            keepAlive: true,
            startupSuffix: nil
        )

        #expect((launch.args.last ?? "").contains("cd '\\''/srv/repo/subdir'\\'' || exit"))
    }

    @Test func remoteLaunchPreservesConfiguredStartupScript() {
        var terminal = AppConfig.defaults.terminal
        terminal.startupScript = "echo global"
        let project = ProjectConfig(
            id: "p1",
            name: "Remote",
            path: "/srv/repo",
            color: "#5fb7c4",
            addedAt: Date(timeIntervalSince1970: 0),
            startupScripts: ProjectStartupScripts(
                sessionOpenMode: .appendToGlobal,
                sessionOpenScript: "echo project",
                worktreeCreateMode: .useGlobal,
                worktreeCreateScript: ""
            ),
            host: "devbox"
        )
        let startupScript = TerminalService.effectiveStartupScript(
            global: terminal,
            project: project,
            includeUserStartupScript: true,
            startupScriptSuffix: "claude --continue"
        )
        let launch = TerminalService.remoteLaunch(
            host: "devbox",
            worktreePath: "/srv/repo",
            zmxSessionName: "alas-aaaa-bbbb",
            keepAlive: true,
            startupSuffix: startupScript
        )
        let remoteScript = launch.args.last ?? ""

        #expect(remoteScript.contains("echo global"))
        #expect(remoteScript.contains("echo project"))
        #expect(remoteScript.contains("claude --continue"))
    }
}
