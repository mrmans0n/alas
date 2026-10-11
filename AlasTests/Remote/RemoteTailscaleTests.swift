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

    /// The route must not outlive Alas, crashes included: the wrapper stops
    /// serving once the parent PID is gone.
    @Test func serveStopsWhenParentProcessIsGone() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeTailscale = dir.appendingPathComponent("tailscale")
        try "#!/bin/sh\nexec sleep 30\n".write(to: fakeTailscale, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeTailscale.path)

        let exitedParent = Process()
        exitedParent.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exitedParent.run()
        exitedParent.waitUntilExit()

        let serve = try RemoteTailscaleServeProcess(
            executable: fakeTailscale.path,
            port: 8765,
            parentPID: exitedParent.processIdentifier
        ) { _ in }
        defer { serve.stop() }

        let deadline = Date().addingTimeInterval(10)
        while serve.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!serve.isRunning)
    }
}
