import Foundation
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
        ("aifx", 102, "2.1.325\t/home/user/.local/share/claude/versions/2.1.325 (deleted)", .claudeCode),
        ("aifx", 103, "/home/user/.local/bin/claude", nil),
        ("wrapper", 102, "/opt/codex/bin/codex", .codex),
        ("wrapper", 102, "gemini\t/usr/bin/node", .gemini),
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

    /// Runs the remote host's selection step on a fixture, as the host's `sh` and `awk` would.
    private func selectOnTheHost(names: Set<String>, sessions: String, processes: String) throws -> (sessions: String, rows: String) {
        let script = RemoteTerminalHarness.selectSessionsScript(names: names)
            + "\n" + RemoteTerminalHarness.selectRowsScript
            + "\nprintf '%s\\n__ROWS__\\n%s\\n' \"$selected\" \"$rows\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ProcessInfo.processInfo.environment.merging(["sessions": sessions, "processes": processes]) { $1 }
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let parts = text.components(separatedBy: "__ROWS__\n")
        return (parts[0], parts.dropFirst().joined())
    }

    @Test func hostSendsBackOnlyTheMonitoredSessionsAndTheirForegroundRows() throws {
        let sessions = [
            "name=devpod\tpid=101\tclients=1\tstart_dir=/repo",
            "name=wrapped\tpid=301\tclients=1\tstart_dir=/repo",
            "name=other\tpid=201\tclients=1\tstart_dir=/other",
        ].joined(separator: "\n")
        let processes = """
            1     0     1     -1 /sbin/init
          500     1   500     -1 /usr/sbin/sshd
          101     1   101    102 /bin/zsh
          102   101   102    102 /usr/bin/aifx
          103   102   102    102 /home/user/.local/bin/claude
          104   101   104    102 /usr/bin/sleep
          105   104   105    102 /usr/bin/git
          201     1   201    202 /bin/bash
          202   201   202    202 /opt/codex/bin/codex
          203   202   202    202 /usr/bin/node
          301     1   301    301 /bin/bash
          302   301   301    301 /usr/bin/wrapper
          303   302   301    301 /opt/codex/bin/codex
          304   303   301    301 /usr/bin/rg
          400     1   400     -1 /Applications/Some App/helper
        """
        let selected = try selectOnTheHost(names: ["devpod", "wrapped"], sessions: sessions, processes: processes)

        #expect(selected.sessions == "name=devpod\tpid=101\tclients=1\tstart_dir=/repo\nname=wrapped\tpid=301\tclients=1\tstart_dir=/repo\n")
        let rows = selected.rows.split(separator: "\n").map { $0.split(separator: " ").first.map(String.init) ?? "" }.sorted()
        #expect(rows == ["101", "102", "103", "301", "302", "303"])
        #expect(
            RemoteTerminalHarness.detect(sessions: ZmxClient.parseSessionInfos(selected.sessions), processTable: selected.rows)
                == ["devpod": .claudeCode, "wrapped": .codex]
        )
    }

    @Test func mailboxEventsMustComeFromTheRegisteredForegroundGroup() throws {
        let id = UUID().uuidString
        let session = ZmxSessionInfo(name: "one", startDir: "/repo", pid: 100)
        let processes = """
        100 1 100 101 /bin/bash
        101 100 101 101 /usr/bin/claude
        102 100 102 101 /usr/bin/claude
        """
        for (pid, envelopeID, agent, matches) in [
            (101, id, "claude", true), (102, id, "claude", false),
            (101, "other", "claude", false), (101, id, "codex", false),
        ] {
            let event = """
            {"v":1,"event":"awaiting_input","agent":"\(agent)","session_id":"\(envelopeID)","pid":\(pid)}
            """
            let snapshot = RemoteTerminalHarness.snapshot(
                sessions: [session], processTable: processes,
                hookOutput: "\(id)\t\(event)", namesByID: [id: "one"]
            )
            #expect(snapshot.agents["one"] == .claudeCode)
            #expect((snapshot.hooks[id]?.event == .awaitingInput) == matches)
        }
    }
}
