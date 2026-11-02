import CryptoKit
import Foundation
import AlasFoundation
import AlasPlatform

public struct HostSSHAgent: Equatable, Sendable {
    public var id: String
    public var enabled: Bool

    public init(id: String, enabled: Bool) {
        self.id = id
        self.enabled = enabled
    }
}

/// What one SSH round trip learns about a Mac before setting up `alas-host` on it.
public struct HostSSHProbe: Equatable, Sendable {
    public var os: String
    public var arch: String
    public var brew: String?
    /// The installed cask that ships `alas-host`: "alas-host" or "alas".
    public var cask: String?
    public var hostPath: String?
    public var hostSHA256: String?
    /// From the existing host's `config list`.
    public var reachability: String?
    public var agents: [HostSSHAgent]

    public init(
        os: String,
        arch: String,
        brew: String? = nil,
        cask: String? = nil,
        hostPath: String? = nil,
        hostSHA256: String? = nil,
        reachability: String? = nil,
        agents: [HostSSHAgent] = []
    ) {
        self.os = os
        self.arch = arch
        self.brew = brew
        self.cask = cask
        self.hostPath = hostPath
        self.hostSHA256 = hostSHA256
        self.reachability = reachability
        self.agents = agents
    }

    static let configMarker = "--config--"

    /// Parses `HostSSHSetup.probeScript`'s output: `key=value` lines, then
    /// the marker, then `alas-host config list` (`key = value` lines).
    public static func parse(_ output: String) -> HostSSHProbe {
        var fields: [String: String] = [:]
        var probe = HostSSHProbe(os: "", arch: "")
        var inConfig = false
        for line in output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line == configMarker {
                inConfig = true
                continue
            }
            let separator = inConfig ? " = " : "="
            guard !line.hasPrefix("#"), let range = line.range(of: separator) else { continue }
            let key = String(line[..<range.lowerBound])
            let value = String(line[range.upperBound...])
            guard inConfig else {
                fields[key] = value
                continue
            }
            if key == "host.reachability" {
                probe.reachability = value
            } else if key.hasPrefix("agents."), key.hasSuffix(".enabled") {
                let id = key.dropFirst("agents.".count).dropLast(".enabled".count)
                probe.agents.append(HostSSHAgent(id: String(id), enabled: value == "true"))
            }
        }
        let nonEmpty = { (key: String) in fields[key].flatMap { $0.isEmpty ? nil : $0 } }
        probe.os = fields["os"] ?? ""
        probe.arch = fields["arch"] ?? ""
        probe.brew = nonEmpty("brew")
        probe.cask = nonEmpty("cask")
        probe.hostPath = nonEmpty("host")
        probe.hostSHA256 = nonEmpty("sha")
        return probe
    }
}

public enum HostSSHInstall: Equatable, Sendable {
    case brewUpgrade(cask: String)
    case brewInstall
    /// The remote's own Alas.app host: used as is, not ours to replace.
    case existing(path: String)
    /// Copy this app's host files into `~/.alas/host`.
    case copy
    case upToDate(path: String)
    case unsupported(String)

    public static func decide(_ probe: HostSSHProbe, bundleArch: String, bundleSHA256: String?) -> HostSSHInstall {
        if probe.os != "Darwin" {
            return .unsupported("alas-host runs on macOS only.")
        }
        if let cask = probe.cask {
            return .brewUpgrade(cask: cask)
        }
        if probe.brew != nil {
            return .brewInstall
        }
        if let path = probe.hostPath, path.hasPrefix(HostSSHSetup.appHostPath) {
            return .existing(path: path)
        }
        if probe.arch == bundleArch {
            if let path = probe.hostPath, let sha = probe.hostSHA256, sha == bundleSHA256 {
                return .upToDate(path: path)
            }
            return .copy
        }
        return .unsupported(
            "This app's alas-host is built for \(bundleArch), but the host Mac is \(probe.arch). "
                + "Install Homebrew on the host Mac and try again."
        )
    }
}

public struct HostSSHSetupOptions: Equatable, Sendable {
    public var reachability: String
    public var agents: [String: Bool]
    public var projects: [String]

    public init(reachability: String, agents: [String: Bool], projects: [String]) {
        self.reachability = reachability
        self.agents = agents
        self.projects = projects
    }
}

/// Installs, configures, starts and pairs `alas-host` on another Mac over
/// batch-mode SSH. Every remote command goes through `run`, so a failing
/// step stops the flow with that step's stderr.
public struct HostSSHSetup: Sendable {
    public struct Failure: Error, Equatable, LocalizedError {
        public let step: String
        public let message: String
        public let connectionFailed: Bool

        public init(step: String, message: String, connectionFailed: Bool) {
            self.step = step
            self.message = message
            self.connectionFailed = connectionFailed
        }

        public var errorDescription: String? { message }
    }

