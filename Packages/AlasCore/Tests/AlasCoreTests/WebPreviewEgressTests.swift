import Foundation
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
        ("192.168.1.144", nil),
        ("10.0.0.1", nil),
        ("100.64.0.1", nil),
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

    /// The pin admits only its own address bytes and port, and every answer
    /// for a name must pass.
    @Test(arguments: [
        (["192.0.2.1"], 3000, nil, nil),
        (["192.0.2.1", "127.0.0.1"], 3000, nil, Refusal.thisMac),
        (["127.0.0.1"], 51234, "127.0.0.1", nil),
        (["127.0.0.1"], 3000, "127.0.0.1", .thisMac),
        (["::ffff:127.0.0.1"], 51234, "127.0.0.1", .thisMac),
        (["::1"], 51234, "127.0.0.1", .thisMac),
        (["::1"], 51234, "::1", nil),
        (["192.168.1.143"], 51234, "127.0.0.1", .thisMac),
    ] as [([String], Int, String?, Refusal?)])
    func onlyThePinnedForwardMayBeThisMac(answers: [String], port: Int, pinned: String?, refusal: Refusal?) {
        let pin = pinned.map { WebPreviewEgressPolicy.Pin(addresses: [WebPreviewEgressPolicy.address($0)!], port: 51234) }
        let addresses = answers.compactMap(WebPreviewEgressPolicy.address)
        #expect(WebPreviewEgressPolicy.refusal(forAny: addresses, port: port, pin: pin, localAddresses: Self.local) == refusal)
    }

    /// `allowed.invalid` is the pinned echo server; every other name resolves
    /// to another loopback server or this Mac and must never reach it.
    @Test(arguments: [
        ("CONNECT allowed.invalid:{echo} HTTP/1.1", "200", true),
        ("CONNECT blocked.invalid:{other} HTTP/1.1", "403", false),
        ("CONNECT own.invalid:{other} HTTP/1.1", "403", false),
        ("CONNECT [::1]:{other} HTTP/1.1", "403", false),
        ("CONNECT missing.invalid:{other} HTTP/1.1", "502", false),
        ("GET http://allowed.invalid:{echo}/ HTTP/1.1", "405", false),
        ("CONNECT allowed.invalid HTTP/1.1", "400", false),
    ])
    func theProxyConnectsOnlyToVettedAddresses(request: String, status: String, echoes: Bool) async throws {
        let echo = try await EchoServer.start()
        let other = try await EchoServer.start()
        defer {
            echo.stop()
            other.stop()
        }
        let blocked = Mutex<[String]>([])
        let answers = [
            "allowed.invalid": ["127.0.0.1"], "blocked.invalid": ["127.0.0.1"], "own.invalid": ["192.0.2.7"],
            "::1": ["::1"],
        ]
        let proxy = WebPreviewEgressProxy(
            pin: WebPreviewEgressPolicy.Pin(addresses: [WebPreviewEgressPolicy.address("127.0.0.1")!], port: echo.port),
            resolve: { answers[$0] },
            localAddresses: { [WebPreviewEgressPolicy.address("192.0.2.7")!] },
            onBlocked: { host, _, refusal in blocked.withLock { $0.append("\(host): \(refusal.description)") } }
        )
        defer { proxy.stop() }
        let port = try await proxy.start()
        let client = try await TestClient.connect(host: "127.0.0.1", port: Int(port))
        let line = request.replacingOccurrences(of: "{echo}", with: "\(echo.port)")
            .replacingOccurrences(of: "{other}", with: "\(other.port)")
        client.send(Data("\(line)\r\nHost: x\r\n\r\n".utf8))
        let head = "HTTP/1.1 \(status) "
        try await eventually { String(decoding: client.received.bytes, as: UTF8.self).contains("\r\n\r\n") }
        #expect(String(decoding: client.received.bytes, as: UTF8.self).hasPrefix(head))
        if echoes {
            client.send(Data("ping".utf8))
            try await eventually { String(decoding: client.received.bytes, as: UTF8.self).hasSuffix("\r\n\r\nping") }
        } else {
            try await eventually { client.received.ended }
        }
        #expect(echo.accepted == (echoes ? 1 : 0))
        #expect(other.accepted == 0)
        #expect(blocked.withLock { $0.count } == (status == "403" ? 1 : 0))
    }
}
