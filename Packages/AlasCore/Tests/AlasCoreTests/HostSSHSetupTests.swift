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
            // A short-lived `install` writes the executable. Written from this
            // process, its descriptor can leak into another test's concurrent
            // fork, and Linux refuses to exec it while that child holds it
            // (ETXTBSY, exit 126).
            let source = directory.appendingPathComponent("\(name).txt")
            try body.write(to: source, atomically: true, encoding: .utf8)
            let install = Process()
            install.executableURL = URL(fileURLWithPath: "/usr/bin/install")
            install.arguments = ["-m", "755", source.path, bin.appendingPathComponent(name).path]
            try install.run()
            install.waitUntilExit()
            try #require(install.terminationStatus == 0)
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

    @Test(arguments: [
        (operation: "install", validSignature: true),
        (operation: "upgrade", validSignature: true),
        (operation: "upgrade", validSignature: false),
        (operation: "app", validSignature: true),
    ])
    func homebrewPreparesOnlyVerifiedStandaloneInstalls(operation: String, validSignature: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("host brew's \(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bin = directory.appendingPathComponent("bin")
        let root = directory.appendingPathComponent("Caskroom/alas-host/1.0")
        let installedHost = root.appendingPathComponent("alas-host/alas-host")
        let host = bin.appendingPathComponent("alas-host")
        let log = directory.appendingPathComponent("brew.log")
        let verificationLog = directory.appendingPathComponent("verified.log")
        let quarantineLog = directory.appendingPathComponent("quarantine.log")
        let verifier = bin.appendingPathComponent("verify")
        let clear = bin.appendingPathComponent("clear")
        let tools: [(URL, String)] = [
            (bin.appendingPathComponent("brew"), """
            #!/bin/sh
            {
                printf '%s\\n' "$HOMEBREW_NO_INSTALL_CLEANUP" "$HOMEBREW_NO_ENV_HINTS" "$HOMEBREW_NO_ASK"
                printf '%s\\n' "$@"
            } > \(SSHCommand.shellQuote(log.path))
            echo 'Homebrew install output'
            """),
            (verifier, """
            #!/bin/sh
            for argument do last=$argument; done
            printf '%s\\n' "$last" >> \(SSHCommand.shellQuote(verificationLog.path))
            exit \(validSignature ? 0 : 37)
            """),
            (clear, """
            #!/bin/sh
            printf '%s\\n' "$@" > \(SSHCommand.shellQuote(quarantineLog.path))
            """),
            (installedHost, "#!/bin/sh\nexit 0\n"),
            (root.appendingPathComponent("zmx/zmx"), "#!/bin/sh\nexit 0\n"),
            (root.appendingPathComponent("alas-cli/alas"), "#!/bin/sh\nexit 0\n"),
        ]
        for (tool, body) in tools {
            try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        try FileManager.default.createSymbolicLink(at: host, withDestinationURL: installedHost)
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedHost = installedHost.resolvingSymlinksInPath()
        // Execute the real preparation script, replacing only its system tools.
        // Production supplies neither optional argument.
        let preparation = """
        exec /bin/sh -c \(SSHCommand.shellQuote(HostSelfUpdate.prepareStandaloneInstallScript)) sh "$1" \
        \(SSHCommand.shellQuote(verifier.path)) \(SSHCommand.shellQuote(clear.path))
        """
        let setup = HostSSHSetup(
            destination: "me@mini",
            bundleResources: directory,
            run: { command, _ in
                let isolated = command.replacingOccurrences(
                    of: SSHCommand.shellQuote(HostSelfUpdate.prepareStandaloneInstallScript),
                    with: SSHCommand.shellQuote(preparation)
                )
                return try await Process.run(
                    "/usr/bin/env",
                    args: ["-i", "PATH=\(bin.path):/usr/bin:/bin", "HOME=\(directory.path)", "/bin/sh", "-c", isolated],
                    timeout: 10
                )
            }
        )
        let probe = HostSSHProbe(
            os: "Darwin",
            arch: HostSSHSetup.bundleArch,
            brew: bin.appendingPathComponent("brew").path,
            cask: operation == "install" ? nil : operation == "app" ? "alas" : "alas-host",
            hostPath: operation == "install" ? nil : host.path
        )

        if validSignature {
            #expect(try await setup.install(probe, progress: { _ in }) == host.path)
        } else {
            await #expect(throws: HostSSHSetup.Failure.self) {
                try await setup.install(probe, progress: { _ in })
            }
        }
        if operation == "app" {
            #expect(!FileManager.default.fileExists(atPath: log.path))
            #expect(!FileManager.default.fileExists(atPath: verificationLog.path))
            #expect(!FileManager.default.fileExists(atPath: quarantineLog.path))
        } else {
            let arguments = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
            // Exact argv rules out removed flags, checksum bypasses and unrelated casks.
            #expect(arguments == [
                "1", "1", "1", operation, "--cask",
                operation == "install" ? "mrmans0n/tap/alas-host" : "alas-host",
            ])
            let verified = try String(contentsOf: verificationLog, encoding: .utf8).split(separator: "\n")
                .map { URL(fileURLWithPath: String($0)).resolvingSymlinksInPath().path }
            #expect(verified == (validSignature
                ? [resolvedHost.path, resolvedRoot.appendingPathComponent("zmx/zmx").path, resolvedRoot.appendingPathComponent("alas-cli/alas").path]
                : [resolvedHost.path]))
            if validSignature {
                let cleared = try String(contentsOf: quarantineLog, encoding: .utf8).split(separator: "\n").map(String.init)
                let clearedRoot = try #require(cleared.last)
                #expect(Array(cleared.dropLast()) == ["-dr", "com.apple.quarantine"])
                #expect(URL(fileURLWithPath: clearedRoot).resolvingSymlinksInPath().path == resolvedRoot.path)
            } else {
                #expect(!FileManager.default.fileExists(atPath: quarantineLog.path))
            }
        }
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
        // A shell function, not a script file: on Linux, executing a file just
        // written fails with ETXTBSY while a process forked by a parallel test
        // still holds its write descriptor.
        let fake = """
        alas_host() {
          case "$1 $2" in
          "project list") printf 'id1  repo  /srv/repo\\n' ;;
          "project add") echo "$3" >> '\(dir.path)/added' ;;
          esac
        }
        """
        let setup = HostSSHSetup(
            destination: "me@mini",
            bundleResources: dir,
            run: { command, _ in try await Process.run("/bin/sh", args: ["-c", fake + "\n" + command], timeout: 10) }
        )

        try await setup.configure(host: "alas_host", options: HostSSHSetupOptions(reachability: "lan", agents: [:], projects: ["/srv/repo", "/srv/repo2"]))

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

    @Test(arguments: [false, true])
    @MainActor
    func aSelfUpdateDoesNotStopTheHostBeforeInstallationFinishes(fails: Bool) async throws {
        var replaced = false
        var events: [String] = []
        let lifecycle = HostSelfUpdate.Lifecycle(
            wasReplaced: { replaced },
            restart: { events.append("restart scheduled") },
            stop: { events.append("stopped") }
        )
        do {
            try await lifecycle.install {
                replaced = true
                lifecycle.executableChanged()
                await Task.yield()
                #expect(events.isEmpty)
                if fails { throw HostError.failed(message: "install failed") }
                events.append("installed")
            }
            #expect(!fails)
        } catch {
            #expect(fails)
        }
        #expect(events == (fails ? [] : ["installed", "restart scheduled", "stopped"]))
    }

    @Test
    @MainActor
    func anUpToDateHostDoesNotScheduleARestart() async throws {
        let lifecycle = HostSelfUpdate.Lifecycle(
            wasReplaced: { false },
            restart: { Issue.record("An unchanged host must not restart") },
            stop: { Issue.record("An unchanged host must keep serving") }
        )
        try await lifecycle.install {}
    }

    #if os(macOS)
    @Test(arguments: [0, 17])
    func theRestartHelperWaitsForHostExitAndRemovesItsJobEvenIfRestartFails(status: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-restart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let exited = root.appendingPathComponent("host-exited")
        let launcher = root.appendingPathComponent("launchctl")
        try """
        #!/bin/sh
        if [ "$1" = kickstart ]; then
            [ -f \(SSHCommand.shellQuote(exited.path)) ] || exit 42
            printf 'started %s\\n' "$2"
            exit \(status)
        fi
        printf 'removed %s\\n' "$2"
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        // Model the old process exiting on the first poll, without real sleeps.
        let script = """
        kill() { [ ! -f \(SSHCommand.shellQuote(exited.path)) ]; }
        sleep() { touch \(SSHCommand.shellQuote(exited.path)); }
        \(HostSelfUpdate.restartScript)
        """
        let result = try await Process.run(
            "/bin/sh", args: ["-c", script, "sh", "123", "gui/501/host", "host.update", launcher.path], timeout: 5
        )
        #expect(result.exitCode == status)
        #expect(result.stdout == "started gui/501/host\nremoved host.update\n")
    }
    #endif

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
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.41.0"], format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        #expect(HostSelfUpdate.cask(executablePath: "/Applications/Alas.app/Contents/Resources/alas-host/alas-host") == "alas")
        #expect(HostSelfUpdate.version(executablePath: app.path + "/Contents/Resources/alas-host/alas-host") == "0.41.0")
    }

    /// A host unpacked from the Linux tarball runs the release its VERSION
    /// names, and updates from the latest release's tarball for its architecture.
    @Test func aHostFromTheLinuxTarballKnowsItsReleaseAndFindsTheNextOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-\(UUID().uuidString)/opt/alas")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        let executable = root.appendingPathComponent("alas-host/alas-host").path
        try FileManager.default.createDirectory(at: root.appendingPathComponent("alas-host"), withIntermediateDirectories: true)
        #expect(HostSelfUpdate.linuxInstallRoot(executablePath: executable) == nil)
        try "0.42.0\n".write(to: root.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        #expect(HostSelfUpdate.linuxInstallRoot(executablePath: executable)?.path == root.path)
        #expect(HostSelfUpdate.version(executablePath: executable) == "0.42.0")

        let release = Data(#"{"assets":[{"name":"alas-host-0.43.0-arm64.zip","browser_download_url":"https://e/1"},{"name":"alas-host-0.43.0-linux-x86_64.tar.gz","browser_download_url":"https://e/2"},{"name":"alas-host-0.43.0-linux-aarch64.tar.gz","browser_download_url":"https://e/3"}]}"#.utf8)
        #expect(HostSelfUpdate.linuxAsset(in: release, architecture: "aarch64")?.absoluteString == "https://e/3")
        #expect(HostSelfUpdate.linuxAsset(in: release, architecture: "riscv64") == nil)
    }
}
