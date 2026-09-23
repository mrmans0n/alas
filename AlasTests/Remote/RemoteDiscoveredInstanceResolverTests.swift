import Testing
import Foundation
import Network
@testable import Alas

@MainActor
struct RemoteDiscoveredInstanceResolverTests {
    final class Requests {
        var seen: [URLRequest] = []
    }

    private let instance = RemoteDiscoveredInstance(
        id: "srv-a", name: "Mac A", protocolVersion: 1, model: nil,
        endpoints: [.service(name: "Mac A", type: RemoteBonjourService.type, domain: "local.", interface: nil)])

    private func info(serverId: String?, addresses: [RemoteAdvertisedAddress]) -> String {
        let snapshot = RemoteDiagnosticsSnapshot(
            appName: "Alas", port: 8765, addresses: addresses, usesPlainHTTP: true,
            pairedDeviceCount: 0, serverId: serverId, name: "Mac A")
        return String(decoding: try! JSONEncoder().encode(snapshot), as: UTF8.self)
    }

    private func resolver(host: String = "192.168.1.20", port: UInt16 = 8765,
                          resolveError: Error? = nil,
                          status: Int = 200, body: String,
                          fetchError: Error? = nil,
                          requests: Requests = Requests()) -> RemoteDiscoveredInstanceResolver {
        RemoteDiscoveredInstanceResolver(
            resolve: { _ in
                if let resolveError { throw resolveError }
                return (host, port)
            },
            fetch: { request in
                requests.seen.append(request)
                if let fetchError { throw fetchError }
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            },
            timeout: 1)
    }

    @Test func resolvedOriginComesFirstThenAdvertisedOnesWithoutLoopback() async {
        let requests = Requests()
        let body = info(serverId: "srv-a", addresses: [
            RemoteAdvertisedAddress(kind: .tailnet, interfaceName: "utun3", host: "100.64.0.9", port: 8765, isRecommended: true),
            RemoteAdvertisedAddress(kind: .localhost, interfaceName: nil, host: "127.0.0.1", port: 8765, isRecommended: false),
            RemoteAdvertisedAddress(kind: .lan, interfaceName: "en0", host: "192.168.1.20", port: 8765, isRecommended: false),
        ])
        let outcome = await resolver(body: body, requests: requests).origins(for: instance)
        #expect(outcome == .success(["http://192.168.1.20:8765", "http://100.64.0.9:8765"]))
        #expect(requests.seen.first?.url?.absoluteString == "http://192.168.1.20:8765/remote-info")
        #expect(requests.seen.first?.timeoutInterval == 1)
    }

    @Test func originListIsCappedAtTheLinkBound() async {
        let addresses = (1...20).map {
            RemoteAdvertisedAddress(kind: .lan, interfaceName: nil, host: "10.0.0.\($0)", port: 8765, isRecommended: false)
        }
        let outcome = await resolver(body: info(serverId: "srv-a", addresses: addresses)).origins(for: instance)
        guard case .success(let origins) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(origins.count == RemotePairingLink.maxOrigins)
        #expect(origins.first == "http://192.168.1.20:8765")
    }

    @Test func aDifferentServerIdInRemoteInfoIsAnIdentityMismatch() async {
        let outcome = await resolver(body: info(serverId: "srv-other", addresses: [])).origins(for: instance)
        #expect(outcome == .failure(.identityMismatch))
    }

    @Test func remoteInfoWithoutAServerIdIsAcceptedOnTheResolvedOriginAlone() async {
        let outcome = await resolver(body: info(serverId: nil, addresses: [])).origins(for: instance)
        #expect(outcome == .success(["http://192.168.1.20:8765"]))
    }

    @Test func aFailedResolutionIsUnreachableAndNeverFetches() async {
        let requests = Requests()
        let outcome = await resolver(resolveError: URLError(.timedOut), body: "", requests: requests).origins(for: instance)
        #expect(outcome == .failure(.unreachable))
        #expect(requests.seen.isEmpty)
    }

