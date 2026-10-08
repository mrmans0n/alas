import Foundation
import Observation
import os

/// A host-local, zmx-backed console the app resolved from an opaque id.
struct PeerConsoleTarget: Equatable, Sendable {
    let consoleId: String
    let socketPath: String
    let rows: Int
    let columns: Int
}

/// One authenticated peer connection's console channel. Identity is the
/// instance: attachments belong to the link that opened them.
final class PeerConsoleLink: Sendable {
    let peerName: String
    /// Sends one event on this peer's socket; `onWritten` fires once the
    /// frame has been handed to the network, which drives output credit. It
    /// must fire asynchronously, never from inside `send`.
    let send: @Sendable (PeerConsoleEvent, _ onWritten: @escaping @Sendable () -> Void) -> Void

    init(peerName: String, send: @escaping @Sendable (PeerConsoleEvent, _ onWritten: @escaping @Sendable () -> Void) -> Void) {
        self.peerName = peerName
        self.send = send
    }

    func send(_ event: PeerConsoleEvent) { send(event) {} }
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
final class PeerConsoleHost {
    struct Environment {
        var consoles: @MainActor () -> [PeerConsoleSummary]
        var resolve: @MainActor (String) -> PeerConsoleTarget?
        var setLocalInputSuppressed: @MainActor (_ consoleId: String, _ suppressed: Bool) -> Void
        var connect: @Sendable (String) throws -> ZmxIPCSocket = { try ZmxIPCSocket.connect(path: $0) }
        var captureTimeout: DispatchTimeInterval = .seconds(3)
        var limits = PeerConsoleOutbox.Limits()
    }

    static let maxScrollbackRows = 10_000
    /// Each attachment holds a socket, a reader thread, and buffers. A viewer
    /// keeps one open at a time, so these only stop a misbehaving peer.
    static let maxAttachmentsPerLink = 4
    static let maxAttachments = 16
    /// Largest accepted input message (a big paste); larger input is rejected.
    static let maxInputBytes = 1024 * 1024

    /// Console id → name of the peer controlling it, for host-side UI.
    private(set) var controllers: [String: String] = [:]

    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private var attachments: [String: PeerConsoleAttachment] = [:]
    @ObservationIgnored private var leases = PeerConsoleLeaseBook()
    @ObservationIgnored private let logger = Logger(subsystem: "io.nlopez.alas", category: "peer-console")

    init(environment: Environment) {
        self.environment = environment
    }

    func handle(_ request: PeerConsoleRequest, from link: PeerConsoleLink) {
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
        }
    }

    /// The peer connection closed or its device was revoked.
    func close(_ link: PeerConsoleLink) {
        for attachment in attachments.values where attachment.link === link {
            remove(attachment, reason: nil)
        }
    }

    /// Host reclaim. The lease generation is invalidated before local input
    /// is restored, so queued peer input can no longer be accepted.
    func reclaim(_ consoleId: String) {
        guard let (holder, generation) = leases.reclaim(consoleId) else { return }
        attachments[holder]?.discardQueuedInput()
        controllers[consoleId] = nil
        broadcastControl(consoleId, generation: generation, change: .reclaimed)
        logger.info("host reclaimed console from attachment \(holder, privacy: .public)")
        environment.setLocalInputSuppressed(consoleId, false)
    }

    /// The host console's grid changed; viewers re-fit their presentation.
    func geometryChanged(consoleId: String, rows: Int, columns: Int) {
        for attachment in attachments.values where attachment.consoleId == consoleId {
            attachment.link.send(.geometry(attachmentId: attachment.id, rows: rows, columns: columns))
        }
    }

    /// App shutdown: detach every viewer; consoles keep running.
    func shutdown() {
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
        link.send(.attached(
            attachmentId: attachmentId,
            rows: target.rows,
            columns: target.columns,
            control: control(for: attachment, change: .current)
        ))
        attachment.start(
            socket: socket,
            scrollbackRows: UInt32(min(max(scrollbackRows, 0), Self.maxScrollbackRows)),
            captureTimeout: environment.captureTimeout
        ) { [weak self] reason in
            Task { @MainActor in self?.passiveClientClosed(attachmentId, reason: reason) }
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
final class PeerConsoleAttachment: @unchecked Sendable {
    let id: String
    let consoleId: String
    let link: PeerConsoleLink
    private let lock = NSLock()
    private var outbox: PeerConsoleOutbox
    private var client: ZmxPassiveClient?

    init(id: String, consoleId: String, link: PeerConsoleLink, limits: PeerConsoleOutbox.Limits) {
        self.id = id
        self.consoleId = consoleId
        self.link = link
        outbox = PeerConsoleOutbox(limits: limits)
    }

    func start(
        socket: ZmxIPCSocket,
        scrollbackRows: UInt32,
        captureTimeout: DispatchTimeInterval,
        onClosed: @escaping @Sendable (ZmxPassiveClient.CloseReason) -> Void
    ) {
        let client = ZmxPassiveClient(socket: socket, scrollbackRows: scrollbackRows, captureTimeout: captureTimeout) {
            [weak self] event in
            switch event {
            case .snapshot(let data): self?.transition { $0.snapshot(data) }
            case .output(let data): self?.transition { $0.output(data) }
            case .closed(let reason): onClosed(reason)
            }
        }
        lock.withLock { self.client = client }
        client.start()
    }

    func send(input: Data) -> Bool {
        lock.withLock { client }?.send(input) ?? false
    }

    func requestResync() {
        transition { $0.requestResync(.requested) }
    }

    /// The lease ended: input accepted under it but not yet written is dropped.
    func discardQueuedInput() {
        lock.withLock { client }?.discardQueuedInput()
    }

    func close() {
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
