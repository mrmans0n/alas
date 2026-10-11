import Foundation

/// This Mac's tailnet identity, read from `tailscale status --json`.
struct RemoteTailscaleStatus: Equatable, Sendable {
    /// MagicDNS name, lowercased, without the trailing root dot.
    let dnsName: String
    /// True when the tailnet can issue HTTPS certificates for `dnsName`, the
    /// precondition for `tailscale serve --https`.
    let httpsEnabled: Bool
}

/// Who owns this Mac's `https://<dnsName>` (port 443, path `/`) handler.
enum RemoteTailscaleServeState: Equatable, Sendable {
    case off
    /// Proxies to the Alas server on this loopback port.
    case ours(port: UInt16)
    /// Something Alas must not touch: another service, or a Funnel.
    case conflict(String)
}

/// Drives the `tailscale` CLI. Parsing is pure and split from process I/O so
/// it can be tested against captured output.
enum RemoteTailscale {
    private static let candidates = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]
    private static let timeout: TimeInterval = 5
    /// The App Store build's app binary doubles as the CLI; without this it
    /// may launch as the GUI instead of answering the command.
    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment.merging(["TAILSCALE_BE_CLI": "1"]) { _, new in new }
    }

    static func executable() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Nil unless the backend is running and has a MagicDNS name.
    static func parseStatus(_ data: Data) -> RemoteTailscaleStatus? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["BackendState"] as? String == "Running",
              let me = root["Self"] as? [String: Any],
              let raw = me["DNSName"] as? String else { return nil }
        let dnsName = normalizedDNSName(raw)
        guard !dnsName.isEmpty else { return nil }
        let certDomains = (root["CertDomains"] as? [String] ?? []).map(normalizedDNSName)
        return RemoteTailscaleStatus(dnsName: dnsName, httpsEnabled: certDomains.contains(dnsName))
    }

    /// `ours` means `/` proxies to `http://127.0.0.1:<p>` for some `p` in
    /// `ports`: ports Alas is listening on or recorded installing. Nil when
    /// the output isn't a JSON object — unknown, not "nothing served".
    static func parseServe(_ data: Data, dnsName: String, ports: Set<UInt16>) -> RemoteTailscaleServeState? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let hostPort = "\(dnsName):443"
        if (root["AllowFunnel"] as? [String: Bool])?[hostPort] == true {
            return .conflict("Tailscale Funnel is on for \(dnsName). Alas won't serve on a public address.")
        }
        let web = (root["Web"] as? [String: Any])?[hostPort] as? [String: Any]
        let handlers = web?["Handlers"] as? [String: Any] ?? [:]
        if handlers.isEmpty {
            let tcp443 = (root["TCP"] as? [String: Any])?["443"] != nil
            return tcp443 ? .conflict("Port 443 on \(dnsName) is already used by another Tailscale service.") : .off
        }
        guard handlers.count == 1,
              let proxy = (handlers["/"] as? [String: Any])?["Proxy"] as? String,
              let port = ports.first(where: { proxy == target(port: $0) }) else {
            return .conflict("https://\(dnsName) already serves something else. Run `tailscale serve status` to see it.")
        }
        return .ours(port: port)
    }

    static func status() async -> RemoteTailscaleStatus? {
        guard let output = await run(["status", "--json"]) else { return nil }
        return parseStatus(output)
    }

    /// Nil when the CLI fails or times out.
    static func serveState(dnsName: String, ports: Set<UInt16>) async -> RemoteTailscaleServeState? {
        guard let output = await run(["serve", "status", "--json"]) else { return nil }
        return parseServe(output, dnsName: dnsName, ports: ports)
    }

    static func enableServe(port: UInt16) async throws {
        try await runChecked(["serve", "--bg", "--https=443", target(port: port)])
    }

    static func disableServe() async throws {
        try await runChecked(["serve", "--https=443", "off"])
    }

    private static func target(port: UInt16) -> String { "http://127.0.0.1:\(port)" }

    private static func normalizedDNSName(_ name: String) -> String {
        var name = name.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }

    private static func run(_ args: [String]) async -> Data? {
        guard let executable = executable(),
              let result = try? await Process.run(executable, args: args, env: environment, timeout: timeout),
              result.exitCode == 0 else { return nil }
        return Data(result.stdout.utf8)
    }

    private static func runChecked(_ args: [String]) async throws {
        guard let executable = executable() else { throw ProcessError.launchFailed("Tailscale CLI not found.") }
        let result = try await Process.run(executable, args: args, env: environment, timeout: timeout)
        guard result.exitCode == 0 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
    }
}
