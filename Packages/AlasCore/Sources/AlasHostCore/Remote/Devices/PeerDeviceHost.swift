import Foundation
import AlasFoundation

/// Owns direct device attachments for the app. Pairing, delivery, and device
/// input are all tied to the current control link, never just the pairing ID.
@MainActor
public final class PeerDeviceHost {
    public struct Environment {
        let eligible: @MainActor () -> Bool
        let availability: @MainActor (String) -> PeerDeviceAvailability
        let driver: @MainActor (String) -> PeerDeviceDriver
        let subscribe: @MainActor (String, @escaping @MainActor (PeerDeviceVideoPacket) -> Void, @escaping @MainActor () -> Void) -> UUID
        let unsubscribe: @MainActor (String, UUID) -> Void
        let acquire: @MainActor (String, UUID) async -> Bool
        let freezeInput: @MainActor (String, UUID) -> Void
        let release: @MainActor (String, UUID) async -> Void
        let input: @MainActor (String, UUID, UInt64, PeerDeviceInput) -> Void

        public init(
            eligible: @escaping @MainActor () -> Bool,
            availability: @escaping @MainActor (String) -> PeerDeviceAvailability,
            driver: @escaping @MainActor (String) -> PeerDeviceDriver,
            subscribe: @escaping @MainActor (String, @escaping @MainActor (PeerDeviceVideoPacket) -> Void, @escaping @MainActor () -> Void) -> UUID,
            unsubscribe: @escaping @MainActor (String, UUID) -> Void,
            acquire: @escaping @MainActor (String, UUID) async -> Bool,
            freezeInput: @escaping @MainActor (String, UUID) -> Void,
            release: @escaping @MainActor (String, UUID) async -> Void,
            input: @escaping @MainActor (String, UUID, UInt64, PeerDeviceInput) -> Void
        ) {
            self.eligible = eligible
            self.availability = availability
            self.driver = driver
            self.subscribe = subscribe
            self.unsubscribe = unsubscribe
            self.acquire = acquire
            self.freezeInput = freezeInput
            self.release = release
            self.input = input
        }
    }

    struct AttachmentKey: Hashable, Sendable {
        let linkID: UUID
        let attachmentID: UUID
    }

    struct MediaSession: Equatable, Sendable {
        let key: AttachmentKey
        let id: UUID
    }

    private final class Link {
        let pairingID: String
        let name: String
        let authorized: () -> Bool
        let send: (PeerDeviceEvent) -> Void
        var lastList: [PeerDeviceSummary]?

        init(pairingID: String, name: String, authorized: @escaping () -> Bool, send: @escaping (PeerDeviceEvent) -> Void) {
            self.pairingID = pairingID
            self.name = name
            self.authorized = authorized
            self.send = send
        }
    }

    private struct MediaSink {
        let session: MediaSession
        let write: @Sendable (Data, @escaping @Sendable () -> Void) -> Void
        let close: @MainActor () -> Void
        let isOpen: @MainActor () -> Bool
    }

    private final class Attachment {
        let binding: PeerDeviceTickets.Binding
        let serial: String
        let ticketDeadline: Duration
        var ticketExpiry: Task<Void, Never>?
        var media: MediaSink?
        var streaming = false
        var lastControl: PeerDeviceEvent?

        init(binding: PeerDeviceTickets.Binding, serial: String, ticketDeadline: Duration) {
            self.binding = binding
            self.serial = serial
            self.ticketDeadline = ticketDeadline
        }
    }

    @MainActor
    private final class Capture {
        let id = UUID()
        let fanout: PeerDeviceVideoFanout
        var viewers = 0
        var token: UUID?
        var formatGeneration: UInt64?

        init(videoNow: @escaping () -> ContinuousClock.Instant) {
            fanout = PeerDeviceVideoFanout(now: videoNow)
        }
    }

    private final class Lease {
        enum State {
            case acquiring, cancelledAcquisition, active(deadline: Duration), releasing
        }

