import Foundation
import Observation
import os
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents

/// A host-local, zmx-backed console the app resolved from an opaque id.
public struct PeerConsoleTarget: Equatable, Sendable {
    public let consoleId: String
    public let socketPath: String
    public let rows: Int
    public let columns: Int

    public init(consoleId: String, socketPath: String, rows: Int, columns: Int) {
        self.consoleId = consoleId
        self.socketPath = socketPath
        self.rows = rows
        self.columns = columns
    }
}

/// One authenticated peer connection's console channel. Identity is the
/// instance: attachments belong to the link that opened them.
public final class PeerConsoleLink: Sendable {
    public let peerName: String
    /// Sends one event on this peer's socket; `onWritten` fires once the
    /// frame has been handed to the network, which drives output credit. It
    /// must fire asynchronously, never from inside `send`.
    public let send: @Sendable (PeerConsoleEvent, _ onWritten: @escaping @Sendable () -> Void) -> Void

    public init(peerName: String, send: @escaping @Sendable (PeerConsoleEvent, _ onWritten: @escaping @Sendable () -> Void) -> Void) {
        self.peerName = peerName
        self.send = send
    }

    public func send(_ event: PeerConsoleEvent) { send(event) {} }
}

/// Serves the host's consoles to paired peers.
///
/// Peers name a console only by its opaque id; the app resolves the socket
/// through its live terminal registry and refuses anything ineligible before
/// a connection is opened. Each attachment is a passive zmx client, so views
/// never change zmx leadership or PTY geometry. Control is an app-level
/// lease (`PeerConsoleLeaseBook`): while a peer holds it, the host's own
/// input to that console is suppressed and accepted peer input goes through
/// zmx `Send`.
@MainActor
@Observable
public final class PeerConsoleHost {
    public struct Environment {
        public var consoles: @MainActor () -> [PeerConsoleSummary]
        public var resolve: @MainActor (String) -> PeerConsoleTarget?
        public var setLocalInputSuppressed: @MainActor (_ consoleId: String, _ suppressed: Bool) -> Void
        /// Closes a console `resolve` accepted, as a local tab close does.
        public var terminate: @MainActor (String) -> Void
        /// Opens a console in a host worktree and returns its id. Throws
        /// `PeerConsoleOpenError`. Nil when this host can't open consoles.
        public var open: (@MainActor (_ worktreeId: String) async throws -> String)?
        /// Resizes a console; true when it applied. Nil means the host sizes
        /// its consoles itself and ignores peer resizes.
        public var resize: (@MainActor (_ consoleId: String, _ rows: Int, _ columns: Int) async -> Bool)?
        /// How long a newly opened console has to become reachable before it
        /// is closed and the open fails.
        public var openReadyTimeout: Duration
        public var connect: @Sendable (String) throws -> ZmxIPCSocket = { try ZmxIPCSocket.connect(path: $0) }
        /// Detects a socket's wire format. Blocking; runs off the main actor.
        public var probe: @Sendable (String) -> ZmxDaemonStatus = { ZmxIPCSocket.probe(path: $0) }
        public var captureTimeout: DispatchTimeInterval = .seconds(3)
        public var limits = PeerConsoleOutbox.Limits()

        public init(
            consoles: @escaping @MainActor () -> [PeerConsoleSummary],
            resolve: @escaping @MainActor (String) -> PeerConsoleTarget?,
            setLocalInputSuppressed: @escaping @MainActor (_ consoleId: String, _ suppressed: Bool) -> Void,
            terminate: @escaping @MainActor (String) -> Void,
            open: (@MainActor (_ worktreeId: String) async throws -> String)? = nil,
            resize: (@MainActor (_ consoleId: String, _ rows: Int, _ columns: Int) async -> Bool)? = nil,
            openReadyTimeout: Duration = .seconds(5),
            connect: @escaping @Sendable (String) throws -> ZmxIPCSocket = { try ZmxIPCSocket.connect(path: $0) },
            probe: @escaping @Sendable (String) -> ZmxDaemonStatus = { ZmxIPCSocket.probe(path: $0) },
            captureTimeout: DispatchTimeInterval = .seconds(3),
            limits: PeerConsoleOutbox.Limits = PeerConsoleOutbox.Limits()
        ) {
            self.consoles = consoles
            self.resolve = resolve
            self.setLocalInputSuppressed = setLocalInputSuppressed
            self.terminate = terminate
            self.open = open
            self.resize = resize
            self.openReadyTimeout = openReadyTimeout
            self.connect = connect
            self.probe = probe
            self.captureTimeout = captureTimeout
            self.limits = limits
        }
    }

