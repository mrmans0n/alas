import Testing
@testable import AlasAgentKit
import AlasPlatform

struct RemoteTerminalHarnessTests {
    @Test func resolvesEachRemoteTerminalFromItsOwnForegroundGroup() {
        let sessions = [
            ZmxSessionInfo(name: "claude", startDir: "/repo", pid: 101),
            ZmxSessionInfo(name: "codex", startDir: "/repo", pid: 201),
            ZmxSessionInfo(name: "shell", startDir: "/repo", pid: 301),
            ZmxSessionInfo(name: "node", startDir: "/repo", pid: 401),
            ZmxSessionInfo(name: "gone", startDir: "/repo", pid: 501),
            ZmxSessionInfo(name: "launch", startDir: "/repo", pid: 601),
            ZmxSessionInfo(name: "ambiguous", startDir: "/repo", pid: 701),
            ZmxSessionInfo(name: "ambiguous-launcher", startDir: "/repo", pid: 801),
            ZmxSessionInfo(name: "shell-launcher", startDir: "/repo", pid: 901),
        ]
        let processes = """
        101 1 101 102 /bin/bash
        102 101 102 102 /home/test user/.local/share/claude/versions/2.1.325
        201 1 201 202 /bin/bash
        202 201 202 202 /usr/bin/node
        203 202 202 202 /opt/codex/bin/codex
        301 1 301 301 /bin/bash
        302 301 302 301 /opt/codex/bin/codex
        401 1 401 402 /bin/bash
        402 401 402 402 /usr/bin/node
        403 402 403 402 /opt/codex/bin/codex
        501 1 501 -1 /bin/bash
        601 1 601 601 /bin/bash
        602 601 601 601 /root/.local/share/claude/versions/2.1.325
        701 1 701 701 /bin/bash
        702 701 701 701 /usr/bin/claude
        703 701 701 701 /usr/bin/codex
        801 1 801 802 /bin/bash
        802 801 802 802 /usr/bin/wrapper
        803 802 802 802 /usr/bin/claude
        804 802 802 802 /usr/bin/codex
        901 1 901 901 /bin/bash
        902 901 901 901 /usr/bin/wrapper
        903 902 901 901 /usr/bin/codex
        """
        #expect(RemoteTerminalHarness.detect(sessions: sessions, processTable: processes) == [
            "claude": .claudeCode, "codex": .codex, "launch": .claudeCode, "shell-launcher": .codex,
        ])
    }

    @Test(arguments: [
        ("aifx", 102, "/home/user/.local/bin/claude", HarnessKind.claudeCode as HarnessKind?),
        ("aifx", 102, "/home/user/.local/share/claude/versions/2.1.325 (deleted)", .claudeCode),
        ("aifx", 103, "/home/user/.local/bin/claude", nil),
        ("wrapper", 102, "/opt/codex/bin/codex", .codex),
        ("wrapper", 102, "/usr/bin/vim", nil),
    ])
    func recognizesAgentsBehindLaunchersInTheForegroundGroup(
        launcher: String, childGroup: Int, executable: String, expected: HarnessKind?
    ) {
        let sessions = [ZmxSessionInfo(name: "devpod", startDir: "/repo", pid: 101)]
        let processes = """
        101 1 101 102 /bin/zsh
        102 101 102 102 /usr/bin/\(launcher)
        103 102 \(childGroup) 102 \(executable)
        """
        #expect(RemoteTerminalHarness.detect(sessions: sessions, processTable: processes)["devpod"] == expected)
    }
}
