import Foundation
import Synchronization
import Testing
@testable import AlasHostCore
import AlasPlatform
import AlasACP

struct HostSSHSetupTests {
    /// Records every remote command and answers each with `reply`.
    final class FakeRemote: Sendable {
        let commands = Mutex<[String]>([])
        let sleeps = Mutex<[Duration]>([])
        let reply: @Sendable (String, Int) -> ProcessResult

        init(reply: @escaping @Sendable (String, Int) -> ProcessResult = { _, _ in ProcessResult(exitCode: 0, stdout: "", stderr: "") }) {
            self.reply = reply
        }

        func setup(bundle: URL = URL(fileURLWithPath: "/nonexistent")) -> HostSSHSetup {
            HostSSHSetup(
                destination: "me@mini",
                bundleResources: bundle,
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

    @Test func anExistingHostKeepsItsConfiguredAgents() async throws {
        let output = """
        os=Darwin
        arch=arm64
        brew=/opt/homebrew/bin/brew
        cask=alas-host
        host=/opt/homebrew/bin/alas-host
        __ALAS_AGENT_PROBE_AVAILABLE__ 1
        __ALAS_AGENT_PROBE_AVAILABLE__ 7
        --config--
        # Host
        host.reachability = tailscale

        # Agents
        agents.claude.enabled = true
        agents.codex.enabled = false
        """
        let remote = FakeRemote { _, _ in ProcessResult(exitCode: 0, stdout: output, stderr: "") }

        #expect(try await remote.setup().probe() == HostSSHProbe(
            os: "Darwin",
            arch: "arm64",
            brew: "/opt/homebrew/bin/brew",
            cask: "alas-host",
            hostPath: "/opt/homebrew/bin/alas-host",
            reachability: "tailscale",
            agents: [HostSSHAgent(id: "claude", enabled: true), HostSSHAgent(id: "codex", enabled: false)]
        ))
    }

    static let appHost = "/Applications/Alas.app/Contents/Resources/alas-host/alas-host"
    static let copiedHost = "/Users/me/.alas/host/alas-host/alas-host"

    static let brew = "/opt/homebrew/bin/brew"
    static let brewHost = "/opt/homebrew/bin/alas-host"

    @Test(arguments: [
        (HostSSHProbe(os: "Linux", arch: "x86_64"), "unsupported"),
        (HostSSHProbe(os: "Darwin", arch: "arm64", brew: brew, cask: "alas-host", hostPath: brewHost), "brewUpgrade(alas-host)"),
        // The full app is the user's: setting up a host must not upgrade it.
        (HostSSHProbe(os: "Darwin", arch: "arm64", brew: brew, cask: "alas", hostPath: brewHost), "existing"),
        // A cask record with no host behind it is stale, whichever cask it names.
        (HostSSHProbe(os: "Darwin", arch: "arm64", brew: brew, cask: "alas"), "brewInstall"),
        (HostSSHProbe(os: "Darwin", arch: "arm64", brew: brew, cask: "alas-host"), "brewInstall"),
        (HostSSHProbe(os: "Darwin", arch: "arm64", brew: brew), "brewInstall"),
        // A copy made after a stale cask's install failed still gets refreshed.
        (HostSSHProbe(os: "Darwin", arch: "arm64", brew: brew, cask: "alas", hostPath: copiedHost), "brewInstall"),
        (HostSSHProbe(os: "Darwin", arch: "arm64", brew: brew, cask: "alas-host", hostPath: copiedHost), "brewInstall"),
        (HostSSHProbe(os: "Darwin", arch: "arm64", hostPath: appHost), "existing"),
        // The web client, zmx and CLI change without the host binary: always copied.
        (HostSSHProbe(os: "Darwin", arch: "arm64", hostPath: copiedHost), "copy"),
        (HostSSHProbe(os: "Darwin", arch: "x86_64"), "unsupported Homebrew"),
    ])
    func installDecision(probe: HostSSHProbe, expected: String) {
        let decision = HostSSHInstall.decide(probe, bundleArch: "arm64")
        switch (decision, expected) {
        case (.unsupported, "unsupported"), (.brewInstall, "brewInstall"), (.copy, "copy"):
            break
        case let (.unsupported(reason), "unsupported Homebrew"):
            #expect(reason.contains("Homebrew"))
        case let (.brewUpgrade(cask), "brewUpgrade(alas-host)"):
            #expect(cask == "alas-host")
        case let (.existing(path), "existing"):
            #expect(path == probe.hostPath)
        default:
            Issue.record("expected \(expected), got \(decision)")
        }
    }

