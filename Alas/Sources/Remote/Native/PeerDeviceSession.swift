import AlasRemoteKit
import Foundation
import Observation

@MainActor
@Observable
final class PeerDeviceSession {
    typealias MediaOpener = @MainActor (
        _ origin: URL, _ ticket: String,
        _ packet: @escaping @MainActor (PeerDeviceVideoPacket) -> Void,
        _ ended: @escaping @MainActor () -> Void
    ) -> (@MainActor () -> Void)

    struct InputContext: Equatable {
        fileprivate let attachmentID: UUID
        fileprivate let leaseGeneration: UInt64
        fileprivate let formatGeneration: UInt64
    }

    private struct Attachment: Equatable {
        let id: UUID
        let origin: URL
    }

    private enum Control: Equatable {
        case viewing
        case requesting
        case holding(UInt64)
        case releasing
    }

    private(set) var devices: [PeerDeviceSummary] = []
    private(set) var hasDeviceList = false
    private(set) var selected: PeerDeviceSummary?
    private(set) var driver: PeerDeviceDriver = .available
    let playback = PeerDevicePlayback()

    var status: String? {
        notice ?? selected?.availability.peerDeviceStatus ?? (attachment != nil && playback.displayedSize == nil ? "Waiting for video…" : nil)
    }

    var canTakeControl: Bool {
        guard selected?.access == .control, readyForInput, control == .viewing else { return false }
        if case .other = driver { return false }
        return true
    }

    var canSendInput: Bool { inputContext != nil }

    var inputContext: InputContext? {
        guard readyForInput, selected?.access == .control, let attachment, case .holding(let lease) = control,
              let generation = playback.displayedGeneration else { return nil }
        return InputContext(attachmentID: attachment.id, leaseGeneration: lease, formatGeneration: generation)
    }

    private var readyForInput: Bool {
        guard selected?.availability == .ready, let attachment, verifiedOrigin() == attachment.origin else { return false }
        return playback.displayedGeneration != nil
    }

    private let send: @MainActor (PeerDeviceRequest) -> Void
    private let verifiedOrigin: @MainActor () -> URL?
    private let openMedia: MediaOpener
    private var attachment: Attachment?
    private var control: Control = .viewing
    private var notice: String?
    @ObservationIgnored private var reopenOnList = false
    @ObservationIgnored private var active = false
    @ObservationIgnored private var mediaRecoveryAttempted = false
    @ObservationIgnored private var stopMedia: (@MainActor () -> Void)?
    @ObservationIgnored private var renewal: Task<Void, Never>?

    convenience init(send: @escaping @MainActor (PeerDeviceRequest) -> Void, verifiedOrigin: @escaping @MainActor () -> URL?) {
        self.init(send: send, verifiedOrigin: verifiedOrigin, openMedia: PeerDeviceMediaSocket.open)
    }

    init(send: @escaping @MainActor (PeerDeviceRequest) -> Void, verifiedOrigin: @escaping @MainActor () -> URL?,
         openMedia: @escaping MediaOpener) {
        self.send = send
        self.verifiedOrigin = verifiedOrigin
        self.openMedia = openMedia
        playback.onRecoveryNeeded = { [weak self] in
            guard let self, let attachment else { return }
            mediaEnded(attachment)
        }
    }

    isolated deinit {
        renewal?.cancel()
        stopMedia?()
    }

    func refresh() {
        active = true
        guard let origin = verifiedOrigin(), PeerDeviceMediaSocket.url(on: origin) != nil else {
            endAttachment(notifyHost: false)
            reopenOnList = false
            notice = "Host unreachable."
            return
        }
        reopenOnList = attachment == nil && selected != nil
        if attachment == nil {
            notice = nil
            mediaRecoveryAttempted = false
        }
        send(.list)
    }

    func select(_ device: PeerDeviceSummary) {
        active = true
        if selected?.id == device.id, attachment != nil { return }
        reopenOnList = false
        endAttachment(notifyHost: true)
        selected = device
        driver = device.driver == .you ? .available : device.driver
        notice = nil
        mediaRecoveryAttempted = false
        attachSelection()
    }

