import Foundation
import Testing
@testable import Alas

struct RemoteTailscaleTests {
    private static let name = "mac.tail1.ts.net"

    @Test(arguments: [
        (#"{"BackendState":"Running","Self":{"DNSName":"Mac.tail1.ts.net."},"CertDomains":["mac.tail1.ts.net"]}"#,
         RemoteTailscaleStatus(dnsName: name, httpsEnabled: true)),
        (#"{"BackendState":"Running","Self":{"DNSName":"mac.tail1.ts.net."},"CertDomains":null}"#,
         RemoteTailscaleStatus(dnsName: name, httpsEnabled: false)),
        (#"{"BackendState":"Stopped","Self":{"DNSName":"mac.tail1.ts.net."}}"#, nil),
        (#"{"BackendState":"Running","Self":{"DNSName":""}}"#, nil),
    ] as [(String, RemoteTailscaleStatus?)])
    func parseStatus(json: String, expected: RemoteTailscaleStatus?) throws {
        #expect(try RemoteTailscale.parseStatus(Data(json.utf8)) == expected)
    }

    @Test func parseStatusTreatsMalformedOutputAsUnknownNotStopped() {
        #expect(throws: (any Error).self) { try RemoteTailscale.parseStatus(Data("not json".utf8)) }
    }

    @Test(arguments: [
        ("{}", RemoteTailscaleServeState.off),
        ("not json", nil),
        // Captured from `tailscale serve status --json` (1.102.4).
        (#"{"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail1.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8765"}}}}}"#,
         .ours(port: 8765)),
        (#"{"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail1.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}"#,
         .conflict("already serves something else")),
        (#"{"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail1.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8765"},"/api":{"Proxy":"http://127.0.0.1:9000"}}}}}"#,
         .conflict("already serves something else")),
        (#"{"TCP":{"443":{"TCPForward":"127.0.0.1:22"}}}"#, .conflict("another Tailscale service")),
        // Route left under the pre-rename hostname.
        (#"{"TCP":{"443":{"HTTPS":true}},"Web":{"old.tail1.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8765"}}}}}"#,
         .conflict("old.tail1.ts.net")),
        (#"{"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail1.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8765"}}}},"AllowFunnel":{"mac.tail1.ts.net:443":true}}"#,
         .conflict("Funnel")),
    ] as [(String, RemoteTailscaleServeState?)])
    func parseServe(json: String, expected: RemoteTailscaleServeState?) {
        let state = RemoteTailscale.parseServe(Data(json.utf8), dnsName: Self.name, ports: [8765, 9999])
        // 3000 isn't a port Alas listens on or recorded, so it isn't ours.
        // Conflicts match on a substring identifying which check fired.
        if case .conflict(let expectedReason)? = expected {
            guard case .conflict(let reason)? = state else {
                Issue.record("expected conflict, got \(String(describing: state))")
                return
            }
            #expect(reason.contains(expectedReason))
        } else {
            #expect(state == expected)
        }
    }
}
