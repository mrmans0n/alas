import Foundation
import Network
import Synchronization
import Testing
import AlasCore

struct WebPreviewEgressTests {
    typealias Refusal = WebPreviewEgressPolicy.Refusal

    /// This Mac's addresses in the table below.
    private static let local: Set<Data> = Set(["192.168.1.143", "fd7a:115c:a1e0::d614"].compactMap(WebPreviewEgressPolicy.address))

    @Test(arguments: [
        ("127.0.0.1", Refusal.thisMac),
        ("127.255.0.9", .thisMac),
        ("0.0.0.0", .thisMac),
        ("0.1.2.3", .thisMac),
        ("::1", .thisMac),
        ("::", .thisMac),
        ("::ffff:127.0.0.1", .thisMac),
        ("::ffff:7f00:2", .thisMac),
        ("::127.0.0.1", .thisMac),
        ("169.254.10.10", .localAddress),
        ("::ffff:169.254.1.1", .localAddress),
        ("fe80::1%en0", .localAddress),
        ("febf::1", .localAddress),
        ("192.168.1.143", .thisMac),
        ("::ffff:192.168.1.143", .thisMac),
        ("[fd7a:115c:a1e0:0::d614]", .thisMac),
        ("100.100.100.100", .thisMac),
        ("::ffff:100.100.100.100", .thisMac),
        ("fd7a:115c:a1e0::53", .thisMac),
        ("192.168.1.144", nil),
        ("10.0.0.1", nil),
        ("100.64.0.1", nil),
        ("100.100.100.101", nil),
        ("fd7a:115c:a1e0::54", nil),
        ("8.8.8.8", nil),
        ("::ffff:8.8.8.8", nil),
        ("fec0::1", nil),
        ("fd00::1", nil),
        ("2001:db8::1", nil),
    ] as [(String, Refusal?)])
    func remotePagesAreRefusedThisMacAndLinkLocal(address: String, refusal: Refusal?) throws {
        let bytes = try #require(WebPreviewEgressPolicy.address(address))
        #expect(WebPreviewEgressPolicy.refusal(for: bytes, localAddresses: Self.local) == refusal)
    }

    /// Every answer for a name must pass.
    @Test(arguments: [
        (["192.0.2.1"], nil),
        (["192.0.2.1", "2001:db8::1"], nil),
        (["192.0.2.1", "127.0.0.1"], Refusal.thisMac),
        (["2001:db8::1", "169.254.1.1"], .localAddress),
    ] as [([String], Refusal?)])
    func oneRefusedAnswerRefusesTheName(answers: [String], refusal: Refusal?) {
        let addresses = answers.compactMap(WebPreviewEgressPolicy.address)
        #expect(WebPreviewEgressPolicy.refusal(forAny: addresses, localAddresses: Self.local) == refusal)
    }

