import Foundation
import Network
import Synchronization
import Testing
import AlasCore

struct PeerPortForwardTests {
    /// Nil is a stale or stopped run; `0.0.0.0` would reach the listener but
    /// isn't a loopback endpoint.
    @Test(arguments: [nil, "0.0.0.0"])
    func aStaleOrStoppedRunIsRefusedWithoutDialling(endpointHost: String?) async throws {
        let server = try await EchoServer.start()
        defer { server.stop() }
        let events = EventLog()
        let port = server.port
        let host = PeerPortForwardHost(resolve: { _ in endpointHost.map { ($0, port) } }, send: { events.append($1) })
        let stream = UUID()

        host.receive(.open(stream: stream, runID: "stale"), from: UUID())

        try await eventually { events.all.contains(.refused(stream: stream, message: PeerPortForwardHost.notRunningMessage)) }
        #expect(server.accepted == 0)
    }

    /// `localhost` is dialled as declared and reaches the IPv4 listener.
    @Test(arguments: ["127.0.0.1", "localhost"])
    func aPeerExceedingItsWindowLosesTheStream(endpointHost: String) async throws {
        let server = try await EchoServer.start()
        defer { server.stop() }
        let events = EventLog()
        let port = server.port
        let host = PeerPortForwardHost(resolve: { _ in (endpointHost, port) }, send: { events.append($1) })
        let connection = UUID()
        let stream = UUID()

        host.receive(.open(stream: stream, runID: "run"), from: connection)
        try await eventually { events.all.contains(.opened(stream: stream)) }

        // Never returning credit stalls the echo, so the host's writes stall
        // and the Mac's unacknowledged bytes outgrow its window.
        let chunk = Data(repeating: 7, count: PeerPortForwardLimits().maxChunk)
        for _ in 0..<4096 where !events.all.contains(.closed(stream: stream)) {
            host.receive(.data(stream: stream, bytes: chunk), from: connection)
            await Task.yield()
        }
        try await eventually { events.all.contains(.closed(stream: stream)) }
    }

    @Test(arguments: [
        ("http://localhost:3000", true),
        ("http://127.0.0.1:5173/x", true),
        ("http://[::1]:8080", true),
        ("http://dev.example:3000", false),
        ("http://0.0.0.0:3000", false),
    ])
    func loopbackEndpointsAreRecognised(url: String, isLoopback: Bool) throws {
        #expect(PeerPortForwardEndpoint.isLoopback(try #require(URL(string: url))) == isLoopback)
    }
}

private final class EventLog: Sendable {
    private let events = Mutex<[PeerPortForwardEvent]>([])
    var all: [PeerPortForwardEvent] { events.withLock { $0 } }
    func append(_ event: PeerPortForwardEvent) { events.withLock { $0.append(event) } }
}

/// A loopback TCP echo server that reads only once its previous echo was
/// written, so it stops reading when its peer stops reading.
private final class EchoServer: Sendable {
    private let listener: NWListener
    private let acceptedCount = Mutex(0)
    private let queue = DispatchQueue(label: "PeerPortForwardTests.echo")

    var accepted: Int { acceptedCount.withLock { $0 } }
    var port: Int { Int(listener.port?.rawValue ?? 0) }

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start() async throws -> EchoServer {
        let server = try EchoServer()
        server.listener.newConnectionHandler = { [weak server] connection in
            guard let server else { return connection.cancel() }
            server.acceptedCount.withLock { $0 += 1 }
            connection.start(queue: server.queue)
            echo(connection)
        }
        server.listener.start(queue: server.queue)
        try await eventually { server.port != 0 }
        return server
    }

    func stop() { listener.cancel() }

    private static func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            guard error == nil, !isComplete, let data else { return connection.cancel() }
            connection.send(content: data, completion: .contentProcessed { error in
                guard error == nil else { return connection.cancel() }
                echo(connection)
            })
        }
    }
}