    func close() {
        active = false
        reopenOnList = false
        endAttachment(notifyHost: true)
        selected = nil
        devices = []
        hasDeviceList = false
        driver = .available
        notice = nil
    }

    func connectionChanged() {
        guard active else { return }
        // Even the same origin may now be a new authenticated control socket.
        endAttachment(notifyHost: false)
        devices = []
        hasDeviceList = false
        driver = .available
        refresh()
    }

    func receive(_ event: PeerDeviceEvent) {
        guard active, let origin = verifiedOrigin(), attachment.map({ $0.origin == origin }) ?? true else { return }
        switch event {
        case .list(let list):
            receiveList(list)
        case .attached(let id, let ticket):
            guard let attachment, attachment.id == id, stopMedia == nil else { return }
            notice = nil
            let stop = openMedia(attachment.origin, ticket, { [weak self] packet in
                self?.receiveVideo(packet, attachment: attachment)
            }, { [weak self] in
                self?.mediaEnded(attachment)
            })
            if self.attachment == attachment { stopMedia = stop } else { stop() }
        case .control(let id, let driver, let generation):
            guard id == attachment?.id else { return }
            if driver == .you {
                guard control == .requesting || control == .holding(generation), selected?.access == .control else { return }
                self.driver = .you
                control = .holding(generation)
                notice = nil
                if renewal == nil { renewControl(id, generation: generation) }
            } else {
                self.driver = driver
                if control != .requesting && control != .viewing {
                    notice = nil
                    clearControl()
                }
            }
        case .refused(let id, let reason):
            guard id == attachment?.id else { return }
            if stopMedia == nil && control == .viewing { endAttachment(notifyHost: false) }
            if control == .requesting || control == .releasing { clearControl() }
            notice = reason
        case .detached(let id, let reason):
            guard id == attachment?.id else { return }
            endAttachment(notifyHost: false)
            notice = reason
        }
    }

    func takeControl() {
        guard canTakeControl, let attachment else { return }
        control = .requesting
        notice = "Requesting control…"
        send(.takeControl(attachmentID: attachment.id))
    }

    func releaseControl() {
        guard let attachment, control != .viewing, control != .releasing else { return }
        clearControl()
        control = .releasing
        if driver == .you { driver = .available }
        notice = nil
        if verifiedOrigin() == attachment.origin { send(.releaseControl(attachmentID: attachment.id)) }
    }

    func input(_ event: PeerDeviceInput) {
        guard let context = inputContext else { return }
        send(.input(attachmentID: context.attachmentID, leaseGeneration: context.leaseGeneration,
                    formatGeneration: context.formatGeneration, event: event))
    }

    private func receiveList(_ list: [PeerDeviceSummary]) {
        hasDeviceList = true
        devices = list
        let reopen = reopenOnList
        reopenOnList = false
        guard let previous = selected else { return }
        guard let device = list.first(where: { $0.id == previous.id }) else {
            endAttachment(notifyHost: true)
            selected = nil
            driver = .available
            notice = "This device is no longer shared."
            return
        }
        selected = device
        driver = device.driver == .you ? driver : device.driver
        if device.driver != .you, case .holding = control { clearControl() }
        if device.availability != .ready {
            endAttachment(notifyHost: true)
            notice = nil
        } else if attachment == nil, reopen || previous.availability != .ready {
            mediaRecoveryAttempted = false
            attachSelection()
        } else if device.access == .view, previous.access == .control {
            releaseControl()
        }
    }

    private func attachSelection() {
        guard let selected else { return }
        guard let origin = verifiedOrigin(), PeerDeviceMediaSocket.url(on: origin) != nil else {
            notice = "Host unreachable."
            return
        }
        guard selected.availability == .ready else { return }
        let attachment = Attachment(id: UUID(), origin: origin)
        self.attachment = attachment
        notice = "Opening device…"
        send(.attach(deviceID: selected.id, attachmentID: attachment.id))
    }