    /// `allowed.invalid` is this Mac's LAN address, which the injected
    /// address set leaves out so it stands in for a remote host; every other
    /// name resolves to loopback or an address the set lists, and must never
    /// reach a server. Requests carry the proxy's credentials unless
    /// `credentials` says otherwise.
    @Test(arguments: [
        ("CONNECT allowed.invalid:{port} HTTP/1.1", "200", true, nil),
        ("CONNECT blocked.invalid:{port} HTTP/1.1", "403", false, nil),
        ("CONNECT own.invalid:{port} HTTP/1.1", "403", false, nil),
        ("CONNECT [::1]:{port} HTTP/1.1", "403", false, nil),
        ("CONNECT missing.invalid:{port} HTTP/1.1", "502", false, nil),
        ("GET http://allowed.invalid:{port}/ HTTP/1.1", "405", false, nil),
        ("CONNECT allowed.invalid HTTP/1.1", "400", false, nil),
        ("CONNECT allowed.invalid:{port} HTTP/1.1", "407", false, ""),
        ("CONNECT allowed.invalid:{port} HTTP/1.1", "407", false, "Proxy-Authorization: Basic YWxhcy1wcmV2aWV3Ondyb25n\r\n"),
    ] as [(String, String, Bool, String?)])
    func theProxyConnectsOnlyToVettedAddresses(request: String, status: String, echoes: Bool, credentials: String?) async throws {
        let lan = try #require(RemoteNetwork.interfaces().first {
            !$0.isLoopback && !$0.host.hasPrefix("169.254.") && WebPreviewEgressPolicy.address($0.host)?.count == 4
        }).host
        let echo = try await EchoServer.start(host: "0.0.0.0")
        let loopback = try await EchoServer.start()
        defer {
            echo.stop()
            loopback.stop()
        }
        let blocked = Mutex<[String]>([])
        let answers = ["allowed.invalid": [lan], "blocked.invalid": ["127.0.0.1"], "own.invalid": ["192.0.2.7"], "::1": ["::1"]]
        let proxy = WebPreviewEgressProxy(
            resolve: { answers[$0] },
            localAddresses: { [WebPreviewEgressPolicy.address("192.0.2.7")!] },
            onBlocked: { host, _, refusal in blocked.withLock { $0.append("\(host): \(refusal.description)") } }
        )
        defer { proxy.stop() }
        let port = try await proxy.start()
        let client = try await TestClient.connect(host: "127.0.0.1", port: Int(port))
        let target = request.contains("blocked") || request.contains("::1") ? loopback.port : echo.port
        let authorization = credentials ?? Self.authorization(proxy)
        client.send(Data("\(request.replacingOccurrences(of: "{port}", with: "\(target)"))\r\nHost: x\r\n\(authorization)\r\n".utf8))
        try await eventually { String(decoding: client.received.bytes, as: UTF8.self).contains("\r\n\r\n") }
        #expect(String(decoding: client.received.bytes, as: UTF8.self).hasPrefix("HTTP/1.1 \(status) "))
        if echoes {
            client.send(Data("ping".utf8))
            try await eventually { String(decoding: client.received.bytes, as: UTF8.self).hasSuffix("\r\n\r\nping") }
        } else {
            try await eventually { client.received.ended }
        }
        #expect(echo.accepted == (echoes ? 1 : 0))
        #expect(loopback.accepted == 0)
        #expect(blocked.withLock { $0.count } == (status == "403" ? 1 : 0))
    }

    @Test func connectionsBeyondTheTunnelCapAreRefused() async throws {
        let lookups = Mutex<[CheckedContinuation<[String]?, Never>]>([])
        let proxy = WebPreviewEgressProxy(
            resolve: { _ in await withCheckedContinuation { continuation in lookups.withLock { $0.append(continuation) } } },
            localAddresses: { [] }, maxTunnels: 2, onBlocked: { _, _, _ in }
        )
        defer {
            proxy.stop()
            for lookup in lookups.withLock({ $0 }) {
                lookup.resume(returning: nil)
            }
        }
        let port = try await Int(proxy.start())
        let request = Data("CONNECT held.invalid:443 HTTP/1.1\r\n\(Self.authorization(proxy))\r\n".utf8)
        var held: [TestClient] = []
        for _ in 0..<2 {
            let client = try await TestClient.connect(host: "127.0.0.1", port: port)
            client.send(request)
            held.append(client)
        }
        // Both tunnels are open, waiting on their lookups.
        try await eventually { lookups.withLock { $0.count } == 2 }
        let refused = try await TestClient.connect(host: "127.0.0.1", port: port)
        try await eventually { refused.received.ended }
        #expect(String(decoding: refused.received.bytes, as: UTF8.self).hasPrefix("HTTP/1.1 503 "))
        #expect(held.allSatisfy { $0.received.bytes.isEmpty })
    }

    private static func authorization(_ proxy: WebPreviewEgressProxy) -> String {
        "Proxy-Authorization: Basic \(Data("\(WebPreviewEgressProxy.username):\(proxy.password)".utf8).base64EncodedString())\r\n"
    }
}