    public static let maxScrollbackRows = 10_000
    /// Each attachment holds a socket, a reader thread, and buffers. A viewer
    /// keeps one open at a time, so these only stop a misbehaving peer.
    public static let maxAttachmentsPerLink = 4
    public static let maxAttachments = 16
    /// Largest accepted input message (a big paste); larger input is rejected.
    public static let maxInputBytes = 1024 * 1024
    /// Rows and columns a peer may resize a console to.
    public nonisolated static let gridLimits: ClosedRange<Int> = 2...1000

    /// Console id → name of the peer controlling it, for host-side UI.
    public private(set) var controllers: [String: String] = [:]

    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private var attachments: [String: PeerConsoleAttachment] = [:]
    @ObservationIgnored private var leases = PeerConsoleLeaseBook()
    @ObservationIgnored private let logger = Logger(subsystem: "io.nlopez.alas", category: "peer-console")

    public init(environment: Environment) {
        self.environment = environment
    }

    public func handle(_ request: PeerConsoleRequest, from link: PeerConsoleLink) {
        switch request {
        case .list:
            link.send(.list(consoles: environment.consoles()))
        case .attach(let consoleId, let attachmentId, let scrollbackRows):
            attach(consoleId: consoleId, attachmentId: attachmentId, scrollbackRows: scrollbackRows, link: link)
        case .takeControl(let attachmentId):
            guard let attachment = attachment(attachmentId, of: link) else { return }
            takeControl(attachment)
        case .releaseControl(let attachmentId):
            guard let attachment = attachment(attachmentId, of: link) else { return }
            revokeLease(of: attachment, change: .released)
        case .input(let attachmentId, let generation, let sequence, let data):
            let attachment = attachment(attachmentId, of: link)
            let leased = attachment.map {
                data.count <= Self.maxInputBytes
                    && leases.accepts($0.consoleId, from: attachmentId, generation: generation)
            } ?? false
            let accepted = leased && attachment?.send(input: data) == true
            link.send(.inputAck(attachmentId: attachmentId, sequence: sequence, accepted: accepted))
            // The console is not taking input (stalled or gone). Keystrokes
            // after a gap would be wrong, so control ends visibly instead.
            if leased, !accepted, let attachment {
                revokeLease(of: attachment, change: .revoked)
            }
        case .resync(let attachmentId):
            attachment(attachmentId, of: link)?.requestResync()
        case .detach(let attachmentId):
            guard let attachment = attachment(attachmentId, of: link) else { return }
            remove(attachment, reason: .detached)
        case .terminate(let consoleId):
            terminate(consoleId: consoleId, link: link)
        case .open(let requestId, let worktreeId):
            open(requestId: requestId, worktreeId: worktreeId, link: link)
        case .resize(let attachmentId, let rows, let columns):
            resize(attachmentId: attachmentId, rows: rows, columns: columns, link: link)
        }
    }

    /// The peer connection closed or its device was revoked.
    public func close(_ link: PeerConsoleLink) {
        for attachment in attachments.values where attachment.link === link {
            remove(attachment, reason: nil)
        }
    }

    /// Host reclaim. The lease generation is invalidated before local input
    /// is restored, so queued peer input can no longer be accepted.
    public func reclaim(_ consoleId: String) {
        guard let (holder, generation) = leases.reclaim(consoleId) else { return }
        attachments[holder]?.discardQueuedInput()
        controllers[consoleId] = nil
        broadcastControl(consoleId, generation: generation, change: .reclaimed)
        logger.info("host reclaimed console from attachment \(holder, privacy: .public)")
        environment.setLocalInputSuppressed(consoleId, false)
    }

    /// The host console's grid changed; viewers re-fit their presentation.
    public func geometryChanged(consoleId: String, rows: Int, columns: Int) {
        for attachment in attachments.values where attachment.consoleId == consoleId {
            attachment.link.send(.geometry(attachmentId: attachment.id, rows: rows, columns: columns))
        }
    }

    /// App shutdown: detach every viewer; consoles keep running.
    public func shutdown() {
        for attachment in attachments.values { remove(attachment, reason: .detached) }
    }

    // MARK: - Attachments

