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
        ("not json", nil),
    ] as [(String, RemoteTailscaleStatus?)])
    func parseStatus(json: String, expected: RemoteTailscaleStatus?) {
        #expect(RemoteTailscale.parseStatus(Data(json.utf8)) == expected)
    }

    @Test(arguments: [
        ("{}", RemoteTailscaleServeState.off),
        ("not json", nil),
        // Captured from `tailscale serve status --json` (1.102.4).
        (#"{"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail1.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8765"}}}}}"#,
         .ours(port: 8765)),
        (#"{"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail1.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}"#,
         .conflict("")),
        (#"{"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail1.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8765"},"/api":{"Proxy":"http://127.0.0.1:9000"}}}}}"#,
         .conflict("")),
        (#"{"TCP":{"443":{"TCPForward":"127.0.0.1:22"}}}"#, .conflict("")),
        (#"{"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail1.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8765"}}}},"AllowFunnel":{"mac.tail1.ts.net:443":true}}"#,
         .conflict("")),
    ] as [(String, RemoteTailscaleServeState?)])
    func parseServe(json: String, expected: RemoteTailscaleServeState?) {
        let state = RemoteTailscale.parseServe(Data(json.utf8), dnsName: Self.name, ports: [8765, 9999])
        // 3000 isn't a port Alas listens on or recorded, so it isn't ours.
        if case .conflict? = expected {
            guard case .conflict? = state else {
                Issue.record("expected conflict, got \(String(describing: state))")
                return
            }
        } else {
            #expect(state == expected)
        }
    }
}