    public typealias Run = @Sendable (_ command: String, _ timeout: TimeInterval) async throws -> ProcessResult
    public typealias Upload = @Sendable (_ localPath: String, _ remotePath: String) async throws -> ProcessResult

    static let appHostPath = "/Applications/Alas.app/Contents/Resources/alas-host/alas-host"

    public let destination: String
    let bundleResources: URL
    let run: Run
    let upload: Upload
    let sleep: @Sendable (Duration) async throws -> Void

    public init(
        destination: String,
        bundleResources: URL,
        run: Run? = nil,
        upload: Upload? = nil,
        sleep: (@Sendable (Duration) async throws -> Void)? = nil
    ) {
        self.destination = destination
        self.bundleResources = bundleResources
        self.run = run ?? { command, timeout in
            try await RemoteExec.run(host: destination, cwd: nil, command: command, timeout: timeout)
        }
        self.upload = upload ?? { localPath, remotePath in
            try await Process.run(
                SSHCommand.scpExecutable,
                args: SSHCommand.scpArgv(localPath: localPath, host: destination, remotePath: remotePath),
                timeout: 300
            )
        }
        self.sleep = sleep ?? { try await Task.sleep(for: $0) }
    }

    /// `uname -m` name of the architecture this app's host binary is built for.
    public static var bundleArch: String {
        RemoteZmxInstaller.localArch == "aarch64" ? "arm64" : RemoteZmxInstaller.localArch
    }

    var bundleHost: URL { bundleResources.appendingPathComponent("alas-host/alas-host") }

