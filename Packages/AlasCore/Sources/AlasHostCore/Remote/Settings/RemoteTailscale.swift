import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents

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

    private struct Node: Decodable {
        let Online: Bool
        let TailscaleIPs: [String]?
        let DNSName: String?
    }

    static func candidateOrigins(status: Data, ports: [Int]) -> [String] {
        struct Inventory: Decodable {
            let BackendState: String
            let Peer: [String: Node]?
        }
        guard let inventory = try? JSONDecoder().decode(Inventory.self, from: status),
              inventory.BackendState == "Running" else { return [] }
        var result: [String] = []
        for node in inventory.Peer?.values.filter(\.Online) ?? [] {
            for ip in node.TailscaleIPs ?? [] where RemoteNetwork.isTailnetIPv4(ip) || RemoteNetwork.isTailnetIPv6(ip) {
                let host = ip.contains(":") ? "[\(ip)]" : ip
                for port in ports { result.append("http://\(host):\(port)") }
            }
            if let dns = node.DNSName.map(normalizedDNSName), dns.hasSuffix(".ts.net"),
               dns.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) {
                result.append("https://\(dns)")
            }
        }
        return result.sorted()
    }

    @MainActor
    static func discover(peer: RemotePeer, local: RemotePeerManager.LocalIdentity) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                guard let key = peer.publicKey, !key.isEmpty, !local.publicKey.isEmpty, let executable = executable(),
                      let status = try? await Process.run(executable, args: ["status", "--json"], env: environment, timeout: timeout),
                      status.exitCode == 0 else {
                    continuation.finish()
                    return
                }
                let ports = Set(peer.origins.compactMap { URL(string: $0)?.port })
                let candidates = candidateOrigins(status: Data(status.stdout.utf8), ports: ports.sorted())
                    .filter { !peer.origins.contains($0) && $0 != peer.lastOrigin }
                let requester = ApprovalPeer(serverID: local.serverId, publicKey: local.publicKey, name: local.name,
                                             origins: Array(local.origins.prefix(RemotePairingLink.maxOrigins)))
                // Bound concurrent requests, including on large tailnets. No pairing request
                // is submitted: the challenge reply already signs the receiver's own origins.
                await withTaskGroup(of: String?.self) { group in
                    var pending = candidates.makeIterator()
                    func enqueue(_ origin: String) {
                        group.addTask {
                            await verifiedOrigin(origin, serverID: peer.serverId, key: key, requester: requester)
                        }
                    }
                    for _ in 0..<4 {
                        if let origin = pending.next() { enqueue(origin) }
                    }
                    while let result = await group.next() {
                        if let result { continuation.yield(result) }
                        if Task.isCancelled { group.cancelAll()
                        break }
                        if let origin = pending.next() { enqueue(origin) }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func verifiedOrigin(_ origin: String, serverID: String, key: String,
                                       requester: ApprovalPeer,
                                       fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = {
                                           try await boundedFetch($0, maxBytes: 65536)
                                       }) async -> String? {
        guard let infoURL = URL(string: origin + "/remote-info"),
              let url = URL(string: origin + "/peer-approval/v1/challenge") else { return nil }
        let nonce = RemoteIdentityCrypto.randomChallenge()
        var query = URLRequest(url: infoURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        query.setValue(nonce, forHTTPHeaderField: "X-Alas-Route-Nonce")
        query.setValue(origin, forHTTPHeaderField: "X-Alas-Route-Origin")
        guard let (data, response) = try? await fetch(query), response.statusCode == 200,
              let info = try? JSONDecoder().decode(RemoteDiagnosticsSnapshot.self, from: data),
              info.serverId == serverID, !Task.isCancelled else { return nil }
        if let proof = info.routeProof {
            return RemoteIdentityCrypto.verify(proof, serverId: routeIdentity(serverID, origin: origin),
                                               expectedPublicKey: key, challenge: nonce) ? origin : nil
        }
        // Existing GUI hosts can attest their addresses with the v1 challenge.
        guard info.pairingApprovalVersion == 1 else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(RemotePairingApprovalHTTP.ChallengeRequest(requester: requester, attemptNonce: nonce))
        guard let (reply, http) = try? await fetch(request), http.statusCode == 200,
              let envelope = try? JSONDecoder().decode(ApprovalEnvelope.self, from: reply) else { return nil }
        let proof = envelope.payload
        guard proof.operation == .challenge, proof.phase == .challenged, proof.attemptNonce == nonce,
              proof.requester == requester, proof.receiver.serverID == serverID, proof.receiver.publicKey == key,
              proof.receiver.origins.contains(origin), ApprovalWire.verify(envelope, expectedKey: key, reply: true)
        else { return nil }
        return origin
    }

    static func routeIdentity(_ serverID: String, origin: String) -> String {
        // A separate transcript from a socket proof, binding the address chosen
        // by the server to a fresh nonce. Server IDs and origins are single-line.
        "alas.tailnet-route.v1\n\(serverID)\n\(origin)"
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
    private let stderr = Pipe.closingOnExec()

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
