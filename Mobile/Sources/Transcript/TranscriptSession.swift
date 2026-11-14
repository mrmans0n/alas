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
    @ObservationIgnored private var subscription: ListenerToken?
    @ObservationIgnored private var hostWasOnline = false
    /// Bumped on open and close, so a watch left over from an earlier open stops.
    @ObservationIgnored private var watchGeneration = 0
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

    var hostName: String {
        hub.hosts.first { $0.id == hostID }?.name ?? "your Mac"
    }

    var hostState: PhoneConnection.State {
        hub.state(of: hostID)
    }

    /// Closed by the host, gone from its session list, or listed as no longer open.
    var hasEnded: Bool {
        isClosed || hub.sessions(of: hostID).first { $0.id == sessionId }?.isActive != true
    }

    func open() {
        guard listener == nil else { return }
        listener = hub.addListener(hostID) { [weak self] message in
            self?.receive(message)
        }
        subscription = hub.subscribe(sessionId, on: hostID)
        hostWasOnline = hub.state(of: hostID) == .online
        watchGeneration += 1
        watchHost(generation: watchGeneration)
    }

    func close() {
        guard listener != nil else { return }
        subscription = nil
        listener = nil
        watchGeneration += 1
        MarkdownBlockCache.shared.remove(ids: items.map(\.id))
        // Unanswered reads die with the subscription; a reopened row asks again.
        requestedImages = requestedImages.filter { images[$0] != nil }
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

    /// Resubscribes each time the host comes back online. Observation tracking re-reads the
    /// hub's state after every change, so no connection event needs forwarding to listeners.
    /// (Not `Observations`: Swift 6.3.3, in CI's Xcode 26.6, crashes compiling that closure.)
    private func watchHost(generation: Int) {
        guard generation == watchGeneration else { return }
        let online = withObservationTracking {
            hub.state(of: hostID) == .online
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchHost(generation: generation) }
        }
        defer { hostWasOnline = online }
        if online, !hostWasOnline { resubscribe() }
    }

    private func resubscribe() {
        state.resetResubscribeRequest()
        // A page request or image read sent before a reconnect has no reply coming, and
        // rows whose messages are unchanged won't ask again, so resend the unanswered reads.
        fetchingOlder = false
        hub.send(.subscribe(sessionId: sessionId), to: hostID)
        for path in requestedImages where images[path] == nil {
            hub.send(.readTranscriptImage(sessionId: sessionId, path: path), to: hostID)
        }
        refreshCanLoadOlder()
    }

    private func receive(_ message: PhoneServerMessage) {
        switch message {
        case .transcriptImage(let id, let path, let data) where id == sessionId:
            Task { [weak self] in
                let image = await Self.thumbnail(data)
                self?.images[path] = image.map(LoadedImage.image) ?? .unavailable
            }
            return
        case .transcriptSnapshot(let id, _, _, _, _, _, _, _, _) where id == sessionId,
             .transcriptPage(let id, _, _, _) where id == sessionId:
            fetchingOlder = false
        default:
            break
        }
        // The latch stays set until the fresh snapshot clears it, so the out-of-order deltas
        // still in flight do not each ask again. Released only when the ask could not go out.
        if state.apply(message) {
            if hub.state(of: hostID) == .online {
                hub.send(.subscribe(sessionId: sessionId), to: hostID)
            } else {
                state.resetResubscribeRequest()
            }
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

    /// Decoded and downscaled off the main actor, once on arrival, so neither the frame handler
    /// nor a cell decodes a full-size photo. 288 px fills the row's 96 pt square at 3x.
    @concurrent
    private nonisolated static func thumbnail(_ data: Data?) async -> UIImage? {
        guard let data, let image = UIImage(data: data) else { return nil }
        let scale = 288 / min(image.size.width, image.size.height)
        let size = scale < 1 ? CGSize(width: image.size.width * scale, height: image.size.height * scale) : image.size
        return await image.byPreparingThumbnail(ofSize: size) ?? image
    }

    private func refreshCanLoadOlder() {
        let can = !fetchingOlder && state.olderPageBeforeIndex != nil
        if canLoadOlder != can { canLoadOlder = can }
    }
}