    @Test(arguments: [
        ("  812 /opt/homebrew/bin/alas-host\n", true),
        ("    1 /Users/me/.alas/host/alas-host/alas-host\n", false),
        ("  812 /bin/zsh\n  900 /usr/bin/not-alas-host-helper\n", false),
    ])
    func aHostRunInATerminalIsFound(psOutput: String, found: Bool) async throws {
        let result = try await Process.run(
            "/bin/sh",
            args: ["-c", "printf %s \(SSHCommand.shellQuote(psOutput)) | \(HostSSHSetup.foregroundHostFilter)"],
            timeout: 10
        )
        #expect((result.exitCode == 0) == found)
    }

    @Test func installsTheAdaptersOfEnabledManagedAgentsOnly() async {
        let remote = FakeRemote()
        let warnings = await remote.setup().installAdapters(agents: ["claude": true, "codex": false, "gemini": true])
        let commands = remote.commands.withLock { $0 }
        #expect(warnings.isEmpty)
        #expect(commands.count == 1)
        #expect(commands[0].contains("@alas-ide/claude-agent-acp"))
        // A fish or csh login shell can't parse the script itself.
        #expect(commands[0].contains("-i -l -c '/bin/sh -c "))
    }

    /// Runs in a real shell: what decides here is the script's own logic.
    @Test(arguments: [
        (owner: "@alas-ide/codex-acp", installs: false),
        (owner: "@agentclientprotocol/codex-acp", installs: true),
        (owner: nil, installs: true),
    ] as [(owner: String?, installs: Bool)])
    func installsAnAdapterUnlessItsPackageOwnsTheBinary(owner: String?, installs: Bool) throws {
        let adapter = ACPManagedAdapterDescriptor.codex
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("lib/node_modules")
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for package in [adapter.packageName, "@agentclientprotocol/codex-acp"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(package), withIntermediateDirectories: true)
        }
        if let owner {
            let executable = root.appendingPathComponent(owner).appendingPathComponent("index.js")
            try Data().write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent(adapter.binaryName), withDestinationURL: executable)
        }
        let log = directory.appendingPathComponent("npm.log")
        let tools: [(String, String)] = [
            ("codex", "#!/bin/sh\n"),
            ("npm", """
            #!/bin/sh
            case "$1" in
            root) echo "\(root.path)" ;;
            prefix) echo "\(directory.path)" ;;
            *) echo "$*" >> "\(log.path)" ;;
            esac
            """),
        ]
        for (name, body) in tools {
            let tool = bin.appendingPathComponent(name)
            try body.write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", HostSSHSetup.adapterInstallScript(cli: "codex", adapter: adapter)]
        shell.environment = ["PATH": "\(bin.path):/usr/bin:/bin"]
        try shell.run()
        shell.waitUntilExit()

        #expect(shell.terminationStatus == 0)
        let logged = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(logged.contains("install -g --force") == installs)
    }