        let key: AttachmentKey
        let owner = UUID()
        let name: String
        let generation: UInt64
        var state: State = .acquiring
        var acquisition: Task<Void, Never>?
        var expiry: Task<Void, Never>?

        init(key: AttachmentKey, name: String, generation: UInt64) {
            self.key = key
            self.name = name
            self.generation = generation
        }
    }

    private static let leaseLifetime: Duration = .seconds(6)
    private static let attachmentLimitPerLink = 8
    private let grants: PeerDeviceGrants
    private let environment: Environment
    private let now: @MainActor () -> Duration
    private let videoNow: () -> ContinuousClock.Instant
    private let waitForExpiry: @MainActor (Duration) async throws -> Void
    private let tickets = PeerDeviceTickets()
    private var links: [UUID: Link] = [:]
    private var attachments: [AttachmentKey: Attachment] = [:]
    private var captures: [String: Capture] = [:]
    private var leases: [String: Lease] = [:]
    private var leaseGeneration: UInt64 = 0
    private var shuttingDownPermanently = false
    private var shutdownWaiters: [UUID: () -> Void] = [:]

    public var onDriverChange: ((String) -> Void)?

    public convenience init(grants: PeerDeviceGrants, environment: Environment) {
        let origin = ContinuousClock.now
        self.init(grants: grants, environment: environment, now: { origin.duration(to: .now) })
    }

    init(grants: PeerDeviceGrants, environment: Environment, now: @escaping @MainActor () -> Duration,
         videoNow: @escaping () -> ContinuousClock.Instant = { .now },
         waitForExpiry: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.grants = grants
        self.environment = environment
        self.now = now
        self.videoNow = videoNow
        self.waitForExpiry = waitForExpiry
    }

    var isEligible: Bool { !shuttingDownPermanently && environment.eligible() }

    public func remoteDriverName(serial: String) -> String? {
        guard let lease = leases[serial], case .active(let deadline) = lease.state, now() < deadline else { return nil }
        return lease.name
    }

    public func reclaim(serial: String) {
        relinquish(serial: serial)
    }

    /// Call when device inventory, grants, driver, or serving policy changes.
    public func refresh() {
        for (key, attachment) in attachments {
            if access(to: attachment) == nil {
                detach(key, reason: "Device access is no longer available.")
                continue
            }
            let availability = environment.availability(attachment.serial)
            if availability != .ready {
                detach(key, reason: Self.unavailableReason(availability))
            } else if !attachment.streaming, now() >= attachment.ticketDeadline {
                detach(key, reason: "The device video connection expired.")
            }
        }
        for (serial, lease) in leases {
            if let attachment = attachments[lease.key], access(to: attachment) != .control {
                relinquish(serial: serial)
            } else {
                expireLease(serial: serial)
            }
        }
        for (serial, capture) in captures where capture.viewers > 0 { sendDrivers(serial: serial) }
        sendChangedLists()
    }

    public func shutdown() {
        for id in Array(links.keys) { disconnect(id) }
    }

    /// Quit stops admission permanently. Give input cleanup time to finish
    /// while capture is alive, but do not hold quit behind a stuck agent turn.
    public func shutdownAndWait() async {
        await shutdownAndWait(upTo: .seconds(2))
    }

