import Foundation
import Testing
import Darwin
@testable import Alas

@MainActor
struct RemoteAppStateAccessTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    @Test func appStateRemoteServerPublishesAndRefreshesConfiguredAccessState() async throws {
        let port = try availableTCPPort()
        let state = AppState(store: MemoryStore())
        state.config.remote.enabled = true
        state.config.remote.port = port
        state.config.remote.allowedHosts = ["custom-a.example"]
        state.syncRemoteServer()
        defer {
            state.config.remote.enabled = false
            state.syncRemoteServer()
        }

        for _ in 0..<50 where state.remotePort != port {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(state.remotePort == port)
        #expect(state.remoteAdvertisedAddresses.contains {
            $0.host == "custom-a.example" && $0.port == port
        })
        #expect(try await statusCode(port: port, host: "custom-a.example", path: "/health") == 200)

        state.config.remote.allowedHosts = ["custom-b.example"]
        state.syncRemoteServer()

        #expect(state.remoteAdvertisedAddresses.contains {
            $0.host == "custom-b.example" && $0.port == port
        })
        #expect(!state.remoteAdvertisedAddresses.contains { $0.host == "custom-a.example" })
        #expect(try await statusCode(port: port, host: "custom-b.example", path: "/health") == 200)
        #expect(try await statusCode(port: port, host: "custom-a.example", path: "/health") == 403)

        let infoData = try await data(port: port, host: "custom-b.example", path: "/remote-info")
        let snapshot = try JSONDecoder().decode(RemoteDiagnosticsSnapshot.self, from: infoData)
        #expect(snapshot.addresses == state.remoteAdvertisedAddresses)

        state.config.remote.enabled = false
        state.syncRemoteServer()
        #expect(state.remotePort == nil)
        #expect(state.remoteAdvertisedAddresses.isEmpty)
    }

    private func statusCode(port: UInt16, host: String, path: String) async throws -> Int? {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.setValue(host, forHTTPHeaderField: "Host")
        let (_, resp) = try await URLSession.shared.data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode
    }

    private func data(port: UInt16, host: String, path: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.setValue(host, forHTTPHeaderField: "Host")
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    private func availableTCPPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return UInt16(bigEndian: bound.sin_port)
    }
}
