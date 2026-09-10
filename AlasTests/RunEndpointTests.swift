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
        for host in ["localhost", "localhost.", "127.0.0.1", "127.0.0.2", "127.1", "2130706433", "0177.0.0.1", "0x7f000001", "0.0.0.0", "0", "[::1]", "[0:0::1]", "[0000::0001]", "[::1%25lo0]", "[::ffff:127.0.0.1]", "[::ffff:7f00:1]", "[::]", "[0:0::]", "[0000:0000:0000:0000:0000:0000:0000:0000]"] {
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

    @Test func remoteRunDoesNotTreatDnsNamesStartingWith127AsLoopback() {
        let url = URL(string: "https://127.example.internal:8443/app")!
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

    @Test func portProbeDetectsIPv6OnlyListener() throws {
        let listener = try IPv6OnlyListener()
        defer { listener.close() }

        #expect(RunPortProbe.isLocalPortInUse(listener.port))
        #expect(listener.isOpen)
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

private final class IPv6OnlyListener {
    let descriptor: Int32
    let port: Int

    init() throws {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Listener.ListenerError.failed }
        var only: Int32 = 1
        guard setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(fd)
            throw Listener.ListenerError.failed
        }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = 0
        address.sin6_addr = in6addr_loopback
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw Listener.ListenerError.failed
        }
        var assigned = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(fd)
            throw Listener.ListenerError.failed
        }
        descriptor = fd
        port = Int(UInt16(bigEndian: assigned.sin6_port))
    }

    var isOpen: Bool {
        fcntl(descriptor, F_GETFL) != -1
    }

    func close() {
        Darwin.close(descriptor)
    }
}
