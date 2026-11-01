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
    /// `"linux"` for the Linux helper; nil from a macOS helper, which never sends it.
    var guestKind: String? = nil
    /// What the helper can do, such as `"run"`; nil from a macOS helper, which can do everything.
    var capabilities: [String]? = nil

    /// The capability a Linux helper lists once it answers `computer_*` calls.
    static let computerUseCapability = "computer_use"
}

/// Talks to the Alas VM Guest helper over one connection at a time, multiplexing requests by id.
/// It connects and says hello on first use, and again after the connection drops.
actor VMGuestClient {
    /// Every way a call can fail before the guest answers it, with the text agents see.
    enum Failure: LocalizedError, Equatable {
        case helperMissing
        case helperUnresponsive
        case stopped
        case outdated
        case cancelled
        case malformed

        var message: String { message(for: .macOS) }

        /// The text for a call to the helper of a `guest` VM. Codes are the same for both guests;
        /// only the remedies differ.
        func message(for guest: VMGuestOS) -> String {
            if guest == .linux, let linux = linuxMessage { return linux }
            return switch self {
            case .helperMissing:
                "computer_vm_helper_missing: The Alas VM Guest helper isn't running in this VM. If the VM just started, wait for it to log in and try again. Otherwise, in the VM open My Shared Files › helper › Install Alas VM Guest. Customize base image puts it in new VMs. Or click Update helper in the VM tab."
            case .helperUnresponsive:
                "computer_vm_helper_missing: The Alas VM Guest helper isn't responding in this VM. Restart the VM, or reinstall it from My Shared Files › helper › Install Alas VM Guest in the VM. Or click Update helper in the VM tab."
            case .stopped:
                "computer_vm_stopped: The VM stopped or its helper disconnected."
            case .outdated:
                "computer_vm_helper_outdated: The Alas VM Guest helper in this VM doesn't match this version of Alas. In the VM, open My Shared Files › helper › Install Alas VM Guest to update it. Or click Update helper in the VM tab."
            case .cancelled:
                "computer_cancelled: The call was cancelled."
            case .malformed:
                "computer_vm_malformed: The Alas VM Guest helper sent a reply Alas couldn't read."
            }
        }

        /// Remedies a Linux guest can take: its helper is installed at first boot, and Update
        /// helper reinstalls it only through a helper that still answers `run`.
        private var linuxMessage: String? {
            switch self {
            case .helperMissing:
                "computer_vm_helper_missing: The Alas VM Guest helper isn't running in this Linux VM. If the VM just started, wait for Ubuntu to finish starting and try again. Otherwise, restart the VM."
            case .helperUnresponsive:
                "computer_vm_helper_missing: The Linux VM's helper isn't answering yet. Wait for Ubuntu to finish starting, or restart the VM."
            case .outdated:
                "computer_vm_helper_outdated: The Alas VM Guest helper in this Linux VM doesn't match this version of Alas. In the VM, run `sudo install -m 0755 /mnt/alas/helper/alas-vm-guest-linux /usr/local/bin/alas-vm-guest`, then `systemctl --user restart alas-vm-guest`."
            case .stopped, .cancelled, .malformed:
                nil
            }
        }

        var errorDescription: String? { message }
    }

    /// One established connection and the requests waiting on it.
    private final class Connection {
        let token: UInt64
        let transport: VMGuestTransport
        /// The latest `helloReply`; nil until the handshake's.
        var hello: VMGuestHello?
        /// Hellos sent and answered on this connection. The helper answers them in order, so
        /// the nth reply answers the nth hello: the handshake's is 1.
        var hellosSent: UInt64 = 0
        var hellosAnswered: UInt64 = 0
        var helloWaiters: [UInt64: CheckedContinuation<VMGuestHello, Error>] = [:]
        /// Replies that arrived before their sender started waiting.
        var helloReplies: [UInt64: VMGuestHello] = [:]
        /// Later hellos whose sender gave up waiting; their late replies are dropped.
        var abandonedHellos: Set<UInt64> = []
        /// The helper did not answer the handshake's `hello` within `helloTimeout`.
        var helloTimedOut = false
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
    private let helloTimeout: Duration
    /// The client's clock: connect retries and the hello timeout wait through it.
    private let sleep: @Sendable (Duration) async throws -> Void
    private var connection: Connection?
    /// The connect and hello every first caller shares. Callers wait in `establishWaiters`, so one
    /// of them giving up does not cancel it for the others.
    private var establishing: Task<Void, Never>?
    private var establishWaiters: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var nextWaiter: UInt64 = 0
    private var nextToken: UInt64 = 0
    private var nextID: UInt64 = 0
    private var closed = false

    private static let log = Logger(subsystem: "io.nlopez.alas", category: "vm-guest-client")

    init(
        connect: @escaping @Sendable () async throws -> VMGuestTransport,
        hostVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        retryWindow: Duration = .seconds(5),
        retryInterval: Duration = .milliseconds(250),
        helloTimeout: Duration = .seconds(5),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.connect = connect
        self.hostVersion = hostVersion
        self.retryWindow = retryWindow
        self.retryInterval = retryInterval
        self.helloTimeout = helloTimeout
        self.sleep = sleep
    }

    // MARK: - Calls

    /// The helper's version and grants, connecting first if needed. Does not refuse an out-of-date
    /// helper, so callers can show which version it is.
    func hello() async throws -> VMGuestHello {
        try await connected().hello!
    }

    /// Like `hello()`, but asks the helper again on the established connection, so grants given
    /// since it connected show. Refreshes what `hello()` returns.
    func status() async throws -> VMGuestHello {
        try await sayHello(on: connected())
    }

    /// `guest` picks the remedies in a failure's text.
    func perform(_ command: ComputerUseCommand, sessionID: String, guest: VMGuestOS = .macOS) async -> AlasCLIResponse {
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
            return .error((error as? Failure ?? .stopped).message(for: guest))
        }
    }

    /// Runs `command` in the guest's shell. The guest bounds it by `timeoutSeconds`.
    func run(_ command: String, timeoutSeconds: Int) async throws -> VMGuestRunResult {
        let reply = try await call { .run(id: $0, command: command, timeoutSeconds: timeoutSeconds) }
        guard case let .runResult(_, exitCode, stdout, stderr, truncated, timedOut) = reply else { throw Failure.malformed }
        return VMGuestRunResult(exitCode: exitCode, stdout: stdout, stderr: stderr, truncated: truncated, timedOut: timedOut)
    }

    /// Asks a Linux guest to power off over a live connection, and returns at once whether it
    /// was asked: the connection drops as the guest goes down, so the reply may never come, and
    /// the caller bounds the shutdown itself.
    func requestPoweroff() -> Bool {
        guard !closed, let connection, !connection.lost, connection.hello != nil else { return false }
        Task { _ = try? await self.run(Self.poweroffCommand, timeoutSeconds: 60) }
        return true
    }

    static let poweroffCommand = "sudo systemctl poweroff"

    /// Tells the guest about a session's lifecycle. Sent only over a live connection: when the
    /// connection dropped, the guest already ended its sessions. Returns whether it was sent.
    @discardableResult
    func lifecycle(_ event: VMGuestLifecycleEvent, sessionID: String) async -> Bool {
        guard let connection, !connection.lost, connection.hello != nil else { return false }
        do {
            try await connection.transport.send(VMGuestFramer.frame(.lifecycle(sessionID: sessionID, event: event)))
            return true
        } catch {
            Self.log.error("sending \(event.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Drops the connection and fails every call in flight. Later calls fail at once.
    func close() {
        closed = true
        establishing?.cancel()
        establishing = nil
        finishEstablishing(.failure(Failure.stopped))
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
        if establishing == nil {
            establishing = Task {
                let result: Result<Void, Error>
                do {
                    try await self.establish()
                    result = .success(())
                } catch {
                    result = .failure(error)
                }
                await self.establishFinished(result)
            }
        }
        nextWaiter += 1
        let waiter = nextWaiter
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: Failure.cancelled)
                } else {
                    establishWaiters[waiter] = continuation
                }
            }
        } onCancel: {
            Task { await self.stopWaiting(waiter) }
        }
        guard !closed, let connection, !connection.lost, connection.hello != nil else { throw Failure.stopped }
        return connection
    }

    private func establishFinished(_ result: Result<Void, Error>) {
        establishing = nil
        // `close()` cancels a connect in progress; that is the VM stopping, not a cancelled call.
        finishEstablishing(closed ? .failure(Failure.stopped) : result)
    }

    private func finishEstablishing(_ result: Result<Void, Error>) {
        let waiters = establishWaiters
        establishWaiters = [:]
        for waiter in waiters.values { waiter.resume(with: result) }
    }

    /// A cancelled caller stops waiting; the connect goes on for the others.
    private func stopWaiting(_ waiter: UInt64) {
        establishWaiters.removeValue(forKey: waiter)?.resume(throwing: Failure.cancelled)
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
        let hello = try await sayHello(on: connection)
        if hello.protocolRevision != VMGuestProtocol.revision {
            Self.log.error("guest helper \(hello.guestVersion, privacy: .public) speaks revision \(hello.protocolRevision, privacy: .public), this build \(VMGuestProtocol.revision, privacy: .public)")
        }
    }

    /// Sends a `hello` on `connection` and waits up to `helloTimeout` for its reply.
    private func sayHello(on connection: Connection) async throws -> VMGuestHello {
        connection.hellosSent += 1
        let number = connection.hellosSent
        let timeout = Task { [sleep, helloTimeout, token = connection.token] in
            guard (try? await sleep(helloTimeout)) != nil else { return }
            await self.helloTimedOut(token, number: number)
        }
        defer { timeout.cancel() }
        do {
            try await connection.transport.send(VMGuestFramer.frame(.hello(hostVersion: hostVersion)))
        } catch {
            lose(connection)
            throw connection.helloTimedOut ? Failure.helperUnresponsive : Failure.stopped
        }
        // The reader may have taken the reply while the hello was being sent.
        return try await withCheckedThrowingContinuation { continuation in
            if let hello = connection.helloReplies.removeValue(forKey: number) {
                continuation.resume(returning: hello)
            } else if connection.lost {
                continuation.resume(throwing: connection.helloTimedOut ? Failure.helperUnresponsive : Failure.stopped)
            } else if connection.abandonedHellos.contains(number) {
                continuation.resume(throwing: Failure.helperUnresponsive)
            } else {
                connection.helloWaiters[number] = continuation
            }
        }
    }

    /// A hello the helper did not answer in time. Without an answer to the handshake the
    /// connection is useless; a later hello just fails, leaving calls on the connection running.
    private func helloTimedOut(_ token: UInt64, number: UInt64) {
        guard let connection, connection.token == token, !connection.lost,
              connection.hellosAnswered < number else { return }
        Self.log.error("the guest helper didn't answer hello within \(self.helloTimeout, privacy: .public)")
        guard connection.hello != nil else {
            connection.helloTimedOut = true
            lose(connection)
            return
        }
        connection.abandonedHellos.insert(number)
        connection.helloWaiters.removeValue(forKey: number)?.resume(throwing: Failure.helperUnresponsive)
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
                try await sleep(retryInterval)
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
        case let .helloReply(guestVersion, protocolRevision, accessibility, screenRecording, guestKind, capabilities):
            let hello = VMGuestHello(
                guestVersion: guestVersion, accessibility: accessibility, screenRecording: screenRecording,
                protocolRevision: protocolRevision, guestKind: guestKind, capabilities: capabilities)
            connection.hello = hello
            connection.hellosAnswered += 1
            let number = connection.hellosAnswered
            if let waiter = connection.helloWaiters.removeValue(forKey: number) {
                waiter.resume(returning: hello)
            } else if connection.abandonedHellos.remove(number) == nil {
                connection.helloReplies[number] = hello
            }
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
        let helloWaiters = connection.helloWaiters
        connection.helloWaiters = [:]
        for waiter in helloWaiters.values {
            waiter.resume(throwing: connection.helloTimedOut ? Failure.helperUnresponsive : Failure.stopped)
        }
        let pending = connection.pending
        connection.pending = [:]
        for case let .waiting(continuation?) in pending.values {
            continuation.resume(throwing: Failure.stopped)
        }
    }
}
