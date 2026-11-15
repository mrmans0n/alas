import Foundation
import Testing
@testable import AlasRemoteKit

@Suite struct RemoteBoundedFetchTests {
    /// A caller cancelled as the fetch starts makes the delegate report the
    /// cancelled task before `run()` waits for it. That result must still end
    /// the fetch: the server here never answers, so a dropped result waits
    /// out the five-minute request timeout, well past the time limit.
    @Test(.timeLimit(.minutes(1)))
    func aResultBeforeTheFetchWaitsStillEndsIt() async throws {
        let server = try SilentServer()
        defer { server.close() }
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!, timeoutInterval: 300)
        let fetch = BoundedDataTask(request: request, configuration: .ephemeral, maxBytes: 16)
        fetch.urlSession(.shared, task: URLSession.shared.dataTask(with: request), didCompleteWithError: URLError(.cancelled))
        await #expect(throws: URLError(.cancelled)) { try await fetch.run() }
    }
}

/// Accepts connections into its backlog and never answers.
private struct SilentServer {
    let fd: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && listen(fd, 8) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRNOTAVAIL) }
        self.fd = fd
        port = UInt16(bigEndian: address.sin_port)
    }

    func close() {
        _ = Foundation.close(fd)
    }
}
