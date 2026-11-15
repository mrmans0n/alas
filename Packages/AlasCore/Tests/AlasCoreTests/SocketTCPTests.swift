import Foundation
import Synchronization
import Testing
import AlasFoundation
@testable import AlasHostCore

/// The socket transport Linux hosts serve over, driven through real loopback sockets.
@Suite(.timeLimit(.minutes(1)))
struct SocketTCPTests {
    @Test func sendsArriveInOrderAndFinishEndsTheStream() async throws {
        let pair = try await Pair.connect()
        defer { pair.close() }
        for chunk in ["one ", "two ", "three"] {
            pair.client.send(Data(chunk.utf8)) { #expect($0 == nil) }
        }
        pair.client.finish {}
        #expect(try await pair.server.readToEnd(on: pair.queue) == Data("one two three".utf8))
    }

    @Test func sendingToAClosedPeerFailsInsteadOfKillingTheProcess() async throws {
        let pair = try await Pair.connect()
        defer { pair.close() }
        pair.server.cancel()
        // The first write can still land in the socket buffer; keep writing until one fails.
        let failed = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for _ in 0..<200 {
                    let error = await withCheckedContinuation { done in
                        pair.client.send(Data(repeating: 0, count: 64 * 1024)) { done.resume(returning: $0) }
                    }
                    if error != nil { return true }
                }
                return false
            }
            return try await group.next()!
        }
        #expect(failed)
    }

    @Test func cancellingAnAcceptedStreamBeforeStartClosesItsSocket() throws {
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, streamSocketType, 0, &fds) == 0)
        defer { Foundation.close(fds[1]) }
        SocketTCPStream(fd: fds[0]).cancel()
        #expect(fcntl(fds[0], F_GETFD) == -1)
    }

    @Test func aRefusedConnectionReportsFailure() async throws {
        let queue = DispatchQueue(label: "socket-tcp-tests")
        // Port 1 refuses at once.
        let stream = SocketTCPStream(host: "127.0.0.1", port: 1)
        let state = await withCheckedContinuation { done in
            let reported = Mutex(false)
            stream.start(queue: queue) { state in
                let first = reported.withLock { reported in
                    defer { reported = true }
                    return !reported
                }
                if first { done.resume(returning: state) }
            }
        }
        guard case .failed = state else {
            Issue.record("expected failure, got \(state)")
            return
        }
    }
}

/// A listener, and a client connected to it, on loopback.
private struct Pair {
    let queue: DispatchQueue
    let listener: SocketTCPListener
    let client: SocketTCPStream
    let server: any TCPStream

    static func connect() async throws -> Pair {
        let queue = DispatchQueue(label: "socket-tcp-tests")
        let listener = SocketTCPListener(host: .loopbackV4, port: 0)
        let accepted = AsyncStream<any TCPStream>.makeStream()
        let ready = AsyncStream<UInt16>.makeStream()
        listener.start(queue: queue, onState: { state in
            if case .ready(let port) = state { ready.continuation.yield(port) }
        }, onConnection: { stream in
            stream.start(queue: queue) { _ in }
            accepted.continuation.yield(stream)
        })
        var ports = ready.stream.makeAsyncIterator()
        let port = try #require(await ports.next())
        let client = SocketTCPStream(host: "127.0.0.1", port: port)
        client.start(queue: queue) { _ in }
        var connections = accepted.stream.makeAsyncIterator()
        let server = try #require(await connections.next())
        return Pair(queue: queue, listener: listener, client: client, server: server)
    }

    func close() {
        client.cancel()
        server.cancel()
        listener.cancel()
    }
}

private extension TCPStream {
    func readToEnd(on queue: DispatchQueue) async throws -> Data {
        var data = Data()
        while true {
            let (chunk, isComplete, error): (Data?, Bool, Error?) = await withCheckedContinuation { done in
                receive(maximumLength: 4096) { done.resume(returning: ($0, $1, $2)) }
            }
            if let error { throw error }
            data.append(chunk ?? Data())
            if isComplete { return data }
        }
    }
}