    private func attach(consoleId: String, attachmentId: String, scrollbackRows: Int, link: PeerConsoleLink) {
        guard attachments[attachmentId] == nil else {
            link.send(.detached(attachmentId: attachmentId, reason: .protocolError))
            return
        }
        guard attachments.count < Self.maxAttachments,
              attachments.values.filter({ $0.link === link }).count < Self.maxAttachmentsPerLink else {
            link.send(.detached(attachmentId: attachmentId, reason: .limitReached))
            return
        }
        guard let target = environment.resolve(consoleId) else {
            link.send(.detached(attachmentId: attachmentId, reason: .unavailable))
            return
        }
        let socket: ZmxIPCSocket
        do {
            socket = try environment.connect(target.socketPath)
        } catch {
            logger.info("console socket unavailable: \(String(describing: error), privacy: .public)")
            link.send(.detached(attachmentId: attachmentId, reason: .unavailable))
            return
        }
        let attachment = PeerConsoleAttachment(
            id: attachmentId,
            consoleId: target.consoleId,
            link: link,
            limits: environment.limits
        )
        attachments[attachmentId] = attachment
        let probe = environment.probe
        let socketPath = target.socketPath
        link.send(.attached(
            attachmentId: attachmentId,
            rows: target.rows,
            columns: target.columns,
            control: control(for: attachment, change: .current)
        ))
        attachment.start(
            socket: socket,
            probe: { probe(socketPath) },
            scrollbackRows: UInt32(min(max(scrollbackRows, 0), Self.maxScrollbackRows)),
            captureTimeout: environment.captureTimeout
        ) { [weak self] reason in
            Task { @MainActor in self?.passiveClientClosed(attachmentId, reason: reason) }
        }
    }

    /// Viewers detach before the console closes, so its exit reaches them as
    /// `terminated` rather than racing in as `targetExited`.
    private func terminate(consoleId: String, link: PeerConsoleLink) {
        guard environment.resolve(consoleId) != nil else { return }
        for attachment in attachments.values where attachment.consoleId == consoleId {
            remove(attachment, reason: .terminated)
        }
        environment.terminate(consoleId)
        logger.info("peer terminated console \(consoleId, privacy: .public)")
        link.send(.list(consoles: environment.consoles()))
    }

    /// Replies only once the new console is reachable, so the peer's attach
    /// can't race its startup. One that never comes up is closed rather than
    /// left behind.
    private func open(requestId: String, worktreeId: String, link: PeerConsoleLink) {
        guard let open = environment.open else {
            link.send(.openFailed(requestId: requestId, message: PeerConsoleOpenError.unsupported.message))
            return
        }
        Task {
            let message: String
            do {
                let consoleId = try await open(worktreeId)
                if await waitUntilReachable(consoleId) {
                    logger.info("peer opened console \(consoleId, privacy: .public)")
                    link.send(.list(consoles: environment.consoles()))
                    link.send(.opened(requestId: requestId, consoleId: consoleId))
                    return
                }
                environment.terminate(consoleId)
                message = PeerConsoleOpenError.notStarted.message
            } catch let error as PeerConsoleOpenError {
                message = error.message
            } catch {
                message = PeerConsoleOpenError.notStarted.message
            }
            logger.info("peer console open failed: \(message, privacy: .public)")
            link.send(.openFailed(requestId: requestId, message: message))
        }
    }

    /// Polls until `resolve` knows the console and its daemon answers, at
    /// least once and until `openReadyTimeout` has passed.
    private func waitUntilReachable(_ consoleId: String) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + environment.openReadyTimeout
        let probe = environment.probe
        while true {
            if let path = environment.resolve(consoleId)?.socketPath,
               await BlockingWork.run({ probe(path) }) != .unreachable {
                return true
            }
            guard clock.now < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
    }

    /// Only the lease holder sizes the console; viewers follow `geometry`.
    private func resize(attachmentId: String, rows: Int, columns: Int, link: PeerConsoleLink) {
        guard let resize = environment.resize,
              let attachment = attachment(attachmentId, of: link),
              leases.holder(of: attachment.consoleId) == attachmentId,
              Self.gridLimits.contains(rows), Self.gridLimits.contains(columns) else { return }
        let consoleId = attachment.consoleId
        Task {
            if await resize(consoleId, rows, columns) {
                geometryChanged(consoleId: consoleId, rows: rows, columns: columns)
            }
        }
    }

    private func passiveClientClosed(_ attachmentId: String, reason: ZmxPassiveClient.CloseReason) {
        guard let attachment = attachments[attachmentId] else { return }
        let detachReason: PeerConsoleDetachReason = switch reason {
        case .detached: .detached
        case .targetExited: .targetExited
        case .captureUnsupported: .restartRequired
        case .overflow: .localOverflow
        case .protocolError: .protocolError
        case .unreachable: .unavailable
        }
        remove(attachment, reason: detachReason)
    }

    /// Ends one attachment: revokes its lease, closes only its passive zmx
    /// client, and tells the peer why unless the connection is already gone.
    private func remove(_ attachment: PeerConsoleAttachment, reason: PeerConsoleDetachReason?) {
        guard attachments.removeValue(forKey: attachment.id) != nil else { return }
        revokeLease(of: attachment, change: .revoked)
        attachment.close()
        if let reason {
            attachment.link.send(.detached(attachmentId: attachment.id, reason: reason))
        }
    }

    private func attachment(_ id: String, of link: PeerConsoleLink) -> PeerConsoleAttachment? {
        guard let attachment = attachments[id], attachment.link === link else { return nil }
        return attachment
    }

