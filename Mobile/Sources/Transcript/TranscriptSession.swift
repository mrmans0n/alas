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

struct StagedImage: Identifiable {
    let id: UUID
    let data: Data
    let mimeType: String
    let thumbnail: UIImage
}

/// What the user is composing. Lives on the session so it outlives the screen and reconnects.
struct ComposerDraft {
    var text = ""
    var images: [StagedImage] = []
    var mentions: [RemoteMention] = []
}

enum RequestKind {
    case permission, question, plan, elicitation
}

enum QueueAction {
    case forceSend(String), remove(String), retry(String), edit(String), clear
    case move(String, to: String)
    case promote(String)
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
    private(set) var config: RemoteSessionConfig?
    /// Every queued item; views apply `RemoteQueueRules`.
    private(set) var queue: [RemoteQueuedPrompt] = []
    private(set) var canDrive = false
    private(set) var permission: RemotePermissionPayload?
    private(set) var question: RemoteQuestionPayload?
    private(set) var plan: RemotePlanPayload?
    private(set) var elicitation: RemoteElicitationPayload?
    /// Bumped per kind when the shown request is replaced by a different one, so a card keys its
    /// state on the request rather than its wire id, which can repeat.
    private(set) var requestRevisions: [RequestKind: Int] = [:]
    /// Kinds whose shown request was answered here; their cards hide until a different one arrives.
    private(set) var answered: Set<RequestKind> = []
    @ObservationIgnored private var replacedAt: [RequestKind: ContinuousClock.Instant] = [:]
    private(set) var isStopping = false
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    /// Answers given while another device drove. A take-over makes the host forget its request
    /// ids and surface the pending requests again, so an answer sent right behind it is dropped;
    /// each waits here until its request is back, then goes out under the id it now has.
    @ObservationIgnored private var deferredAnswers: [RequestKind: () -> PhoneClientMessage?] = [:]
    private(set) var hasCancellableBackgroundWork = false
    var rejection: String?
    /// Candidates for `mentionCandidatesQuery`, or for an earlier query while a new one is in flight.
    private(set) var mentionCandidates: [RemoteMention] = []
    /// The query `mentionCandidates` answers; nil while a new query is in flight.
    private(set) var mentionCandidatesQuery: String?
    var draft = ComposerDraft()

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
    @ObservationIgnored private var stopGeneration = 0
    /// Sent drafts the host has neither shown nor refused, oldest first. The host settles prompts
    /// in the order they arrive, so a rejection belongs to the oldest; once a prompt shows up in the
    /// queue or transcript, a later rejection (its turn failed) has no draft to restore.
    @ObservationIgnored private var unsettled: [Unsettled] = []

