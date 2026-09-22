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
        endpoint: .service(name: "Mac A", type: RemoteBonjourService.type, domain: "local.", interface: nil))

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
    }

    @Test func ipv6HostsAreBracketedInTheOrigin() async {
        let outcome = await resolver(host: "fd00::5", body: info(serverId: "srv-a", addresses: [])).origins(for: instance)
        #expect(outcome == .success(["http://[fd00::5]:8765"]))
    }
}
