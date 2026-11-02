import Foundation
import Synchronization
import Testing
@testable import AlasHostCore
import AlasPlatform

struct HostSSHSetupTests {
    /// Records every remote command and answers each with `reply`.
    final class FakeRemote: Sendable {
        let commands = Mutex<[String]>([])
        let sleeps = Mutex<[Duration]>([])
        let reply: @Sendable (String, Int) -> ProcessResult

        init(reply: @escaping @Sendable (String, Int) -> ProcessResult = { _, _ in ProcessResult(exitCode: 0, stdout: "", stderr: "") }) {
            self.reply = reply
        }

        func setup() -> HostSSHSetup {
            HostSSHSetup(
                destination: "me@mini",
                bundleResources: URL(fileURLWithPath: "/nonexistent"),
                run: { command, _ in
                    let index = self.commands.withLock {
                        $0.append(command)
                        return $0.count - 1
                    }
                    return self.reply(command, index)
                },
                upload: { _, _ in ProcessResult(exitCode: 0, stdout: "", stderr: "") },
                sleep: { duration in self.sleeps.withLock { $0.append(duration) } }
            )
        }
    }

    @Test func probeParsesItsScriptOutput() {
        let output = """
        os=Darwin
        arch=arm64
        brew=/opt/homebrew/bin/brew
        cask=alas-host
        host=/opt/homebrew/bin/alas-host
        sha=abc123
        --config--
        # Host
        host.reachability = tailscale

        # Agents
        agents.claude.enabled = true
        agents.codex.enabled = false
        """

        #expect(HostSSHProbe.parse(output) == HostSSHProbe(
            os: "Darwin",
            arch: "arm64",
            brew: "/opt/homebrew/bin/brew",
            cask: "alas-host",
            hostPath: "/opt/homebrew/bin/alas-host",
            hostSHA256: "abc123",
            reachability: "tailscale",
            agents: [HostSSHAgent(id: "claude", enabled: true), HostSSHAgent(id: "codex", enabled: false)]
        ))
    }

    static let appHost = "/Applications/Alas.app/Contents/Resources/alas-host/alas-host"
    static let copiedHost = "/Users/me/.alas/host/alas-host/alas-host"

    @Test(arguments: [
        (HostSSHProbe(os: "Linux", arch: "x86_64"), "unsupported"),
        (HostSSHProbe(os: "Darwin", arch: "arm64", brew: "/opt/homebrew/bin/brew", cask: "alas"), "brewUpgrade(alas)"),
        (HostSSHProbe(os: "Darwin", arch: "arm64", brew: "/opt/homebrew/bin/brew"), "brewInstall"),
        (HostSSHProbe(os: "Darwin", arch: "arm64", hostPath: appHost, hostSHA256: "other"), "existing"),
        (HostSSHProbe(os: "Darwin", arch: "arm64", hostPath: copiedHost, hostSHA256: "bundle"), "upToDate"),
        (HostSSHProbe(os: "Darwin", arch: "arm64", hostPath: copiedHost, hostSHA256: "old"), "copy"),
        (HostSSHProbe(os: "Darwin", arch: "x86_64"), "unsupported Homebrew"),
    ])
    func installDecision(probe: HostSSHProbe, expected: String) {
        let decision = HostSSHInstall.decide(probe, bundleArch: "arm64", bundleSHA256: "bundle")
        switch (decision, expected) {
        case (.unsupported, "unsupported"), (.brewInstall, "brewInstall"), (.copy, "copy"):
            break
        case let (.unsupported(reason), "unsupported Homebrew"):
            #expect(reason.contains("Homebrew"))
        case let (.brewUpgrade(cask), "brewUpgrade(alas)"):
            #expect(cask == "alas")
        case let (.existing(path), "existing"), let (.upToDate(path), "upToDate"):
            #expect(path == probe.hostPath)
        default:
            Issue.record("expected \(expected), got \(decision)")
        }
    }

    @Test func pairingLinkIsTheSecondLine() {
        #expect(HostSSHSetup.pairingLink(fromPairOutput: "123456\nhttp://a/?code=123456\n") == "http://a/?code=123456")
        #expect(HostSSHSetup.pairingLink(fromPairOutput: "123456\n") == nil)
    }

    @Test func configureQuotesProjectPathsAndSetsOnlyChangedKeys() async throws {
        let remote = FakeRemote()
        let probe = HostSSHProbe(
            os: "Darwin",
            arch: "arm64",
            reachability: "lan",
            agents: [HostSSHAgent(id: "claude", enabled: true), HostSSHAgent(id: "codex", enabled: true)]
        )
        let options = HostSSHSetupOptions(
            reachability: "tailscale",
            agents: ["claude": true, "codex": false],
            projects: ["~/code/it's here", "  "]
        )

        try await remote.setup().configure(host: "/opt/homebrew/bin/alas-host", probe: probe, options: options)

        #expect(remote.commands.withLock { $0 } == [
            "'/opt/homebrew/bin/alas-host' config set 'host.reachability' 'tailscale'",
            "'/opt/homebrew/bin/alas-host' config set 'agents.codex.enabled' 'false'",
            "'/opt/homebrew/bin/alas-host' project add '~/code/it'\\''s here'",
        ])
    }

    @Test(arguments: [(Int32(1), false), (Int32(255), true)])
    func aFailingStepStopsWithItsStderr(exitCode: Int32, connectionFailed: Bool) async {
        let remote = FakeRemote { _, _ in
            ProcessResult(exitCode: exitCode, stdout: "", stderr: "refused: the app has the profile open\n")
        }
        let options = HostSSHSetupOptions(reachability: "tailscale", agents: [:], projects: ["/p"])

        await #expect(throws: HostSSHSetup.Failure(
            step: "Configure",
            message: "refused: the app has the profile open",
            connectionFailed: connectionFailed
        )) {
            try await remote.setup().configure(host: "h", probe: HostSSHProbe(os: "Darwin", arch: "arm64"), options: options)
        }
        #expect(remote.commands.withLock { $0.count } == 1)
    }

    @Test func pairPollsUntilTheHostServes() async throws {
        let remote = FakeRemote { _, index in
            index < 2
                ? ProcessResult(exitCode: 1, stdout: "", stderr: "no host running")
                : ProcessResult(exitCode: 0, stdout: "123456\nhttp://a/?code=123456\n", stderr: "")
        }

        #expect(try await remote.setup().pair(host: "h") == "http://a/?code=123456")
        #expect(remote.sleeps.withLock { $0 } == [.seconds(1), .seconds(1)])
    }

    @Test func pairGivesUpAfterTheDeadline() async {
        let remote = FakeRemote { _, _ in ProcessResult(exitCode: 1, stdout: "", stderr: "no host running") }

        await #expect(throws: HostSSHSetup.Failure.self) { try await remote.setup().pair(host: "h") }
        #expect(remote.sleeps.withLock { $0.count } == 30)
    }
}
