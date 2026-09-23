import Foundation
import Network

/// Turns a browsed instance into the origin list `RemotePeerManager.addPeer`
/// needs: the address Bonjour resolves to, proven reachable just now, then
/// whatever that Mac advertises about itself in `/remote-info` (tailnet and
/// other interfaces), so the stored peer can be dialed later from elsewhere.
struct RemoteDiscoveredInstanceResolver {
    struct ResolvedPeer: Equatable, Sendable {
        let origins: [String]
        let serverID: String?
        let pairingApprovalVersion: Int?
    }

    enum Failure: Error, Equatable, Sendable {
        /// Bonjour could not resolve the endpoint, or the resolved address
        /// did not answer `/remote-info`.
        case unreachable
        /// `/remote-info` reported a different `serverId` than the TXT record
        /// this row was built from: a stale registration or a different Mac
        /// now answering at that address.
        case identityMismatch
    }

    // Not `@Sendable` for the same reason as `RemotePeerPairer.Fetch`: tests
    // inject closures recording into plain classes, on the main actor.
    typealias ResolveEndpoint = (NWEndpoint) async throws -> (host: String, port: UInt16)
    typealias Fetch = (URLRequest) async throws -> (Data, HTTPURLResponse)

    let resolve: ResolveEndpoint
    let fetch: Fetch
    let timeout: TimeInterval

    init(resolve: @escaping ResolveEndpoint, fetch: @escaping Fetch, timeout: TimeInterval = 4) {
        self.resolve = resolve
        self.fetch = fetch
        self.timeout = timeout
    }

    static var live: RemoteDiscoveredInstanceResolver {
        RemoteDiscoveredInstanceResolver(
            resolve: { try await Self.resolveOverTCP($0, timeout: 4) },
            fetch: { try await boundedFetch($0, maxBytes: maxReplyBytes) })
    }

    /// `/remote-info` is a handful of addresses and short strings. Same
    /// posture as `RemotePeerPairer.maxReplyBytes`: the endpoint is whatever
    /// answered a Bonjour name, so never buffer it unbounded.
    static let maxReplyBytes = 64 * 1024

    /// Tries every endpoint this identity was seen at, in order, falling
    /// back past a resolve failure, an unanswered `/remote-info`, or an
    /// answer from a different identity — any of those can be true of one
    /// interface while another still reaches the real peer. An identity
    /// mismatch is remembered over a plain unreachable, the same way
    /// `RemotePeerPairer` prioritizes `expiredCode`: it is the more
    /// informative failure to surface once every endpoint has been tried.
    func origins(for instance: RemoteDiscoveredInstance,
                 isolation: isolated (any Actor)? = #isolation) async -> Result<[String], Failure> {
        await resolvePeer(for: instance).map(\.origins)
    }

    func resolvePeer(for instance: RemoteDiscoveredInstance,
                     isolation: isolated (any Actor)? = #isolation) async -> Result<ResolvedPeer, Failure> {
        var sawIdentityMismatch = false
        for endpoint in instance.endpoints {
            guard let resolved = try? await resolve(endpoint),
                  let base = RemotePairingLink.normalizeOrigin("http://\(Self.urlHost(resolved.host)):\(resolved.port)"),
                  let url = URL(string: "\(base)/remote-info") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = timeout
            guard let (data, response) = try? await fetch(request), response.statusCode == 200,
                  let info = try? JSONDecoder().decode(RemoteDiagnosticsSnapshot.self, from: data) else { continue }
            if let reported = info.serverId, !reported.isEmpty, reported != instance.id {
                sawIdentityMismatch = true
                continue
            }
            var origins = [base]
            for address in info.addresses where address.kind != .localhost {
                guard origins.count < RemotePairingLink.maxOrigins else { break }
                guard let origin = RemotePairingLink.normalizeOrigin(address.url), !origins.contains(origin) else { continue }
                origins.append(origin)
            }
            // Legacy peers may omit identity. Approval requires the diagnostics
            // identity to agree with the discovered row before offering it.
            return .success(ResolvedPeer(origins: origins, serverID: info.serverId,
                pairingApprovalVersion: info.serverId == instance.id ? info.pairingApprovalVersion : nil))
        }
        return .failure(sawIdentityMismatch ? .identityMismatch : .unreachable)
    }

    /// Opens a TCP connection to the Bonjour endpoint and reads the address
    /// it landed on. Lets Network pick the address family — an IPv6-only LAN
    /// or a ULA/Tailscale-only peer must still resolve, and both are already
    /// accepted by `RemoteNetwork`'s Host policy. `hostString` below keeps a
    /// link-local IPv6 address's `%interface` zone rather than stripping it,
    /// since the origin built from it needs the zone to be dialable again.
    static func resolveOverTCP(_ endpoint: NWEndpoint, timeout: TimeInterval) async throws -> (host: String, port: UInt16) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "io.alas.remote.resolve")
        return try await withThrowingTaskGroup(of: (host: String, port: UInt16).self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(host: String, port: UInt16), Error>) in
                    let gate = ResumeGate()
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            guard gate.claim() else { return }
                            if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                                continuation.resume(returning: (hostString(host), port.rawValue))
                            } else {
                                continuation.resume(throwing: URLError(.cannotFindHost))
                            }
                            connection.cancel()
                        case .failed(let error):
                            guard gate.claim() else { return }
                            continuation.resume(throwing: error)
                        case .waiting(let error):
                            // No viable path (for example the peer is v6-only); do
                            // not sit here until the timeout fires.
                            guard gate.claim() else { return }
                            continuation.resume(throwing: error)
                            connection.cancel()
                        case .cancelled:
                            guard gate.claim() else { return }
                            continuation.resume(throwing: URLError(.cancelled))
                        default:
                            break
                        }
                    }
                    connection.start(queue: queue)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer {
                group.cancelAll()
                connection.cancel()
            }
            return try await group.next()!
        }
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address):
            // Description already carries a link-local address's zone as
            // `%en0`; keep it. `urlHost` below brackets the whole thing, and
            // `RemotePairingLink.normalizeOrigin` round-trips a bracketed
            // `[addr%zone]` host through `URLComponents` unchanged, so the
            // resulting origin is dialable again, zone and all.
            return "\(address)"
        case .name(let name, _): return name
        @unknown default: return "\(host)"
        }
    }

    private static func urlHost(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }
}

/// One-shot flag shared by the `NWConnection` state handler, which the
/// serial queue runs one call at a time, so a plain Bool suffices.
private final class ResumeGate: @unchecked Sendable {
    private var resumed = false
    func claim() -> Bool {
        if resumed { return false }
        resumed = true
        return true
    }
}