    /// Only rows and queue items the host adds after the send can show it: a take-over replays
    /// the whole transcript first, and older prompts may share the text.
    private struct Unsettled {
        let draft: ComposerDraft
        let rowFloor: Int
        let priorQueue: Set<String>
    }
    @ObservationIgnored private var lastMentionQuery: String?
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
        guard subscription == nil else { return }
        if listener == nil {
            listener = hub.addListener(hostID) { [weak self] message in
                self?.receive(message)
            }
        }
        forgetTransientState()
        subscription = hub.subscribe(sessionId, on: hostID)
        hostWasOnline = hub.state(of: hostID) == .online
        watchGeneration += 1
        watchHost(generation: watchGeneration)
    }

    func close() {
        guard subscription != nil else { return }
        subscription = nil
        // The host refuses a prompt over the connection, subscribed or not: keep listening
        // until every sent draft has an outcome, so a refusal still lands in the draft.
        if unsettled.isEmpty { listener = nil }
        watchGeneration += 1
        MarkdownBlockCache.shared.remove(ids: items.map(\.id))
        // Unanswered reads die with the subscription; a reopened row asks again.
        requestedImages = requestedImages.filter { images[$0] != nil }
    }

    func send(intent: String) {
        let text = draft.text
        let attachments = draft.images.map {
            RemoteAttachment(name: nil, mimeType: $0.mimeType, dataBase64: $0.data.base64EncodedString())
        }
        let mentions = Array(RemoteComposerText.liveMentions(draft.mentions, in: text)
            .prefix(RemoteAttachmentLimits.maxMentionCount))
        rejection = nil
        let sent = drive(.sendPrompt(sessionId: sessionId, text: text, attachments: attachments, intent: intent, mentions: mentions),
                         offline: "Your message wasn't sent.")
        guard sent else { return }
        unsettled.append(Unsettled(draft: draft, rowFloor: state.totalCount, priorQueue: Set(state.queue.map(\.id))))
        draft = ComposerDraft()
    }

    func stop() { hub.send(.stop(sessionId: sessionId), to: hostID) }

    func takeOver() { hub.send(.takeOver(sessionId: sessionId), to: hostID) }

    func queue(_ action: QueueAction) {
        let id = sessionId
        switch action {
        case .forceSend(let item): drive(.queueForceSend(sessionId: id, itemId: item))
        case .remove(let item): drive(.queueRemove(sessionId: id, itemId: item))
        case .retry(let item): drive(.queueRetry(sessionId: id, itemId: item))
        case .edit(let item): drive(.queueEdit(sessionId: id, itemId: item))
        case .clear: drive(.queueClear(sessionId: id))
        case .move(let item, let target): drive(.queueMove(sessionId: id, itemId: item, targetItemId: target))
        case .promote(let item): drive(.queuePromote(sessionId: id, itemId: item))
        }
    }

    func answerPermission(optionId: String) {
        guard let permission, accepts(.permission) else { return }
        let id = sessionId
        answer(.permission, permission, current: { [weak self] in self?.state.pendingPermission }) {
            .permissionDecision(sessionId: id, requestId: $0.requestId, optionId: optionId, persistScope: nil)
        }
    }

    func answerQuestion(_ answers: [RemoteQuestionAnswer]) {
        guard let question, accepts(.question) else { return }
        let id = sessionId
        answer(.question, question, current: { [weak self] in self?.state.pendingQuestion }) {
            .questionAnswer(sessionId: id, requestId: $0.requestId, answers: answers)
        }
    }

    func answerPlan(action: String, reason: String?) {
        guard let plan, accepts(.plan) else { return }
        let id = sessionId
        answer(.plan, plan, current: { [weak self] in self?.state.pendingPlan }) {
            .planResponse(sessionId: id, requestId: $0.requestId, action: action, reason: reason)
        }
    }

    func answerElicitation(action: String, content: [String: ACPElicitationValue]?) {
        guard let elicitation, accepts(.elicitation) else { return }
        let id = sessionId
        answer(.elicitation, elicitation, current: { [weak self] in self?.state.pendingElicitation }) {
            .elicitationResponse(sessionId: id, requestId: $0.requestId, action: action, content: content)
        }
    }

    /// Sends the answer now when this phone drives; otherwise takes over and defers it until
    /// the same request (same content, any id) is pending again under the new lease.
    private func answer<P: Encodable>(_ kind: RequestKind, _ shown: P, current: @escaping () -> P?,
                                      message: @escaping (P) -> PhoneClientMessage) {
        if state.canDrive {
            if drive(message(shown)) { answered.insert(kind) }
            return
        }
        guard hub.state(of: hostID) == .online else {
            rejection = "\(hostName) is offline. Nothing was sent."
            return
        }
        let identity = Self.requestIdentity(shown)
        deferredAnswers[kind] = {
            guard let now = current(), Self.requestIdentity(now) == identity else { return nil }
            return message(now)
        }
        answered.insert(kind)
        takeOver()
    }

    private func sendDeferredAnswers() {
        guard state.canDrive, !deferredAnswers.isEmpty else { return }
        for (kind, build) in deferredAnswers {
            guard let message = build() else { continue }
            deferredAnswers[kind] = nil
            // A changed id made the card look new; it is answered.
            answered.insert(kind)
            hub.send(message, to: hostID)
        }
    }

    /// A request's content without its wire id, which a fresh follow may change.
    private static func requestIdentity<P: Encodable>(_ payload: P) -> Data? {
        guard let data = try? JSONEncoder().encode(payload),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        object["requestId"] = nil
        return try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }

    /// False once answered, and briefly after the request changed under the user's finger.
    private func accepts(_ kind: RequestKind) -> Bool {
        guard !answered.contains(kind) else { return false }
        guard let replaced = replacedAt[kind] else { return true }
        return replaced.duration(to: .now) >= .milliseconds(500)
    }

    func setModel(_ modelId: String) { drive(.setModel(sessionId: sessionId, modelId: modelId)) }

    func setMode(_ modeId: String) { drive(.setMode(sessionId: sessionId, modeId: modeId)) }

    func setAutoRun(_ enabled: Bool) {
        guard drive(.setAutoRun(sessionId: sessionId, enabled: enabled)) else { return }
        state.applyOptimisticAutoRun(enabled)
        publish()
    }

    func setConfigOption(_ configId: String, value: ACPConfigValue) {
        guard drive(.setConfigOption(sessionId: sessionId, configId: configId, value: value)) else { return }
        if case .boolean(let on) = value {
            state.applyOptimistic(configId: configId, value: on)
            publish()
        }
    }

    /// Not a lease verb: the host lets any follower rename.
    func rename(_ title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        hub.send(.renameSession(sessionId: sessionId, title: title), to: hostID)
    }

    /// The caller debounces.
    func searchMentions(_ query: String) {
        lastMentionQuery = query
        // The previous rows stay up, dimmed, until the answer arrives.
        mentionCandidatesQuery = nil
        hub.send(.searchMentions(sessionId: sessionId, query: query), to: hostID)
    }

    /// Verbs that need the writer lease ask for it first when this phone does not hold it.
    /// False, with `rejection` set, when the host is offline and nothing was sent.
    @discardableResult
    private func drive(_ message: PhoneClientMessage, offline: String = "Nothing was sent.") -> Bool {
        guard hub.state(of: hostID) == .online else {
            rejection = "\(hostName) is offline. \(offline)"
            return false
        }
        if !state.canDrive { takeOver() }
        hub.send(message, to: hostID)
        return true
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

    /// The host re-sends on subscribe only the requests it still has outstanding, and resolves
    /// only those its connection remembers, so anything held from before could be stale for good.
    /// The hold in `publish()` keeps a card through the host's re-send, so nothing flashes.
    private func forgetTransientState() {
        state.clearPendingRequests()
        // A request answered but refused comes back identical; show it again. The hold restarts so
        // the re-send gets the full grace period.
        answered = []
        replacedAt = [:]
        deferredAnswers = [:]
        holdTask?.cancel()
        holdTask = nil
        isStopping = false
        mentionCandidates = []
        mentionCandidatesQuery = nil
        publish()
    }

    /// Drops each unsettled draft the host now shows in a row or queue item added since its send.
    /// A user row appends attachment labels after the text, and the host trims what it records.
    private func settle(rows: [RemoteWireMessage] = [], queued: [RemoteQueuedPrompt] = []) {
        unsettled.removeAll { sent in
            let text = sent.draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let images = sent.draft.images.count
            return rows.contains { $0.kind == "user" && $0.index >= sent.rowFloor && ($0.text ?? "").hasPrefix(text) }
                || queued.contains { !sent.priorQueue.contains($0.id) && $0.text == text && $0.imageCount == images }
        }
    }

    private func resubscribe() {
        state.resetResubscribeRequest()
        // A page request or image read sent before a reconnect has no reply coming, and
        // rows whose messages are unchanged won't ask again, so resend the unanswered reads.
        fetchingOlder = false
        forgetTransientState()
        hub.send(.subscribe(sessionId: sessionId), to: hostID)
        for path in requestedImages where images[path] == nil {
            hub.send(.readTranscriptImage(sessionId: sessionId, path: path), to: hostID)
        }
        refreshCanLoadOlder()
    }

    private func receive(_ message: PhoneServerMessage) {
        // Closed, the listener stays only for the outcome of sent prompts.
        if subscription == nil {
            guard case .promptRejected(let id, _) = message, id == sessionId else { return }
        }
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
            if case .transcriptSnapshot(_, _, _, let rows, _, _, _, _, _) = message { settle(rows: rows) }
        case .transcriptDelta(let id, _, _, let rows, _, _, _) where id == sessionId:
            settle(rows: rows)
        case .stopPending(let id) where id == sessionId:
            isStopping = true
            stopGeneration += 1
            let generation = stopGeneration
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                if let self, generation == stopGeneration { isStopping = false }
            }
        case .promptRejected(let id, let reason) where id == sessionId:
            if !unsettled.isEmpty {
                // Ahead of what the user typed since, as the Mac does, so neither is lost.
                let rejected = unsettled.removeFirst().draft
                draft = ComposerDraft(
                    text: [rejected.text, draft.text].filter { !$0.isEmpty }.joined(separator: "\n"),
                    images: rejected.images + draft.images,
                    mentions: rejected.mentions + draft.mentions)
            }
            rejection = reason ?? state.config?.agentIssue?.message ?? "The host refused this prompt."
            if subscription == nil, unsettled.isEmpty { listener = nil }
        case .queueEditRestored(let id, _, let text) where id == sessionId:
            draft.text += draft.text.isEmpty ? text : "\n" + text
        case .mentionCandidates(let id, let query, let candidates) where id == sessionId:
            if query == lastMentionQuery {
                mentionCandidates = candidates
                mentionCandidatesQuery = query
            }
            return
        case .error(let message, let id) where id == sessionId:
            rejection = message
        case .queueState(let id, let queued) where id == sessionId:
            settle(queued: queued)
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
        if streamingState == "idle", isStopping { isStopping = false }
        if hasCancellableBackgroundWork != state.hasCancellableBackgroundWork {
            hasCancellableBackgroundWork = state.hasCancellableBackgroundWork
        }
        if config != state.config { config = state.config }
        if queue != state.queue { queue = state.queue }
        if canDrive != state.canDrive { canDrive = state.canDrive }
        var holding = settle(\.permission, state.pendingPermission, .permission)
        holding = settle(\.question, state.pendingQuestion, .question) || holding
        holding = settle(\.plan, state.pendingPlan, .plan) || holding
        holding = settle(\.elicitation, state.pendingElicitation, .elicitation) || holding
        sendDeferredAnswers()
        if holding, holdTask == nil {
            holdTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                holdTask = nil
                permission = state.pendingPermission
                question = state.pendingQuestion
                plan = state.pendingPlan
                elicitation = state.pendingElicitation
                if permission == nil { answered.remove(.permission) }
                if question == nil { answered.remove(.question) }
                if plan == nil { answered.remove(.plan) }
                if elicitation == nil { answered.remove(.elicitation) }
            }
        }
        refreshCanLoadOlder()
    }

    /// A request that resolves is kept briefly: on a resubscribe or take-over the host resolves
    /// it and re-sends it in separate frames, and a card that vanished between them would lose
    /// what the user typed. Returns true while a resolved request is still being held.
    private func settle<T: Equatable>(_ shown: ReferenceWritableKeyPath<TranscriptSession, T?>, _ new: T?,
                                      _ kind: RequestKind) -> Bool {
        if let new {
            let old = self[keyPath: shown]
            if old != new {
                self[keyPath: shown] = new
                requestRevisions[kind, default: 0] += 1
                answered.remove(kind)
                if old != nil { replacedAt[kind] = .now }
            }
            return false
        }
        return self[keyPath: shown] != nil
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