    func shutdownAndWait(upTo timeout: Duration) async {
        shuttingDownPermanently = true
        shutdown()
        guard !leases.isEmpty, timeout > .zero else { return }
        let id = UUID()
        await withCheckedContinuation { continuation in
            let timer = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                self?.shutdownWaiters.removeValue(forKey: id)?()
            }
            shutdownWaiters[id] = {
                timer.cancel()
                continuation.resume()
            }
        }
    }

    private func resumeShutdownWaitersIfDrained() {
        guard leases.isEmpty, !shutdownWaiters.isEmpty else { return }
        let completed = shutdownWaiters.values
        shutdownWaiters.removeAll()
        for resume in completed { resume() }
    }

    func connect(pairingID: String, name: String, authorized: @escaping () -> Bool,
                 send: @escaping (PeerDeviceEvent) -> Void) -> UUID {
        let id = UUID()
        links[id] = Link(pairingID: pairingID, name: name, authorized: authorized, send: send)
        return id
    }

    func disconnect(_ linkID: UUID) {
        guard links.removeValue(forKey: linkID) != nil else { return }
        tickets.invalidate(linkID: linkID)
        for key in attachments.keys where key.linkID == linkID { detach(key, reason: nil) }
    }

    func handle(_ request: PeerDeviceRequest, from linkID: UUID) {
        guard let link = links[linkID], link.authorized() else {
            disconnect(linkID)
            return
        }
        switch request {
        case .list:
            sendList(to: link, id: linkID, force: true)
        case .attach(let deviceID, let attachmentID):
            attach(deviceID: deviceID, key: AttachmentKey(linkID: linkID, attachmentID: attachmentID), link: link)
        case .detach(let id):
            detach(AttachmentKey(linkID: linkID, attachmentID: id), reason: nil)
        case .takeControl(let id):
            takeControl(AttachmentKey(linkID: linkID, attachmentID: id), link: link)
        case .releaseControl(let id):
            let key = AttachmentKey(linkID: linkID, attachmentID: id)
            guard let attachment = attachments[key] else { return }
            if let lease = leases[attachment.serial], lease.key == key {
                if case .active = lease.state {
                    relinquish(serial: attachment.serial)
                    return // Already sends the updated driver to this attachment.
                }
                relinquish(serial: attachment.serial)
            }
            sendDriver(to: key, attachment: attachment, force: true)
        case .renewControl(let id, let generation):
            let key = AttachmentKey(linkID: linkID, attachmentID: id)
            guard let attachment = attachments[key], let lease = activeLease(for: attachment, key: key),
                  lease.generation == generation else { return }
            lease.state = .active(deadline: now() + Self.leaseLifetime)
        case .input(let id, let leaseGeneration, let formatGeneration, let event):
            let key = AttachmentKey(linkID: linkID, attachmentID: id)
            guard let attachment = attachments[key], let lease = activeLease(for: attachment, key: key),
                  lease.generation == leaseGeneration,
                  captures[attachment.serial]?.formatGeneration == formatGeneration,
                  Self.validInput(event) else { return }
            environment.input(attachment.serial, lease.owner, formatGeneration, event)
        }
    }

    // A claim consumes the one-use ticket before the socket writes its 101.
    // Do not subscribe to capture until that response is actually written.
    func claimMedia(ticket: String, write: @escaping @Sendable (Data, @escaping @Sendable () -> Void) -> Void,
                    close: @escaping @MainActor () -> Void,
                    isOpen: @escaping @MainActor () -> Bool) -> MediaSession? {
        guard let binding = tickets.redeem(ticket, now: now()) else { return nil }
        let key = AttachmentKey(linkID: binding.linkID, attachmentID: binding.attachmentID)
        guard let attachment = attachments[key], attachment.binding == binding,
              attachment.media == nil, access(to: attachment) != nil,
              environment.availability(attachment.serial) == .ready else { return nil }
        let session = MediaSession(key: key, id: UUID())
        attachment.media = MediaSink(session: session, write: write, close: close, isOpen: isOpen)
        return session
    }

    func startMedia(_ session: MediaSession) {
        guard let attachment = attachments[session.key], let media = attachment.media,
              media.session == session, !attachment.streaming else { return }
        guard media.isOpen(), now() < attachment.ticketDeadline, access(to: attachment) != nil,
              environment.availability(attachment.serial) == .ready else {
            detach(session.key, reason: "The device video connection is no longer available.")
            return
        }
        attachment.ticketExpiry?.cancel()
        attachment.ticketExpiry = nil
        attachment.streaming = true
        let serial = attachment.serial
        let first = captures[serial] == nil
        let capture = captures[serial] ?? Capture(videoNow: videoNow)
        captures[serial] = capture
        capture.viewers += 1
        capture.fanout.add(id: session.id, write: media.write, close: { [weak self] in
            self?.mediaClosed(session, reason: "The video connection could not keep up.")
        })
        if first, captures[serial] === capture {
            let id = capture.id
            let token = environment.subscribe(serial, { [weak self] packet in
                self?.publish(packet, serial: serial, captureID: id)
            }, { [weak self] in
                self?.sourceStopped(serial: serial, captureID: id)
            })
            // Some sources replay or fail synchronously during subscription.
            if captures[serial] === capture { capture.token = token }
            else { environment.unsubscribe(serial, token) }
        }
        if attachments[session.key] === attachment { sendDriver(to: session.key, attachment: attachment) }
    }

    func mediaClosed(_ session: MediaSession) {
        mediaClosed(session, reason: "The device video connection closed.")
    }

    private func mediaClosed(_ session: MediaSession, reason: String) {
        guard attachments[session.key]?.media?.session == session else { return }
        detach(session.key, reason: reason)
    }

    private func attach(deviceID: PeerDeviceID, key: AttachmentKey, link: Link) {
        func refuse(_ reason: String) { link.send(.refused(attachmentID: key.attachmentID, reason: reason)) }
        guard attachments[key] == nil else { return }
        guard isEligible, grants.access(to: deviceID, pairingID: link.pairingID) != nil,
              let serial = grants.serial(for: deviceID) else {
            refuse("This device is not shared with you.")
            return
        }
        let availability = environment.availability(serial)
        guard availability == .ready else { return refuse(Self.unavailableReason(availability)) }
        guard attachments.keys.lazy.filter({ $0.linkID == key.linkID }).prefix(Self.attachmentLimitPerLink).count < Self.attachmentLimitPerLink else {
            return refuse("Too many device attachments are open.")
        }
        let binding = PeerDeviceTickets.Binding(linkID: key.linkID, attachmentID: key.attachmentID,
                                                pairingID: link.pairingID, deviceID: deviceID)
        let issued = now()
        let attachment = Attachment(binding: binding, serial: serial, ticketDeadline: issued + PeerDeviceTickets.lifetime)
        attachments[key] = attachment
        let ticket = tickets.issue(for: binding, now: issued)
        attachment.ticketExpiry = Task { [weak self, weak attachment] in
            try? await Task.sleep(for: PeerDeviceTickets.lifetime)
            guard !Task.isCancelled, let self, let attachment, self.attachments[key] === attachment else { return }
            self.detach(key, reason: "The device video connection expired.")
        }
        link.send(.attached(attachmentID: key.attachmentID, ticket: ticket))
    }

    private func detach(_ key: AttachmentKey, reason: String?) {
        guard let attachment = attachments.removeValue(forKey: key) else { return }
        tickets.invalidate(attachment.binding)
        attachment.ticketExpiry?.cancel()
        let serial = attachment.serial
        if leases[serial]?.key == key { relinquish(serial: serial) }
        if let media = attachment.media {
            if attachment.streaming, let capture = captures[serial] {
                capture.fanout.remove(id: media.session.id)
                capture.viewers -= 1
                stopUnusedCapture(serial: serial)
            }
            media.close()
        }
        if let reason, let link = links[key.linkID], link.authorized() {
            link.send(.detached(attachmentID: key.attachmentID, reason: reason))
        }
    }

    private func stopUnusedCapture(serial: String) {
        // Keep the scrcpy session alive long enough to send pointer cancels
        // and key ups, even if the old driver was the last video viewer.
        guard let capture = captures[serial], capture.viewers == 0, leases[serial] == nil else { return }
        captures[serial] = nil
        if let token = capture.token { environment.unsubscribe(serial, token) }
    }

    private func publish(_ packet: PeerDeviceVideoPacket, serial: String, captureID: UUID) {
        guard let capture = captures[serial], capture.id == captureID, isEligible else { return }
        if case .format(let generation, _, _) = packet, generation != capture.formatGeneration {
            if capture.formatGeneration != nil { relinquish(serial: serial) }
            capture.formatGeneration = generation
        }
        capture.fanout.publish(packet)
    }

    private func sourceStopped(serial: String, captureID: UUID) {
        guard let capture = captures[serial], capture.id == captureID else { return }
        captures[serial] = nil
        let availability = environment.availability(serial)
        let reason = Self.unavailableReason(availability == .ready ? .interrupted : availability)
        for (key, attachment) in attachments where attachment.serial == serial { detach(key, reason: reason) }
        if let token = capture.token { environment.unsubscribe(serial, token) }
        sendChangedLists()
    }

    private func access(to attachment: Attachment) -> PeerDeviceAccess? {
        let binding = attachment.binding
        guard isEligible, let link = links[binding.linkID], link.pairingID == binding.pairingID, link.authorized() else { return nil }
        return grants.access(to: binding.deviceID, pairingID: binding.pairingID)
    }

    private func canControl(_ attachment: Attachment) -> Bool {
        attachment.streaming && attachment.media?.isOpen() == true && captures[attachment.serial]?.formatGeneration != nil &&
            access(to: attachment) == .control && environment.availability(attachment.serial) == .ready
    }

    private func takeControl(_ key: AttachmentKey, link: Link) {
        guard let attachment = attachments[key], canControl(attachment) else {
            link.send(.refused(attachmentID: key.attachmentID, reason: "Control is not available for this attachment."))
            return
        }
        let serial = attachment.serial
        expireLease(serial: serial)
        if let lease = leases[serial] {
            if lease.key == key, case .active = lease.state {
                sendDriver(to: key, attachment: attachment, force: true)
            } else if lease.key == key, case .acquiring = lease.state {
                return // This request already has a takeover in progress.
            } else {
                link.send(.refused(attachmentID: key.attachmentID, reason: "Control is held or being handed back."))
            }
            return
        }
        leaseGeneration &+= 1
        let lease = Lease(key: key, name: link.name, generation: leaseGeneration)
        leases[serial] = lease
        lease.acquisition = Task { await finishTakingControl(lease, serial: serial) }
    }

    private func finishTakingControl(_ lease: Lease, serial: String) async {
        let key = lease.key
        let acquired: Bool
        if case .acquiring = lease.state, let attachment = attachments[key], canControl(attachment) {
            acquired = await environment.acquire(serial, lease.owner)
        } else {
            acquired = false
        }
        lease.acquisition = nil
        if acquired {
            if case .acquiring = lease.state, let attachment = attachments[key], canControl(attachment) {
                lease.state = .active(deadline: now() + Self.leaseLifetime)
                let owner = lease.owner
                lease.expiry = Task { [weak self] in await self?.waitForLeaseExpiry(serial: serial, owner: owner) }
                driverChanged(serial: serial)
            } else {
                lease.state = .releasing
                environment.freezeInput(serial, lease.owner)
                await finishRelease(lease, serial: serial)
            }
        } else {
            leases[serial] = nil
            stopUnusedCapture(serial: serial)
            if case .acquiring = lease.state, let link = links[key.linkID], link.authorized(), attachments[key] != nil {
                link.send(.refused(attachmentID: key.attachmentID, reason: "The device could not hand over control."))
            }
            sendDrivers(serial: serial)
            sendChangedLists()
            resumeShutdownWaitersIfDrained()
        }
    }

    private func activeLease(for attachment: Attachment, key: AttachmentKey) -> Lease? {
        let serial = attachment.serial
        expireLease(serial: serial)
        guard let lease = leases[serial], lease.key == key, case .active = lease.state else { return nil }
        guard canControl(attachment) else {
            relinquish(serial: serial)
            return nil
        }
        return lease
    }

    private func relinquish(serial: String) {
        guard let lease = leases[serial] else { return }
        switch lease.state {
        case .acquiring:
            // Let the reservation settle before another takeover. If the
            // backend grants it after cancellation, release it without use.
            lease.state = .cancelledAcquisition
            lease.acquisition?.cancel()
        case .active:
            // Invalidate the wire lease before waiting on the input backend.
            lease.state = .releasing
            environment.freezeInput(serial, lease.owner)
            lease.expiry?.cancel()
            lease.expiry = nil
            driverChanged(serial: serial)
            Task { await finishRelease(lease, serial: serial) }
        case .cancelledAcquisition, .releasing:
            break
        }
    }

    private func finishRelease(_ lease: Lease, serial: String) async {
        await environment.release(serial, lease.owner)
        guard leases[serial] === lease else { return }
        leases[serial] = nil
        stopUnusedCapture(serial: serial)
        sendDrivers(serial: serial)
        sendChangedLists()
        resumeShutdownWaitersIfDrained()
    }

    private func expireLease(serial: String) {
        if let lease = leases[serial], case .active(let deadline) = lease.state, now() >= deadline {
            relinquish(serial: serial)
        }
    }

    private func waitForLeaseExpiry(serial: String, owner: UUID) async {
        while !Task.isCancelled, let lease = leases[serial], lease.owner == owner, case .active(let deadline) = lease.state {
            let remaining = deadline - now()
            guard remaining > .zero else { return expireLease(serial: serial) }
            do { try await waitForExpiry(remaining) } catch { return }
        }
    }

    private func driverChanged(serial: String) {
        sendDrivers(serial: serial)
        sendChangedLists()
        onDriverChange?(serial)
    }

    private func driver(serial: String, link: UUID, attachment: AttachmentKey? = nil) -> PeerDeviceDriver {
        guard let lease = leases[serial], case .active(let deadline) = lease.state, now() < deadline else {
            return environment.driver(serial)
        }
        return (attachment.map { $0 == lease.key } ?? (lease.key.linkID == link)) ? .you : .other(name: lease.name)
    }

    private func sendDriver(to key: AttachmentKey, attachment: Attachment, force: Bool = false) {
        guard let link = links[key.linkID], access(to: attachment) != nil else { return }
        let driver = driver(serial: attachment.serial, link: key.linkID, attachment: key)
        let generation = driver == .you ? leases[attachment.serial]?.generation ?? 0 : 0
        let event = PeerDeviceEvent.control(attachmentID: key.attachmentID, driver: driver, generation: generation)
        guard force || attachment.lastControl != event else { return }
        attachment.lastControl = event
        link.send(event)
    }

    private func sendDrivers(serial: String) {
        for (key, attachment) in attachments where attachment.streaming && attachment.serial == serial {
            sendDriver(to: key, attachment: attachment)
        }
    }

    private func sendChangedLists() {
        for (id, link) in links where link.lastList != nil { sendList(to: link, id: id) }
    }

    private func sendList(to link: Link, id: UUID, force: Bool = false) {
        guard link.authorized() else { return }
        let devices: [PeerDeviceSummary] = isEligible ? grants.sharedIDs(for: link.pairingID).compactMap { deviceID in
            guard let access = grants.access(to: deviceID, pairingID: link.pairingID),
                  let serial = grants.serial(for: deviceID), let name = grants.name(for: deviceID) else { return nil }
            return PeerDeviceSummary(id: deviceID, name: name, access: access, availability: environment.availability(serial),
                                     driver: driver(serial: serial, link: id))
        } : []
        guard force || devices != link.lastList else { return }
        link.lastList = devices
        link.send(.list(devices))
    }

    private static func validInput(_ input: PeerDeviceInput) -> Bool {
        switch input {
        case .pointer(_, let x, let y):
            (0...1).contains(x) && (0...1).contains(y)
        case .scroll(let x, let y, let dx, let dy):
            (0...1).contains(x) && (0...1).contains(y) && (-100...100).contains(dx) && (-100...100).contains(dy)
        case .key(let usage, _):
            (1...0xffff).contains(usage)
        case .text(let text):
            !text.isEmpty && text.utf8.count <= 4096
        case .button:
            true
        }
    }

    private static func unavailableReason(_ availability: PeerDeviceAvailability) -> String {
        switch availability {
        case .absent: "The Android device is disconnected."
        case .unauthorized: "Authorize USB debugging on the Android device."
        case .offline: "The Android device is offline."
        case .interrupted: "The Android video stream was interrupted."
        case .ready: "The device is ready."
        }
    }
}
