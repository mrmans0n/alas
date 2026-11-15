import Foundation
import Network

enum AndroidSocketError: Error, Equatable {
    case closed
    case failed(String)
}

/// A TCP connection to an `adb forward` port. Its callbacks run on one serial
/// queue, which the pumps reading it rely on.
final class AndroidSocket: @unchecked Sendable {
    private let connection: NWConnection
    static let queue = DispatchQueue(label: "io.nlopez.alas.android-socket")

    private init(_ connection: NWConnection) {
        self.connection = connection
    }

    static func open(port: UInt16) async throws -> AndroidSocket {
        guard let endpoint = NWEndpoint.Port(rawValue: port) else { throw AndroidSocketError.failed("No port.") }
        let connection = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = ResumeOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(returning: ())
                case .failed(let error), .waiting(let error):
                    once.resume(throwing: AndroidSocketError.failed(error.localizedDescription))
                case .cancelled: once.resume(throwing: AndroidSocketError.closed)
                default: break
                }
            }
            connection.start(queue: queue)
        }
        return AndroidSocket(connection)
    }

    /// Opens a connection and reads the server's dummy byte; nil when adb
    /// accepted but nothing listens on the device yet.
    static func openAnswered(port: UInt16) async throws -> AndroidSocket? {
        let socket = try await open(port: port)
        do {
            _ = try await socket.read(exactly: 1)
            return socket
        } catch AndroidSocketError.closed {
            socket.close()
            return nil
        }
    }

    /// Whatever arrives next, up to 64 KB, on the socket's queue.
    func receive(_ handler: @escaping @Sendable (Result<Data, AndroidSocketError>) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                handler(.success(data))
            } else if let error {
                handler(.failure(.failed(error.localizedDescription)))
            } else {
                handler(.failure(.closed))
            }
            _ = isComplete
        }
    }

    func read(exactly count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: AndroidSocketError.failed(error.localizedDescription))
                } else {
                    continuation.resume(throwing: AndroidSocketError.closed)
                }
            }
        }
    }

    func write(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        connection.cancel()
    }
}

enum AndroidStreamError: Error, Equatable, LocalizedError {
    case serverDidNotStart

    var errorDescription: String? { "The Android screen server didn't start." }
}

enum AndroidStreamConnector {
    /// `adb forward` accepts a connection before the server listens, then
    /// hangs up; keep connecting until the server answers (10 s by default).
    static func connect<Socket>(
        isolation: isolated (any Actor)? = #isolation,
        attempts: Int = 100,
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) },
        attempt: () async throws -> Socket?
    ) async throws -> Socket {
        for _ in 0..<attempts {
            if let socket = try? await attempt() { return socket }
            try await pause()
        }
        throw AndroidStreamError.serverDidNotStart
    }
}