    @Test func aFailedOrNon200RemoteInfoIsUnreachable() async {
        let failed = await resolver(body: "", fetchError: URLError(.cannotConnectToHost)).origins(for: instance)
        #expect(failed == .failure(.unreachable))
        let forbidden = await resolver(status: 403, body: "forbidden").origins(for: instance)
        #expect(forbidden == .failure(.unreachable))
        let garbage = await resolver(body: "not json").origins(for: instance)
        #expect(garbage == .failure(.unreachable))
        let wrongShape = await resolver(body: #"{"pairingApprovalVersion":"1"}"#).resolvePeer(for: instance)
        #expect(wrongShape == .failure(.unreachable))
    }

    @Test func ipv6HostsAreBracketedInTheOrigin() async {
        let outcome = await resolver(host: "fd00::5", body: info(serverId: "srv-a", addresses: [])).origins(for: instance)
        #expect(outcome == .success(["http://[fd00::5]:8765"]))
    }

    @Test func linkLocalIPv6ZoneIsPreservedInTheOrigin() async {
        // `resolveOverTCP` returns the raw `NWEndpoint.Host` description,
        // which for link-local IPv6 carries the interface as `%en0`; the
        // resolved origin must keep it, or a later dial has no way to know
        // which interface to use.
        let outcome = await resolver(host: "fe80::1%en0", body: info(serverId: "srv-a", addresses: [])).origins(for: instance)
        #expect(outcome == .success(["http://[fe80::1%en0]:8765"]))
    }

    @Test func fallsBackToTheNextEndpointWhenTheFirstFailsToResolve() async {
        let endpointA = NWEndpoint.hostPort(host: "10.0.0.1", port: 8765)
        let endpointB = NWEndpoint.hostPort(host: "10.0.0.2", port: 8765)
        let multi = RemoteDiscoveredInstance(id: "srv-a", name: "Mac A", protocolVersion: 1, model: nil,
                                             endpoints: [endpointA, endpointB])
        let body = info(serverId: "srv-a", addresses: [])
        let resolver = RemoteDiscoveredInstanceResolver(
            resolve: { endpoint in
                if endpoint == endpointA { throw URLError(.cannotFindHost) }
                return ("192.168.1.20", 8765)
            },
            fetch: { request in
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            timeout: 1)
        let outcome = await resolver.origins(for: multi)
        #expect(outcome == .success(["http://192.168.1.20:8765"]))
    }

    @Test func fallsBackWhenTheFirstEndpointsRemoteInfoDoesNotAnswer() async {
        let endpointA = NWEndpoint.hostPort(host: "10.0.0.1", port: 8765)
        let endpointB = NWEndpoint.hostPort(host: "10.0.0.2", port: 8765)
        let multi = RemoteDiscoveredInstance(id: "srv-a", name: "Mac A", protocolVersion: 1, model: nil,
                                             endpoints: [endpointA, endpointB])
        let body = info(serverId: "srv-a", addresses: [])
        let resolver = RemoteDiscoveredInstanceResolver(
            resolve: { endpoint in endpoint == endpointA ? ("169.254.1.1", 8765) : ("192.168.1.20", 8765) },
            fetch: { request in
                guard request.url!.host != "169.254.1.1" else { throw URLError(.cannotConnectToHost) }
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            timeout: 1)
        let outcome = await resolver.origins(for: multi)
        #expect(outcome == .success(["http://192.168.1.20:8765"]))
    }

    @Test func identityMismatchIsRememberedOverAnUnreachableEndpointThatFollows() async {
        let endpointA = NWEndpoint.hostPort(host: "10.0.0.1", port: 8765)
        let endpointB = NWEndpoint.hostPort(host: "10.0.0.2", port: 8765)
        let multi = RemoteDiscoveredInstance(id: "srv-a", name: "Mac A", protocolVersion: 1, model: nil,
                                             endpoints: [endpointA, endpointB])
        let mismatchBody = info(serverId: "srv-other", addresses: [])
        let resolver = RemoteDiscoveredInstanceResolver(
            resolve: { endpoint in
                if endpoint == endpointA { return ("10.0.0.1", 8765) }
                throw URLError(.cannotFindHost)
            },
            fetch: { request in
                (Data(mismatchBody.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            timeout: 1)
        let outcome = await resolver.origins(for: multi)
        #expect(outcome == .failure(.identityMismatch))
    }

    @Test func exhaustingEveryEndpointWithoutASuccessIsUnreachable() async {
        let multi = RemoteDiscoveredInstance(id: "srv-a", name: "Mac A", protocolVersion: 1, model: nil,
                                             endpoints: [.hostPort(host: "10.0.0.1", port: 8765)])
        let resolver = RemoteDiscoveredInstanceResolver(
            resolve: { _ in throw URLError(.cannotFindHost) },
            fetch: { _ in throw URLError(.cannotFindHost) },
            timeout: 1)
        let outcome = await resolver.origins(for: multi)
        #expect(outcome == .failure(.unreachable))
    }

    @Test(arguments: [nil, ""] as [String?])
    func missingIdentityCannotEraseAnEarlierMismatch(missing: String?) async {
        let endpoints: [NWEndpoint] = [.hostPort(host: "10.0.0.1", port: 8765), .hostPort(host: "10.0.0.2", port: 8765)]
        let peer = RemoteDiscoveredInstance(id: "srv-a", name: "Mac A", protocolVersion: 1, model: nil, endpoints: endpoints)
        let resolver = RemoteDiscoveredInstanceResolver(resolve: { endpoint in
            (endpoint == endpoints[0] ? "10.0.0.1" : "10.0.0.2", 8765)
        }, fetch: { request in
            let id = request.url!.host == "10.0.0.1" ? "wrong" : missing
            return (Data(info(serverId: id, addresses: []).utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(await resolver.resolvePeer(for: peer) == .failure(.identityMismatch))
    }

    @Test func exactIdentityCanRecoverAfterMismatchAndMissingIdentity() async {
        let endpoints: [NWEndpoint] = (1...3).map { .hostPort(host: NWEndpoint.Host("10.0.0.\($0)"), port: 8765) }
        let peer = RemoteDiscoveredInstance(id: "srv-a", name: "Mac A", protocolVersion: 1, model: nil, endpoints: endpoints)
        let resolver = RemoteDiscoveredInstanceResolver(resolve: { endpoint in
            ("10.0.0.\(endpoints.firstIndex(of: endpoint)! + 1)", 8765)
        }, fetch: { request in
            let id: String? = switch request.url!.host {
            case "10.0.0.1": "wrong"
            case "10.0.0.2": nil
            default: "srv-a"
            }
            return (Data(info(serverId: id, addresses: []).utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(await resolver.origins(for: peer) == .success(["http://10.0.0.3:8765"]))
    }
}
