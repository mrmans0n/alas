import AlasCore
@testable import AlasHostCore
import Crypto
import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct RemoteTailnetDiscoveryTests {
    @Test func onlyOnlineTailnetAddressesBecomeCandidates() {
        let status = Data(#"{"BackendState":"Running","Peer":{"a":{"Online":true,"DNSName":"Mini.tail.ts.net.","TailscaleIPs":["100.98.1.2","192.168.1.1","fd7a:115c:a1e0::1"]},"b":{"Online":false,"TailscaleIPs":["100.98.1.3"]}}}"#.utf8)
        #expect(RemoteTailscale.candidateOrigins(status: status, ports: [8765]) == [
            "http://100.98.1.2:8765", "http://[fd7a:115c:a1e0::1]:8765", "https://mini.tail.ts.net"
        ])
    }

    @Test(arguments: [true, false])
    func discoveredAddressMustBeSignedByThePairedMac(signsCandidate: Bool) async {
        let key = Curve25519.Signing.PrivateKey()
        let origin = "http://100.98.1.2:8765"
        let requester = ApprovalPeer(serverID: "local", publicKey: "", name: "Local", origins: [])
        let result = await RemoteTailscale.verifiedOrigin(origin, serverID: "mini",
            key: RemoteIdentityCrypto.publicKeyString(key.publicKey), requester: requester) { request in
            let nonce = try #require(request.value(forHTTPHeaderField: "X-Alas-Route-Nonce"))
            let url = try #require(request.url)
            var info = RemoteDiagnosticsSnapshot(appName: "Alas", port: 8765, addresses: [],
                usesPlainHTTP: true, pairedDeviceCount: 0, serverId: "mini")
            let address = signsCandidate ? origin : "http://100.98.1.3:8765"
            info.routeProof = RemoteIdentityCrypto.sign(serverId: RemoteTailscale.routeIdentity("mini", origin: address),
                                                        challenge: nonce, with: key)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (try JSONEncoder().encode(info), response)
        }
        #expect(result == (signsCandidate ? origin : nil))
    }
}