    // MARK: - Control

    private func takeControl(_ attachment: PeerConsoleAttachment) {
        guard let generation = leases.take(attachment.consoleId, by: attachment.id) else {
            attachment.link.send(.control(attachmentId: attachment.id, control: control(for: attachment, change: .denied)))
            return
        }
        // Suppress host input before any peer input can be accepted.
        environment.setLocalInputSuppressed(attachment.consoleId, true)
        controllers[attachment.consoleId] = attachment.link.peerName
        broadcastControl(attachment.consoleId, generation: generation, change: .granted)
    }

    private func revokeLease(of attachment: PeerConsoleAttachment, change: PeerConsoleControl.Change) {
        guard let generation = leases.release(attachment.consoleId, by: attachment.id) else { return }
        attachment.discardQueuedInput()
        controllers[attachment.consoleId] = nil
        broadcastControl(attachment.consoleId, generation: generation, change: change)
        environment.setLocalInputSuppressed(attachment.consoleId, false)
    }

    private func broadcastControl(_ consoleId: String, generation: Int, change: PeerConsoleControl.Change) {
        for attachment in attachments.values where attachment.consoleId == consoleId {
            attachment.link.send(.control(attachmentId: attachment.id, control: control(for: attachment, change: change)))
        }
    }

    private func control(for attachment: PeerConsoleAttachment, change: PeerConsoleControl.Change) -> PeerConsoleControl {
        let owner: PeerConsoleControl.Owner = switch leases.holder(of: attachment.consoleId) {
        case nil: .host
        case attachment.id?: .you
        case .some: .anotherPeer
        }
        return PeerConsoleControl(owner: owner, generation: leases.generation(of: attachment.consoleId), change: change)
    }
}

/// Relays one passive zmx client to one peer through a bounded outbox.
///
/// Thread-safe: zmx events arrive on the client's reader thread and write
/// completions on the connection's queue. Every outbox transition and the
/// send it produces happen under one lock, so frames leave in sequence order.
/// Sends only enqueue onto the connection, so nothing blocks under the lock.
public final class PeerConsoleAttachment: @unchecked Sendable {
    public let id: String
    public let consoleId: String
    public let link: PeerConsoleLink
    private let lock = NSLock()
    private var outbox: PeerConsoleOutbox
    private var client: ZmxPassiveClient?

    public init(id: String, consoleId: String, link: PeerConsoleLink, limits: PeerConsoleOutbox.Limits) {
        self.id = id
        self.consoleId = consoleId
        self.link = link
        outbox = PeerConsoleOutbox(limits: limits)
    }

    public func start(
        socket: ZmxIPCSocket,
        probe: @escaping @Sendable () -> ZmxDaemonStatus,
        scrollbackRows: UInt32,
        captureTimeout: DispatchTimeInterval,
        onClosed: @escaping @Sendable (ZmxPassiveClient.CloseReason) -> Void
    ) {
        let client = ZmxPassiveClient(
            socket: socket,
            probe: probe,
            scrollbackRows: scrollbackRows,
            captureTimeout: captureTimeout
        ) { [weak self] event in
            switch event {
            case .snapshot(let data): self?.transition { $0.snapshot(data) }
            case .output(let data): self?.transition { $0.output(data) }
            case .closed(let reason): onClosed(reason)
            }
        }
        lock.withLock { self.client = client }
        client.start()
    }

    public func send(input: Data) -> Bool {
        lock.withLock { client }?.send(input) ?? false
    }

    public func requestResync() {
        transition { $0.requestResync(.requested) }
    }

    /// The lease ended: input accepted under it but not yet written is dropped.
    public func discardQueuedInput() {
        lock.withLock { client }?.discardQueuedInput()
    }

    public func close() {
        lock.withLock { client }?.close()
    }

    private func transition(_ step: (inout PeerConsoleOutbox) -> [PeerConsoleOutbox.Action]) {
        var captureRequested = false
        lock.withLock {
            for action in step(&outbox) {
                switch action {
                case .snapshot(let sequence, let reason, let data):
                    link.send(.snapshot(attachmentId: id, sequence: sequence, reason: reason, data: data)) { [weak self] in
                        self?.transition { $0.delivered(bytes: data.count) }
                    }
                case .output(let sequence, let data):
                    link.send(.output(attachmentId: id, sequence: sequence, data: data)) { [weak self] in
                        self?.transition { $0.delivered(bytes: data.count) }
                    }
                case .requestCapture:
                    captureRequested = true
                }
            }
        }
        // Outside the lock: a failed write closes the client, whose delivery
        // lock the reader thread may hold while it waits for ours.
        if captureRequested { lock.withLock { client }?.requestResync() }
    }
}
