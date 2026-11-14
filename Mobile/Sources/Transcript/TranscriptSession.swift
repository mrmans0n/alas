import AlasRemoteKit
import Observation
import UIKit

/// One transcript row as the scroller shows it. `id` is the message's `stableId`; the scroller
/// reconfigures the row when `message` changes.
struct TranscriptItem: Identifiable, Equatable {
    let id: String
    let row: RemoteTranscriptRow
    let message: RemoteWireMessage

    init(message: RemoteWireMessage) {
        id = message.stableId
        row = RemoteTranscriptRow(message: message)
        self.message = message
    }
}

/// A live subscription to one session's transcript on one host. Frames for the session go
/// through the shared sync state machine; the scroller reads `items`.
@MainActor @Observable
final class TranscriptSession {
    private(set) var items: [TranscriptItem] = []
    var expanded: Set<String> = []
    var canLoadOlder = false
    /// True once the first snapshot arrived, so an empty transcript can say so.
    private(set) var hasSnapshot = false
    private(set) var isClosed = false
    private(set) var streamingState = "idle"

    let hostID: UUID
    let sessionId: String

    @ObservationIgnored private let hub: HostHub
    @ObservationIgnored private var state: RemoteTranscriptState<OpaqueHostMessage, OpaqueHostMessage>
    @ObservationIgnored private var shownGeneration: UInt64?
    @ObservationIgnored private var fetchingOlder = false
    @ObservationIgnored private var listener: ListenerToken?
    @ObservationIgnored private var hostWatch: Task<Void, Never>?
    @ObservationIgnored private var lastSummary: RemoteSessionSummary?

    private enum LoadedImage {
        case image(UIImage)
        case unavailable
    }

    private var images: [String: LoadedImage] = [:]
    @ObservationIgnored private var requestedImages: Set<String> = []

    init(hub: HostHub, hostID: UUID, sessionId: String) {
        self.hub = hub
        self.hostID = hostID
        self.sessionId = sessionId
        state = RemoteTranscriptState(sessionId: sessionId)
    }

    /// The session as the hub last listed it. Kept after it leaves the list, so an ended
    /// session keeps its title.
    var summary: RemoteSessionSummary? {
        if let current = hub.sessions(of: hostID).first(where: { $0.id == sessionId }) {
            lastSummary = current
            return current
        }
        return lastSummary
    }

    /// Closed by the host, or gone from its session list.
    var hasEnded: Bool {
        isClosed || !hub.sessions(of: hostID).contains { $0.id == sessionId }
    }

    isolated deinit {
        hostWatch?.cancel()
    }

    func open() {
        guard listener == nil else { return }
        listener = hub.addListener(hostID) { [weak self] message in
            self?.receive(message)
        }
        hub.send(.subscribe(sessionId: sessionId), to: hostID)
        watchHost()
    }

    func close() {
        guard listener != nil else { return }
        hub.send(.unsubscribe(sessionId: sessionId), to: hostID)
        listener = nil
        hostWatch?.cancel()
        hostWatch = nil
    }

    func loadOlder() {
        guard !fetchingOlder, let before = state.olderPageBeforeIndex,
              hub.state(of: hostID) == .online else { return }
        fetchingOlder = true
        hub.send(.fetchOlder(sessionId: sessionId, beforeIndex: before, limit: 90), to: hostID)
        refreshCanLoadOlder()
    }

    /// The image's bytes once they arrive. The first call for a path asks the host for them.
    func image(for path: String) -> UIImage? {
        switch images[path] {
        case .image(let image): return image
        case .unavailable: return nil
        case nil:
            if requestedImages.insert(path).inserted {
                hub.send(.readTranscriptImage(sessionId: sessionId, path: path), to: hostID)
            }
            return nil
        }
    }

    /// Resubscribes each time the host comes back online. `Observations` re-reads the hub's
    /// state after every change, so no connection event needs forwarding to listeners.
    private func watchHost() {
        let hub = hub
        let hostID = hostID
        let initiallyOnline = hub.state(of: hostID) == .online
        hostWatch = Task { [weak self] in
            var wasOnline = initiallyOnline
            for await state in Observations({ @MainActor in hub.state(of: hostID) }) {
                let online = state == .online
                defer { wasOnline = online }
                guard online, !wasOnline else { continue }
                guard let self else { return }
                self.resubscribe()
            }
        }
    }

    private func resubscribe() {
        state.resetResubscribeRequest()
        // A page request or image read sent before a reconnect has no reply coming.
        fetchingOlder = false
        requestedImages = requestedImages.filter { images[$0] != nil }
        hub.send(.subscribe(sessionId: sessionId), to: hostID)
        refreshCanLoadOlder()
    }

    private func receive(_ message: PhoneServerMessage) {
        switch message {
        case .transcriptImage(let id, let path, let data) where id == sessionId:
            images[path] = data.flatMap(UIImage.init(data:)).map { .image(Self.thumbnail($0)) } ?? .unavailable
            return
        case .transcriptSnapshot(let id, _, _, _, _, _, _, _, _) where id == sessionId,
             .transcriptPage(let id, _, _, _) where id == sessionId:
            fetchingOlder = false
        default:
            break
        }
        if state.apply(message) {
            state.resetResubscribeRequest()
            hub.send(.subscribe(sessionId: sessionId), to: hostID)
        }
        publish()
    }

    /// Copies what the screen reads out of the sync state, rebuilding `items` only when the
    /// rows changed and reusing every item whose message did not.
    private func publish() {
        if state.messagesGeneration != shownGeneration {
            shownGeneration = state.messagesGeneration
            let previous = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
            items = state.messages.map { message in
                if let old = previous[message.stableId], old.message == message { return old }
                return TranscriptItem(message: message)
            }
        }
        if hasSnapshot != (state.epoch != nil) { hasSnapshot = state.epoch != nil }
        if isClosed != state.isClosed { isClosed = state.isClosed }
        if streamingState != state.streamingState { streamingState = state.streamingState }
        refreshCanLoadOlder()
    }

    /// Downscaled once on arrival, so a cell never decodes a full-size photo while scrolling.
    /// 288 px fills the row's 96 pt square at 3x.
    private static func thumbnail(_ image: UIImage) -> UIImage {
        let scale = 288 / min(image.size.width, image.size.height)
        guard scale < 1 else { return image }
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return image.preparingThumbnail(of: size) ?? image
    }

    private func refreshCanLoadOlder() {
        let can = !fetchingOlder && state.olderPageBeforeIndex != nil
        if canLoadOlder != can { canLoadOlder = can }
    }
}
