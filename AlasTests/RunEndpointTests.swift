import Darwin
import Foundation
import Testing
@testable import Alas

struct RunEndpointTests {
    private func target(host: String?) -> RunExecutionTarget {
        RunExecutionTarget(host: host, workingDirectory: "/wt")
    }

    // MARK: - Header parsing

    @Test func parsesHttpEndpointHeader() {
        let meta = RunScriptMetadata.parse(
            fileName: "web.sh",
            contents: "# alas-name: Web\n# alas-url: http://localhost:3000/app\n"
        )
        #expect(meta.endpoint == URL(string: "http://localhost:3000/app"))
    }

    @Test func ignoresNonHttpOrMalformedEndpointHeaders() {
        for value in ["file:///tmp/x", "localhost:3000", "not a url", "ftp://example.test"] {
            let meta = RunScriptMetadata.parse(fileName: "web.sh", contents: "# alas-url: \(value)\n")
            #expect(meta.endpoint == nil, "expected \(value) to be rejected")
        }
    }

    /// A bad endpoint header must never hide the script from the Run tab.
    @Test func malformedEndpointStillYieldsAUsableScript() {
        let meta = RunScriptMetadata.parse(
            fileName: "web.sh",
            contents: "# alas-name: Web\n# alas-url: nonsense\n# alas-cwd: apps/web\n"
        )
        #expect(meta.displayName == "Web")
        #expect(meta.cwd == "apps/web")
        #expect(meta.endpoint == nil)
    }

    // MARK: - Open policy

    @Test func localRunOpensItsEndpointDirectly() {
        let url = URL(string: "http://localhost:3000")!
        #expect(RunEndpointPolicy.action(for: url, target: target(host: nil)) == .open(url))
    }

    /// The dangerous case: an SSH run whose URL says "localhost" would open a
    /// completely unrelated service on the user's own machine.
    @Test func remoteRunRefusesToOpenALoopbackURL() {
        for host in ["localhost", "127.0.0.1", "127.0.0.2", "0.0.0.0", "[::1]"] {
            let url = URL(string: "http://\(host):3000")!
            #expect(
                RunEndpointPolicy.action(for: url, target: target(host: "devbox"))
                    == .blockedRemoteLoopback(host: "devbox", url: url),
                "expected \(host) to be blocked for a remote run"
            )
        }
    }

    @Test func remoteRunOpensAnAddressableURL() {
        let url = URL(string: "https://devbox.internal:8443/app")!
        #expect(RunEndpointPolicy.action(for: url, target: target(host: "devbox")) == .open(url))
    }

    // MARK: - Port probe

    @Test func portProbeDetectsAListenerWithoutTouchingIt() throws {
        let listener = try Listener()
        defer { listener.close() }
        #expect(RunPortProbe.isLocalPortInUse(listener.port))
        // Observing the collision must leave the other socket alone: it is
        // still open and still holding the port.
        #expect(listener.isOpen)
        #expect(RunPortProbe.isLocalPortInUse(listener.port))
    }

    @Test func portProbeRejectsPortsOutsideTheValidRange() {
        #expect(!RunPortProbe.isLocalPortInUse(0))
        #expect(!RunPortProbe.isLocalPortInUse(-1))
        #expect(!RunPortProbe.isLocalPortInUse(70_000))
    }
}

/// A real listening socket on an OS-assigned port, so the probe is exercised
/// against the same condition a dev server produces.
private final class Listener {
    let descriptor: Int32
    let port: Int

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ListenerError.failed }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw ListenerError.failed
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(fd)
            throw ListenerError.failed
        }
        descriptor = fd
        port = Int(UInt16(bigEndian: assigned.sin_port))
    }

    var isOpen: Bool {
        fcntl(descriptor, F_GETFL) != -1
    }

    func close() {
        Darwin.close(descriptor)
    }

    enum ListenerError: Error { case failed }
}
