import Foundation

/// This Mac's tailnet identity, read from `tailscale status --json`.
public struct RemoteTailscaleStatus: Equatable, Sendable {
    /// MagicDNS name, lowercased, without the trailing root dot.
    public let dnsName: String
    /// True when the tailnet can issue HTTPS certificates for `dnsName`, the
    /// precondition for `tailscale serve --https`.
    public let httpsEnabled: Bool

    public init(dnsName: String, httpsEnabled: Bool) {
        self.dnsName = dnsName
        self.httpsEnabled = httpsEnabled
    }
}

public enum RemoteTailscaleServeState: Equatable, Sendable {
    case off
    /// A foreground `tailscale serve` proxies `https://<dnsName>` to this
    /// loopback port.
    case serving(port: UInt16)
    /// `tailscale serve` exited on its own, e.g. 443 is already served.
    case failed(String)
}

/// Drives the `tailscale` CLI.
public enum RemoteTailscale: Sendable {
    /// The app binary first: the `/usr/local/bin` shim doesn't `exec`, so
    /// signalling it would leave the real process running.
    private static let candidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]
    private static let timeout: TimeInterval = 5
    /// The App Store build's app binary doubles as the CLI; without this it
    /// may launch as the GUI instead of answering the command.
    public static var environment: [String: String] {
        ProcessInfo.processInfo.environment.merging(["TAILSCALE_BE_CLI": "1"]) { _, new in new }
    }

    public static func executable() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Nil unless the backend is running and has a MagicDNS name. Throws on
    /// output that isn't a JSON object: unknown, not "stopped".
    public static func parseStatus(_ data: Data) throws -> RemoteTailscaleStatus? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProcessError.launchFailed("Unexpected tailscale status output.")
        }
        guard root["BackendState"] as? String == "Running",
              let me = root["Self"] as? [String: Any],
              let raw = me["DNSName"] as? String else { return nil }
        let dnsName = normalizedDNSName(raw)
        guard !dnsName.isEmpty else { return nil }
        let certDomains = (root["CertDomains"] as? [String] ?? []).map(normalizedDNSName)
        return RemoteTailscaleStatus(dnsName: dnsName, httpsEnabled: certDomains.contains(dnsName))
    }

    /// Nil when Tailscale isn't installed or isn't running; throws when the
    /// CLI fails, times out, or answers with something unparsable.
    public static func status() async throws -> RemoteTailscaleStatus? {
        guard let executable = executable() else { return nil }
        let result = try await Process.run(executable, args: ["status", "--json"], env: environment, timeout: timeout)
        guard result.exitCode == 0 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
        return try parseStatus(Data(result.stdout.utf8))
    }

    private static func normalizedDNSName(_ name: String) -> String {
        var name = name.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }
}

/// Runs `tailscale serve` in the foreground. Tailscale drops a foreground
/// route as soon as that process dies, even from SIGKILL, so the route can't
/// outlive Alas: no ownership records, no quit cleanup. macOS doesn't kill
/// children with their parent, so a `/bin/sh` wrapper polls `parentPID` and
/// stops serving within a second of Alas exiting, crashes included.
public final class RemoteTailscaleServeProcess {
    private static let script = """
    "$0" serve --https=443 "$1" & child=$!
    stop() { pkill -P $child 2>/dev/null; kill $child 2>/dev/null; }
    trap stop TERM INT HUP
    while kill -0 "$2" 2>/dev/null && kill -0 $child 2>/dev/null; do sleep 1; done
    stop
    wait $child
    """

    public let port: UInt16
    private let process = Process()
    private let stderr = Pipe()

    /// `onExit` runs on the main actor with stderr when serving stops on its
    /// own; never after `stop()`.
    public init(
        executable: String,
        port: UInt16,
        parentPID: Int32 = getpid(),
        onExit: @escaping @MainActor (String) -> Void
    ) throws {
        self.port = port
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.script, executable, "http://127.0.0.1:\(port)", String(parentPID)]
        process.environment = RemoteTailscale.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        process.terminationHandler = { [stderr] process in
            let message = String(decoding: stderr.fileHandleForReading.availableData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = message.isEmpty ? "tailscale serve exited (\(process.terminationStatus))." : message
            Task { @MainActor in onExit(reason) }
        }
        try process.run()
    }

    public var isRunning: Bool { process.isRunning }

    public func stop() {
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
    }
}