    public var bundleSHA256: String? {
        guard let data = try? Data(contentsOf: bundleHost) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func decision(for probe: HostSSHProbe) -> HostSSHInstall {
        HostSSHInstall.decide(probe, bundleArch: Self.bundleArch, bundleSHA256: bundleSHA256)
    }

    /// Prints the host executable: on PATH (brew), else the copied or app one.
    static let locateHost = """
    h=$(command -v alas-host)
    if [ -z "$h" ]; then for p in "$HOME/.alas/host/alas-host/alas-host" \(appHostPath); do \
    if [ -x "$p" ]; then h=$p; break; fi; done; fi
    """

    static let probeScript = """
    echo "os=$(uname -s)"
    echo "arch=$(uname -m)"
    b=$(command -v brew)
    echo "brew=$b"
    c=
    if [ -n "$b" ]; then for k in alas-host alas; do \
    if "$b" list --cask "$k" >/dev/null 2>&1; then c=$k; break; fi; done; fi
    echo "cask=$c"
    \(locateHost)
    echo "host=$h"
    if [ -n "$h" ]; then
    echo "sha=$(shasum -a 256 "$h" | cut -d ' ' -f 1)"
    echo "\(HostSSHProbe.configMarker)"
    "$h" config list 2>/dev/null
    fi
    """

    public func probe() async throws -> HostSSHProbe {
        let result = try await step("Connect", Self.probeScript, timeout: 30)
        return HostSSHProbe.parse(result.stdout)
    }

    /// Installs or updates the host as `decision(for:)` says and returns its
    /// executable path on the remote.
    public func install(_ probe: HostSSHProbe, progress: @Sendable (String) -> Void) async throws -> String {
        switch decision(for: probe) {
        case .unsupported(let reason):
            throw Failure(step: "Install", message: reason, connectionFailed: false)
        case .existing(let path), .upToDate(let path):
            return path
        case .brewUpgrade(let cask):
            progress("Updating alas-host with Homebrew")
            return try await brew("upgrade --cask \(SSHCommand.shellQuote(cask))")
        case .brewInstall:
            progress("Installing alas-host with Homebrew")
            return try await brew("install --cask mrmans0n/tap/alas-host")
        case .copy:
            progress("Copying alas-host from this app")
            return try await copy()
        }
    }

    private func brew(_ arguments: String) async throws -> String {
        // brew's chatter goes to stderr so a failure shows it and stdout is the path.
        let result = try await step(
            "Install",
            "brew \(arguments) 1>&2 || exit $?\n\(Self.locateHost)\n[ -n \"$h\" ] && echo \"$h\"",
            timeout: 900
        )
        guard let path = result.stdout.split(separator: "\n").last.map(String.init), !path.isEmpty else {
            throw Failure(step: "Install", message: "Homebrew finished, but alas-host was not found.", connectionFailed: false)
        }
        return path
    }

    private func copy() async throws -> String {
        let cliArch = Self.bundleArch == "arm64" ? "macos-aarch64" : "macos-x86_64"
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-host-\(UUID().uuidString).tgz")
        defer { try? FileManager.default.removeItem(at: archive) }
        let tar = try await Process.run(
            "/usr/bin/tar",
            args: [
                "-C", bundleResources.path, "-czf", archive.path,
                "alas-host", "RemoteWeb", "zmx/zmx", "alas-cli/\(cliArch)/alas",
            ],
            timeout: 120
        )
        guard tar.exitCode == 0 else {
            throw Failure(step: "Install", message: Self.message(tar), connectionFailed: false)
        }
        _ = try await step("Install", "mkdir -p \"$HOME/.alas\"", timeout: 30)
        let uploaded: ProcessResult
        do {
            uploaded = try await upload(archive.path, ".alas/host.tgz")
        } catch {
            throw Failure(step: "Install", message: error.localizedDescription, connectionFailed: false)
        }
        try requireSuccess("Install", uploaded)
        let result = try await step("Install", """
        cd "$HOME/.alas" && rm -rf host.new && mkdir -p host.new && tar -xzf host.tgz -C host.new && \
        rm -f host.tgz && rm -rf host && mv host.new host && echo "$HOME/.alas/host/alas-host/alas-host"
        """, timeout: 120)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sets each changed setting and adds each project. Stops at the first refusal.
    public func configure(host: String, probe: HostSSHProbe, options: HostSSHSetupOptions) async throws {
        let alasHost = SSHCommand.shellQuote(host)
        var commands: [String] = []
        let set = { (key: String, value: String) in
            commands.append("\(alasHost) config set \(SSHCommand.shellQuote(key)) \(SSHCommand.shellQuote(value))")
        }
        if options.reachability != probe.reachability {
            set("host.reachability", options.reachability)
        }
        let current = Dictionary(probe.agents.map { ($0.id, $0.enabled) }, uniquingKeysWith: { $1 })
        for (id, enabled) in options.agents.sorted(by: { $0.key < $1.key }) where current[id] != enabled {
            set("agents.\(id).enabled", String(enabled))
        }
        for path in options.projects.map({ $0.trimmingCharacters(in: .whitespaces) }) where !path.isEmpty {
            commands.append("\(alasHost) project add \(SSHCommand.shellQuote(path))")
        }
        for command in commands {
            _ = try await step("Configure", command, timeout: 30)
        }
    }

    /// Installs and (re)starts the launchd agent that runs the host.
    public func start(host: String) async throws {
        do {
            _ = try await step("Start", "\(SSHCommand.shellQuote(host)) install-agent", timeout: 60)
        } catch let failure as Failure where !failure.connectionFailed {
            throw Failure(
                step: failure.step,
                message: failure.message
                    + "\nThe host Mac needs a user logged in (launchd runs the host in that user's session).",
                connectionFailed: false
            )
        }
    }

    /// Asks the freshly started host for a pairing link, retrying each second
    /// for 30 s while it comes up.
    public func pair(host: String) async throws -> String {
        let command = "\(SSHCommand.shellQuote(host)) pair"
        var lastFailure = Failure(step: "Pair", message: "The host did not answer.", connectionFailed: false)
        // ponytail: the deadline counts attempts, not wall time; each attempt is short.
        for attempt in 0...30 {
            if attempt > 0 { try await sleep(.seconds(1)) }
            do {
                let result = try await step("Pair", command, timeout: 10)
                guard let link = Self.pairingLink(fromPairOutput: result.stdout) else {
                    throw Failure(step: "Pair", message: Self.noLinkMessage, connectionFailed: false)
                }
                return link
            } catch let failure as Failure where !failure.connectionFailed && failure.message != Self.noLinkMessage {
                lastFailure = failure
            }
        }
        throw lastFailure
    }

    private static let noLinkMessage = "This alas-host prints no pairing link. Update it and try again."

    /// `alas-host setup --check` warnings; empty when the check itself fails.
    public func check(host: String) async -> [String] {
        guard let result = try? await run("\(SSHCommand.shellQuote(host)) setup --check", 30),
              result.exitCode == 0 else { return [] }
        return result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    public func log() async throws -> String {
        try await step("Log", "tail -n 300 \"$HOME/Library/Application Support/Alas/alas-host.log\"", timeout: 30).stdout
    }

    /// `alas-host pair` prints the code, then the link; an older host prints only the code.
    public static func pairingLink(fromPairOutput output: String) -> String? {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.count >= 2 ? lines[1] : nil
    }

    private func step(_ name: String, _ command: String, timeout: TimeInterval) async throws -> ProcessResult {
        let result: ProcessResult
        do {
            result = try await run(command, timeout)
        } catch {
            throw Failure(step: name, message: error.localizedDescription, connectionFailed: false)
        }
        try requireSuccess(name, result)
        return result
    }

    private func requireSuccess(_ name: String, _ result: ProcessResult) throws {
        guard result.exitCode != 0 else { return }
        throw Failure(
            step: name,
            message: Self.message(result),
            connectionFailed: RemoteExec.isConnectionFailure(exitCode: result.exitCode)
        )
    }

    private static func message(_ result: ProcessResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty ? (stdout.isEmpty ? "Exited with status \(result.exitCode)." : stdout) : stderr
    }
}