    private func endAttachment(notifyHost: Bool) {
        let old = attachment
        attachment = nil
        clearControl()
        if driver == .you { driver = .available }
        let stop = stopMedia
        stopMedia = nil
        stop?()
        playback.reset()
        if notifyHost, let old, verifiedOrigin() == old.origin { send(.detach(attachmentID: old.id)) }
    }

    private func receiveVideo(_ packet: PeerDeviceVideoPacket, attachment: Attachment) {
        guard self.attachment == attachment, verifiedOrigin() == attachment.origin else { return }
        if playback.displayedGeneration != nil { mediaRecoveryAttempted = false }
        switch playback.receive(packet) {
        case .accepted:
            switch packet {
            case .format, .config:
                // The view no longer represents the frame that armed a held gesture.
                releaseControl()
            case .frame:
                break
            }
        case .waiting:
            break
        case .failed:
            mediaEnded(attachment)
        }
    }

    private func mediaEnded(_ attachment: Attachment) {
        guard self.attachment == attachment else { return }
        if playback.displayedGeneration != nil { mediaRecoveryAttempted = false }
        endAttachment(notifyHost: true)
        notice = "Video interrupted."
        if !mediaRecoveryAttempted {
            mediaRecoveryAttempted = true
            // Retry once without a lease. A second failure before video resumes
            // stays visible, rather than repeatedly opening a broken attachment.
            attachSelection()
        }
    }

    private func clearControl() {
        control = .viewing
        renewal?.cancel()
        renewal = nil
    }

    private func renewControl(_ id: UUID, generation: UInt64) {
        renewal = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, let attachment, attachment.id == id, verifiedOrigin() == attachment.origin,
                      control == .holding(generation) else { return }
                send(.renewControl(attachmentID: id, generation: generation))
            }
        }
    }
}

extension PeerDeviceAvailability {
    var peerDeviceStatus: String? {
        switch self {
        case .ready: nil
        case .absent: "Android device disconnected."
        case .unauthorized: "Authorize USB debugging on the Android device."
        case .offline: "Android device is offline."
        case .interrupted: "Android capture interrupted."
        }
    }
}

@MainActor
final class PeerDeviceMediaSocket {
    final class RedirectRefusal: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session = URLSession(configuration: .ephemeral, delegate: RedirectRefusal(), delegateQueue: nil)

    static func url(on origin: URL) -> URL? {
        guard var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { return nil }
        parts.scheme = "wss"
        parts.path = "/ws/device-media"
        return parts.url
    }

    static func open(origin: URL, ticket: String, packet: @escaping @MainActor (PeerDeviceVideoPacket) -> Void,
                     ended: @escaping @MainActor () -> Void) -> (@MainActor () -> Void) {
        guard let url = url(on: origin), ticket.utf8.count == 43, ticket.utf8.allSatisfy({ byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
        }) else {
            ended()
            return {}
        }
        let socket = session.webSocketTask(with: url, protocols: [ticket])
        socket.maximumMessageSize = PeerDeviceVideoPacket.maxPacketBytes
        socket.resume()
        let reader = Task { @MainActor in
            while !Task.isCancelled {
                guard let message = try? await socket.receive(), !Task.isCancelled,
                      case .data(let data) = message, let decoded = PeerDeviceVideoPacket(binary: data) else { break }
                packet(decoded)
            }
            if !Task.isCancelled { ended() }
        }
        let keepalive = Task { @MainActor in
            let ping = Ping()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                if ping.pending {
                    socket.cancel(with: .goingAway, reason: nil)
                    return
                }
                ping.pending = true
                socket.sendPing { error in
                    Task { @MainActor in
                        if error != nil { socket.cancel(with: .goingAway, reason: nil) }
                        ping.pending = false
                    }
                }
            }
        }
        return {
            reader.cancel()
            keepalive.cancel()
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    @MainActor
    private final class Ping {
        var pending = false
    }
}