    @Test func aFailedAdapterInstallIsAWarning() async {
        let remote = FakeRemote { _, _ in ProcessResult(exitCode: 127, stdout: "", stderr: "zsh: command not found: npm") }
        let warnings = await remote.setup().installAdapters(agents: ["codex": true])
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("@alas-ide/codex-acp"))
        #expect(warnings[0].contains("command not found: npm"))
    }

    @Test func homebrewRunsWithoutItsCleanup() async throws {
        let remote = FakeRemote { _, _ in ProcessResult(exitCode: 0, stdout: "\(Self.brewHost)\n", stderr: "") }
        let probe = HostSSHProbe(os: "Darwin", arch: "arm64", brew: Self.brew)

        #expect(try await remote.setup().install(probe, progress: { _ in }) == Self.brewHost)

        let command = try #require(remote.commands.withLock { $0.first })
        #expect(command.contains("HOMEBREW_NO_INSTALL_CLEANUP=1"))
        #expect(command.contains("install --cask mrmans0n/tap/alas-host"))
    }

    @Test func aFailedHomebrewInstallFallsBackToCopyingTheHost() async throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let cliArch = HostSSHSetup.bundleArch == "arm64" ? "macos-aarch64" : "macos-x86_64"
        for path in ["alas-host/alas-host", "RemoteWeb/index.html", "zmx/zmx", "alas-cli/\(cliArch)/alas"] {
            let file = bundle.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        let copied = "/Users/me/.alas/host/alas-host/alas-host"
        let remote = FakeRemote { command, _ in
            command.contains("brew ")
                ? ProcessResult(exitCode: 1, stdout: "", stderr: "Error: broken")
                : ProcessResult(exitCode: 0, stdout: "\(copied)\n", stderr: "")
        }
        let probe = HostSSHProbe(os: "Darwin", arch: HostSSHSetup.bundleArch, brew: Self.brew)
        let notes = Mutex<[String]>([])

        let host = try await remote.setup(bundle: bundle).install(probe, progress: { note in notes.withLock { $0.append(note) } })

        #expect(host == copied)
        #expect(notes.withLock { $0.count } == 1)
    }

    @Test(arguments: [
        // A host is already installed: a failed upgrade leaves it alone.
        HostSSHProbe(os: "Darwin", arch: HostSSHSetup.bundleArch, brew: brew, cask: "alas-host", hostPath: brewHost),
        // This app's host can't run there, so copying can't help.
        HostSSHProbe(os: "Darwin", arch: "other", brew: brew),
    ])
    func aHomebrewFailureThatCopyingCannotHelpIsReported(probe: HostSSHProbe) async {
        let remote = FakeRemote { _, _ in ProcessResult(exitCode: 1, stdout: "", stderr: "Error: broken") }

        await #expect(throws: HostSSHSetup.Failure(step: "Install", message: "Error: broken", connectionFailed: false)) {
            try await remote.setup().install(probe, progress: { _ in })
        }
    }

    @Test func aLongFailureKeepsItsEndsAndHomebrewsErrorLines() {
        let long = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let summary = HostSSHSetup.summarizedOutput(long)
        #expect(summary.hasPrefix("line 1\n"))
        #expect(summary.hasSuffix("\nline 40"))
        #expect(summary.contains("25 lines omitted"))
        #expect(!summary.contains("line 20\n"))

        let cleanup = (["==> Upgrading", "Error: mrmans0n/tap/alas: gone"] + (1...40).map { "Removing: \($0)" }).joined(separator: "\n")
        #expect(HostSSHSetup.summarizedOutput(cleanup) == "Error: mrmans0n/tap/alas: gone")

        #expect(HostSSHSetup.summarizedOutput("short\nfailure") == "short\nfailure")
    }

    @Test func pairingLinkIsTheSecondLine() {
        #expect(HostSSHSetup.pairingLink(fromPairOutput: "123456\nhttp://a/?code=123456\n") == "http://a/?code=123456")
        #expect(HostSSHSetup.pairingLink(fromPairOutput: "123456\n") == nil)
    }

    @Test func configureSetsEveryOptionAndAddsMissingProjects() async throws {
        let remote = FakeRemote()
        let options = HostSSHSetupOptions(reachability: "tailscale", agents: ["codex": false, "claude": true], projects: ["/srv/repo", "  "])

        try await remote.setup().configure(host: "/opt/homebrew/bin/alas-host", options: options)

        let host = "'/opt/homebrew/bin/alas-host'"
        #expect(remote.commands.withLock { $0 } == [
            "\(host) config set 'host.reachability' 'tailscale'",
            "\(host) config set 'agents.claude.enabled' 'true'",
            "\(host) config set 'agents.codex.enabled' 'false'",
            "p='/srv/repo'; \(host) project list | awk -v p=\"  $p\" 'substr($0, length($0) - length(p) + 1) == p { f = 1 } END { exit !f }' || \(host) project add \"$p\"",
        ])
    }

    @Test(arguments: [
        ("/srv/it's here/", "'/srv/it'\\''s here'"),
        ("~/code/x", "\"$HOME\"/'code/x'"),
        ("code/x", "\"$HOME\"/'code/x'"),
        ("~", "\"$HOME\""),
    ])
    func remotePathsResolveAgainstTheRemoteHome(path: String, word: String) {
        #expect(HostSSHSetup.remotePath(path) == word)
    }

    /// The project step's shell runs for real: a listed path is not added again.
    @Test func aListedProjectIsNotAddedAgain() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("alas-host")
        try """
        #!/bin/sh
        case "$1 $2" in
        "project list") printf 'id1  repo  /srv/repo\n' ;;
        "project add") echo "$3" >> "\(dir.path)/added" ;;
        esac
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let setup = HostSSHSetup(
            destination: "me@mini",
            bundleResources: dir,
            run: { command, _ in try await Process.run("/bin/sh", args: ["-c", command], timeout: 10) }
        )

        try await setup.configure(host: fake.path, options: HostSSHSetupOptions(reachability: "lan", agents: [:], projects: ["/srv/repo", "/srv/repo2"]))

        #expect(try String(contentsOf: dir.appendingPathComponent("added"), encoding: .utf8) == "/srv/repo2\n")
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
            try await remote.setup().configure(host: "h", options: options)
        }
        #expect(remote.commands.withLock { $0.count } == 1)
    }

    @Test(arguments: [
        ("", [String]()),
        ("__ALAS_AGENT_PROBE_AVAILABLE__ 1\n__ALAS_AGENT_PROBE_AVAILABLE__ 7\n", ["codex", "antigravity"]),
    ])
    func aFreshHostEnablesOnlyDetectedAgents(detectionOutput: String, enabled: [String]) async throws {
        let remote = FakeRemote { _, _ in
            ProcessResult(exitCode: 0, stdout: "os=Darwin\narch=arm64\nbrew=\ncask=\nhost=\n" + detectionOutput, stderr: "")
        }

        let agents = try await remote.setup().probe().agents
        #expect(agents.map(\.id) == ["claude", "codex", "cursor-agent", "pi", "omp", "opencode", "gemini", "antigravity", "copilot"])
        #expect(Set(agents.filter(\.enabled).map(\.id)) == Set(enabled))
    }

    @Test func pairPollsUntilTheHostServesBeyondLoopback() async throws {
        let remote = FakeRemote { _, index in
            switch index {
            case 0: ProcessResult(exitCode: 1, stdout: "", stderr: "no host running")
            // Tailscale serve not up yet: only loopback is advertised.
            case 1: ProcessResult(exitCode: 0, stdout: "123456\nhttp://127.0.0.1:8765/?code=123456\n", stderr: "")
            default: ProcessResult(exitCode: 0, stdout: "123456\nhttp://a/?code=123456\n", stderr: "")
            }
        }

        #expect(try await remote.setup().pair(host: "h") == "http://a/?code=123456")
        #expect(remote.sleeps.withLock { $0 } == [.seconds(1), .seconds(1)])
    }

    @Test func pairGivesUpAfterTheDeadline() async {
        let remote = FakeRemote { _, _ in ProcessResult(exitCode: 1, stdout: "", stderr: "no host running") }

        await #expect(throws: HostSSHSetup.Failure.self) { try await remote.setup().pair(host: "h") }
        #expect(remote.sleeps.withLock { $0.count } == 30)
    }

    @Test(arguments: [
        ("/opt/homebrew/Caskroom/alas-host/0.41.0/alas-host/alas-host", "alas-host", "0.41.0"),
        ("/usr/local/Caskroom/alas-host/0.41.0,7/alas-host/alas-host", "alas-host", "0.41.0,7"),
        ("/Users/me/.alas/host/alas-host/alas-host", nil, nil),
        ("/Users/me/dev/Alas.app/Contents/Resources/alas-host/alas-host", nil, nil),
    ] as [(String, String?, String?)])
    func aHostKnowsTheCaskAndReleaseItRunsFrom(path: String, cask: String?, version: String?) {
        #expect(HostSelfUpdate.cask(executablePath: path) == cask)
        // A copied host, or one in an app without an Info.plist, has none.
        #expect(HostSelfUpdate.version(executablePath: path) == version)
    }

    @Test func aHostInsideAnAppRunsTheAppsRelease() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("alas-\(UUID().uuidString)/Alas.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try (["CFBundleShortVersionString": "0.41.0"] as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        #expect(HostSelfUpdate.cask(executablePath: "/Applications/Alas.app/Contents/Resources/alas-host/alas-host") == "alas")
        #expect(HostSelfUpdate.version(executablePath: app.path + "/Contents/Resources/alas-host/alas-host") == "0.41.0")
    }
}
