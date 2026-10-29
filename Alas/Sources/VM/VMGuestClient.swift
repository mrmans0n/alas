import AlasComputerUseKit
import AlasCore
import Foundation
import os

/// A byte stream to the in-guest helper.
protocol VMGuestTransport: Sendable {
    func send(_ data: Data) async throws
    /// The next bytes the guest sent; nil once the stream is closed.
    func receive() async throws -> Data?
    func close()
}

/// What the guest helper reported when the client connected.
struct VMGuestHello: Equatable, Sendable {
    var guestVersion: String
    var accessibility: Bool
    var screenRecording: Bool
    /// The helper's `VMGuestProtocol.revision`; another value than this build's means it is out of date.
    var protocolRevision: Int
}

/// Talks to the Alas VM Guest helper over one connection at a time, multiplexing requests by id.
/// It connects and says hello on first use, and again after the connection drops.
actor VMGuestClient {
    /// Every way a call can fail before the guest answers it, with the text agents see.
    enum Failure: LocalizedError, Equatable {
        case helperMissing
        case stopped
        case outdated
        case cancelled
        case malformed

        var message: String {
            switch self {
            case .helperMissing:
                "computer_vm_helper_missing: The Alas VM Guest helper isn't running in this VM. Install it with Customize base image."
            case .stopped:
                "computer_vm_stopped: The VM stopped or its helper disconnected."
            case .outdated:
                "computer_vm_helper_outdated: The Alas VM Guest helper in this VM is out of date. Reinstall it with Customize base image."
            case .cancelled:
                "computer_cancelled: The call was cancelled."
            case .malformed:
                "computer_vm_malformed: The Alas VM Guest helper sent a reply Alas couldn't read."
            }
        }

        var errorDescription: String? { message }
    }

    /// One established connection and the requests waiting on it.
    private final class Connection {
        let token: UInt64
        let transport: VMGuestTransport
        var hello: VMGuestHello?
        var helloWaiter: CheckedContinuation<VMGuestHello, Error>?
        /// Requests sent on this connection, by id. A reply that arrives before its caller starts
        /// waiting is parked as `.answered`.
        var pending: [UInt64: Pending] = [:]
        var lost = false

        init(token: UInt64, transport: VMGuestTransport) {
            self.token = token
            self.transport = transport
        }
    }

    private enum Pending {
        case waiting(CheckedContinuation<VMGuestMessage, Error>?)
        case answered(VMGuestMessage)
    }

    private let connect: @Sendable () async throws -> VMGuestTransport
    private let hostVersion: String
    private let retryWindow: Duration
    private let retryInterval: Duration
    private let clock: any Clock<Duration>
    private var connection: Connection?
    /// The connect and hello every first caller shares.
    private var establishing: Task<Void, Error>?
    private var nextToken: UInt64 = 0
    private var nextID: UInt64 = 0
    private var closed = false

    private static let log = Logger(subsystem: "io.nlopez.alas", category: "vm-guest-client")

    init(
        connect: @escaping @Sendable () async throws -> VMGuestTransport,
        hostVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        retryWindow: Duration = .seconds(5),
        retryInterval: Duration = .milliseconds(250),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.connect = connect
        self.hostVersion = hostVersion
        self.retryWindow = retryWindow
        self.retryInterval = retryInterval
        self.clock = clock
    }

    // MARK: - Calls

    /// The helper's version and grants, connecting first if needed. Does not refuse an out-of-date
    /// helper, so callers can show which version it is.
    func hello() async throws -> VMGuestHello {
        try await connected().hello!
    }

    func perform(_ command: ComputerUseCommand, sessionID: String) async -> AlasCLIResponse {
        let request: Data
        do {
            request = try command.requestJSON()
        } catch {
            return .error("computer_malformed: \(error.localizedDescription)")
        }
        do {
            let reply = try await call { .command(id: $0, sessionID: sessionID, request: request) }
            guard case let .response(_, body) = reply, let response = try? AlasCLIResponse.decode(body) else {
                throw Failure.malformed
            }
            return response
        } catch {
            return .error((error as? Failure ?? .stopped).message)
        }
    }

    /// Runs `command` in the guest's shell. The guest bounds it by `timeoutSeconds`.
    func run(_ command: String, timeoutSeconds: Int) async throws -> VMGuestRunResult {
        let reply = try await call { .run(id: $0, command: command, timeoutSeconds: timeoutSeconds) }
        guard case let .runResult(_, exitCode, stdout, stderr, truncated, timedOut) = reply else { throw Failure.malformed }
        return VMGuestRunResult(exitCode: exitCode, stdout: stdout, stderr: stderr, truncated: truncated, timedOut: timedOut)
    }

    /// Tells the guest about a session's lifecycle. Sent only over a live connection: when the
    /// connection dropped, the guest already ended its sessions.
    func lifecycle(_ event: VMGuestLifecycleEvent, sessionID: String) async {
        guard let connection, !connection.lost, connection.hello != nil else { return }
        do {
            try await connection.transport.send(VMGuestFramer.frame(.lifecycle(sessionID: sessionID, event: event)))
        } catch {
            Self.log.error("sending \(event.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drops the connection and fails every call in flight. Later calls fail at once.
    func close() {
        closed = true
        establishing?.cancel()
        establishing = nil
        if let connection { lose(connection) }
    }

    // MARK: - Requests

    private func call(_ message: (UInt64) -> VMGuestMessage) async throws -> VMGuestMessage {
        let connection = try await connected()
        guard connection.hello?.protocolRevision == VMGuestProtocol.revision else { throw Failure.outdated }
        guard !Task.isCancelled else { throw Failure.cancelled }
        nextID += 1
        let id = nextID
        connection.pending[id] = .waiting(nil)
        do {
            try await connection.transport.send(VMGuestFramer.frame(message(id)))
        } catch {
            connection.pending[id] = nil
            throw Failure.stopped
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                switch connection.pending[id] {
                case let .answered(reply):
                    connection.pending[id] = nil
                    continuation.resume(returning: reply)
                case .waiting:
                    connection.pending[id] = .waiting(continuation)
                case nil:
                    // The connection dropped while the request was being sent.
                    continuation.resume(throwing: Failure.stopped)
                }
            }
        } onCancel: { [token = connection.token] in
            Task { await self.cancel(id, token: token) }
        }
    }

    /// Asks the guest to stop a call; its answer still arrives as the call's reply.
    private func cancel(_ id: UInt64, token: UInt64) async {
        guard let connection, connection.token == token, connection.pending[id] != nil else { return }
        do {
            try await connection.transport.send(VMGuestFramer.frame(.cancel(id: id)))
        } catch {
            Self.log.error("sending cancel failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Connection

    private func connected() async throws -> Connection {
        guard !closed else { throw Failure.stopped }
        // A connection still saying hello is not ready; its callers wait on `establishing`.
        if let connection, !connection.lost, connection.hello != nil { return connection }
        do {
            if let establishing {
                try await establishing.value
            } else {
                let task = Task { try await self.establish() }
                establishing = task
                defer { if establishing == task { establishing = nil } }
                try await task.value
            }
        } catch {
            // `close()` cancels a connect in progress; that is the VM stopping, not a cancelled call.
            throw closed ? Failure.stopped : error
        }
        guard !closed, let connection, !connection.lost, connection.hello != nil else { throw Failure.stopped }
        return connection
    }

    /// Connects and says hello; the result becomes `connection`.
    private func establish() async throws {
        let transport = try await connectWithRetry()
        guard !closed else {
            transport.close()
            throw Failure.stopped
        }
        nextToken += 1
        let connection = Connection(token: nextToken, transport: transport)
        self.connection = connection
        Task { await self.read(connection) }
        do {
            try await transport.send(VMGuestFramer.frame(.hello(hostVersion: hostVersion)))
        } catch {
            lose(connection)
            throw Failure.stopped
        }
        let hello = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<VMGuestHello, Error>) in
            if connection.lost {
                continuation.resume(throwing: Failure.stopped)
            } else {
                connection.helloWaiter = continuation
            }
        }
        if hello.protocolRevision != VMGuestProtocol.revision {
            Self.log.error("guest helper \(hello.guestVersion, privacy: .public) speaks revision \(hello.protocolRevision, privacy: .public), this build \(VMGuestProtocol.revision, privacy: .public)")
        }
    }

    /// The helper may still be starting: keeps trying for `retryWindow`.
    private func connectWithRetry() async throws -> VMGuestTransport {
        var waited = Duration.zero
        while true {
            do {
                return try await connect()
            } catch {
                guard waited < retryWindow else {
                    Self.log.error("connecting to the guest helper failed: \(error.localizedDescription, privacy: .public)")
                    throw Failure.helperMissing
                }
            }
            do {
                try await clock.sleep(for: retryInterval)
            } catch {
                throw Failure.cancelled
            }
            waited += retryInterval
        }
    }

    private func read(_ connection: Connection) async {
        var framer = VMGuestFramer()
        while true {
            let data: Data?
            do {
                data = try await connection.transport.receive()
            } catch {
                data = nil
            }
            guard let data else { break }
            let output = framer.append(data)
            if output.malformedFrames > 0 {
                Self.log.error("skipped \(output.malformedFrames, privacy: .public) malformed frame(s) from the guest")
            }
            for message in output.messages { deliver(message, on: connection) }
        }
        lose(connection)
    }

    private func deliver(_ message: VMGuestMessage, on connection: Connection) {
        switch message {
        case let .helloReply(guestVersion, protocolRevision, accessibility, screenRecording):
            let hello = VMGuestHello(
                guestVersion: guestVersion, accessibility: accessibility, screenRecording: screenRecording,
                protocolRevision: protocolRevision)
            connection.hello = hello
            connection.helloWaiter?.resume(returning: hello)
            connection.helloWaiter = nil
        case let .response(id, _), let .runResult(id, _, _, _, _, _):
            switch connection.pending[id] {
            case let .waiting(continuation?):
                connection.pending[id] = nil
                continuation.resume(returning: message)
            case .waiting(nil):
                connection.pending[id] = .answered(message)
            case .answered, nil:
                Self.log.error("ignoring a reply to unknown request \(id, privacy: .public)")
            }
        case .hello, .command, .cancel, .lifecycle, .run:
            Self.log.error("ignoring a host-to-guest message from the guest")
        }
    }

    /// Fails everything waiting on `connection` and forgets it, so the next call reconnects.
    private func lose(_ connection: Connection) {
        guard !connection.lost else { return }
        connection.lost = true
        connection.transport.close()
        if self.connection === connection { self.connection = nil }
        connection.helloWaiter?.resume(throwing: Failure.stopped)
        connection.helloWaiter = nil
        let pending = connection.pending
        connection.pending = [:]
        for case let .waiting(continuation?) in pending.values {
            continuation.resume(throwing: Failure.stopped)
        }
    }
}
