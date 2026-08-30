import Foundation
import Combine

/// Narrow observable holder for the rapidly-mutating slice of session
/// state (transcript + stream state + pending permission). Lives inside
/// `ACPSession`. Views that only care about the transcript can observe
/// this instead of the full `ACPSession`, so updates to model/mode/setup
/// state no longer invalidate the message list.
@MainActor
final class ACPTranscript: ObservableObject {
    @Published var messages: [ACPMessage] = [] {
        didSet {
            synchronizeMessageCreatedAts()
            messagesGeneration &+= 1
            updatePlanCaches(for: pendingMessagesMutation)
            updateMessageIndexCaches(for: pendingMessagesMutation)
            pendingMessagesMutation = nil
            recordMessagesDiff(old: oldValue)
        }
    }
    private enum MessagesMutation {
        case append(ACPMessage)
        case replace(index: Int, old: ACPMessage, new: ACPMessage)
        case prepend(count: Int)
        case planNeutral
    }
    private var pendingMessagesMutation: MessagesMutation?
    private var latestPlanMessageIndex: Int?
    private var latestUserMessageIndex: Int?
    enum TextMessageKind: Hashable {
        case user
        case agent
        case thought
    }
    private struct TextMessageKey: Hashable {
        let kind: TextMessageKind
        let messageId: String
    }
    private var textMessageIndices: [TextMessageKey: Int] = [:]
    private var toolCallIndices: [String: Int] = [:]
    #if DEBUG
    private(set) var planCacheRebuildCountForTests = 0
    private(set) var messageIndexCacheRebuildCountForTests = 0
    #endif
    /// Bumped on every `messages` array mutation. Non-published: consumed by
    /// value caches (visible-rows lookup) that must invalidate when the array
    /// changes, without adding another objectWillChange source.
    private(set) var messagesGeneration: UInt64 = 0
    /// Mutation log consumed by remote-web gateways for incremental deltas.
    /// Recording is enabled only while at least one gateway is subscribed.
    let changeLog = ACPTranscriptChangeLog()
    @Published var streamingState: ACPSession.StreamingState = .idle
    @Published var pendingPermission: ACPSession.PendingPermission?
    @Published var pendingQuestion: ACPSession.PendingQuestion?
    @Published var pendingUserInputs: [ACPUserInputRequest] = []
    @Published var urlElicitationWaits: [ACPURLElicitationWait] = []
    /// Items of the plan emitted for the current turn. Updated when the
    /// transcript array changes so high-frequency streaming ticks do not scan
    /// the full message list from `ACPSessionView` / plan UI bodies.
    @Published private(set) var currentPlan: [ACPMessage.PlanItem]?
    /// Tick incremented on every streaming chunk that mutates an existing
    /// agent/thought buffer. The buffer itself publishes (so the row's
    /// inner Text re-renders), but the transcript array doesn't change —
    /// without this tick, `ACPMessageList`'s body wouldn't re-evaluate
    /// and the tail-scroll signature wouldn't recompute, so long replies
    /// drift below the viewport mid-stream. Body re-eval is cheap because
    /// stableId + StreamingText identity equality keep the ForEach row
    /// tree stable across ticks.
    @Published var streamingTick: UInt32 = 0
    /// Wall-clock time (`ProcessInfo.systemUptime`) of the last `streamingTick`
    /// publish. Used to throttle publishes to `streamingTickMinInterval`.
    private var lastStreamingTickPublish: TimeInterval = 0
    /// Pending trailing-edge publish scheduled when a chunk arrives inside
    /// the throttle window. Guarantees the last chunk of a fast burst still
    /// produces a publish even if no further chunk arrives to trigger one.
    private var streamingTickDrain: Task<Void, Never>?
    /// True while post-hydration tail-first backfill is materialising older
    /// persisted rows. This is separate from `visibleHead`: a non-zero head
    /// means older rows are available behind the render window, not that an
    /// async load is still running.
    @Published var isBackfillingOlderMessages: Bool = false

    /// Number of known persisted messages that precede `messages[0]` while
    /// tail-first hydration is still materialising the older prefix. This is
    /// deliberately non-published: mutation entry points update it before
    /// publishing the corresponding `messages` change, so observers always
    /// see one coherent local/global index mapping.
    private(set) var messageIndexOffset: Int = 0

    /// Total known transcript extent even during the tail-only first paint.
    var logicalMessageCount: Int { messageIndexOffset + messages.count }

    /// Render window: `ACPMessageList` draws `messages[visibleHead..<visibleTail]`.
    /// Reset to `max(0, messages.count - tailWindow)` after hydration so
    /// long transcripts paint quickly; user can scroll up or click the
    /// "Earlier messages…" affordance to reveal older rows in chunks of
    /// `tailWindow`.
    @Published var visibleHead: Int = 0
    /// Exclusive upper bound of the render window. `nil` means the live tail.
    /// Non-tail restored anchors use this to avoid asking SwiftUI to keep every
    /// newer transcript row in a single lazy-stack layout pass.
    @Published var visibleTail: Int?

    /// Number of rows revealed per backfill step. Tuned for chat-style
    /// content where a screenful is a few rows; bigger steps feel like
    /// loading state, smaller steps require too many clicks.
    static let tailWindow: Int = 30
    /// Upper bound for non-tail render windows. A few chunks gives enough room
    /// for natural scrolling while keeping `ForEach` input bounded.
    static let maxVisibleRows: Int = tailWindow * 3

    /// Stable ids of streaming text rows whose prompt has completed. A
    /// later ACP text chunk must start a fresh row instead of appending
    /// directly to any completed output.
    var completedOutputBoundaryMessageIds: Set<String> = []

    // MARK: - Per-message markdown caches

    private var markdownCaches: [String: ACPMarkdownBlockCache] = [:]
    private var stableIdCache: [ACPMessage.StableIdentityKey: String] = [:]
    private var messageCreatedAts: [String: Date] = [:]

    func stableId(for message: ACPMessage) -> String {
        let key = message.stableIdentityKey
        if let cached = stableIdCache[key] {
            return cached
        }
        let stableId = ACPMessage.stableId(for: key)
        stableIdCache[key] = stableId
        return stableId
    }

    func markdownCache(forMessage id: String) -> ACPMarkdownBlockCache {
        if let c = markdownCaches[id] { return c }
        let c = ACPMarkdownBlockCache()
        markdownCaches[id] = c
        return c
    }

    func dropMarkdownCache(forMessage id: String) {
        markdownCaches.removeValue(forKey: id)
    }

    #if DEBUG
    /// Sum of `byteEstimate` over every retained cache. Bounded by the number
    /// of messages with at least one render pass.
    var markdownCacheByteEstimate: UInt64 {
        markdownCaches.values.reduce(0) { $0 + $1.byteEstimate }
    }
    #endif

    /// Clear all per-message caches; call when the transcript itself is
    /// discarded (e.g. session close).
    func resetMarkdownCaches() {
        markdownCaches.removeAll()
        streamingTickDrain?.cancel()
        streamingTickDrain = nil
    }

    // MARK: - Incremental plan caches

    /// Production mutation entry points carry enough context for plan and
    /// message-index caches to update in O(1). Direct `messages` assignments
    /// remain supported for restore/test call sites and safely rebuild once.
    var currentPlanMessageIndex: Int? {
        guard let latestPlanMessageIndex,
              latestPlanMessageIndex > (latestUserMessageIndex ?? -1) else {
            return nil
        }
        return latestPlanMessageIndex
    }

    func createdAt(forStableId stableId: String) -> Date? {
        messageCreatedAts[stableId]
    }

    func createdAt(forMessageAt index: Int) -> Date? {
        guard messages.indices.contains(index) else { return nil }
        return createdAt(forStableId: stableId(for: messages[index]))
    }

    func appendMessage(_ message: ACPMessage, createdAt: Date = Date()) {
        messageCreatedAts[stableId(for: message)] = createdAt
        pendingMessagesMutation = .append(message)
        messages.append(message)
    }

    func replaceMessage(at index: Int, with message: ACPMessage) {
        let old = messages[index]
        let oldStableId = stableId(for: old)
        let newStableId = stableId(for: message)
        if oldStableId != newStableId {
            messageCreatedAts[newStableId] = messageCreatedAts[oldStableId] ?? Date()
            messageCreatedAts.removeValue(forKey: oldStableId)
        }
        pendingMessagesMutation = .replace(index: index, old: old, new: message)
        messages[index] = message
    }

    func replaceMessages(
        with newMessages: [ACPMessage],
        createdAts: [Date]? = nil,
        messageIndexOffset: Int = 0
    ) {
        let previousCreatedAts = messageCreatedAts
        messageCreatedAts.removeAll(keepingCapacity: true)
        for (index, message) in newMessages.enumerated() {
            let stableId = stableId(for: message)
            let createdAt = createdAts?.indices.contains(index) == true
                ? createdAts![index]
                : previousCreatedAts[stableId] ?? Date()
            messageCreatedAts[stableId] = createdAt
        }
        self.messageIndexOffset = max(0, messageIndexOffset)
        messages = newMessages
    }

    func prependMessages(_ older: [ACPMessage], createdAts: [Date]? = nil) {
        guard !older.isEmpty else { return }
        for (index, message) in older.enumerated() {
            let createdAt = createdAts?.indices.contains(index) == true
                ? createdAts![index]
                : Date()
            messageCreatedAts[stableId(for: message)] = createdAt
        }
        messageIndexOffset = max(0, messageIndexOffset - older.count)
        pendingMessagesMutation = .prepend(count: older.count)
        messages.insert(contentsOf: older, at: 0)
    }

    private func synchronizeMessageCreatedAts() {
        let stableIds = Set(messages.map { stableId(for: $0) })
        messageCreatedAts = messageCreatedAts.filter { stableIds.contains($0.key) }
        for message in messages {
            let stableId = stableId(for: message)
            if messageCreatedAts[stableId] == nil {
                messageCreatedAts[stableId] = Date()
            }
        }
    }

    func globalIndex(forLocalIndex index: Int) -> Int? {
        guard messages.indices.contains(index) else { return nil }
        return messageIndexOffset + index
    }

    func localIndex(forGlobalIndex index: Int) -> Int? {
        let localIndex = index - messageIndexOffset
        guard messages.indices.contains(localIndex) else { return nil }
        return localIndex
    }

    func messageIndex(messageId: String, kind: TextMessageKind) -> Int? {
        textMessageIndices[TextMessageKey(kind: kind, messageId: messageId)]
    }

    func toolCallIndex(toolCallId: String) -> Int? {
        toolCallIndices[toolCallId]
    }

    // MARK: - Incremental message index caches

    private func updateMessageIndexCaches(for mutation: MessagesMutation?) {
        switch mutation {
        case .append(let message):
            cacheMessageIndex(messages.count - 1, for: message)
        case .replace(let index, let old, let new):
            let oldTextKey = textMessageKey(for: old)
            let newTextKey = textMessageKey(for: new)
            if oldTextKey != newTextKey {
                if let oldTextKey, textMessageIndices[oldTextKey] == index {
                    textMessageIndices.removeValue(forKey: oldTextKey)
                    restoreTextMessageIndex(for: oldTextKey)
                }
                if let newTextKey,
                   textMessageIndices[newTextKey].map({ index < $0 }) ?? true {
                    textMessageIndices[newTextKey] = index
                }
            }

            let oldToolCallId = toolCallId(for: old)
            let newToolCallId = toolCallId(for: new)
            if oldToolCallId != newToolCallId {
                if let oldToolCallId, toolCallIndices[oldToolCallId] == index {
                    toolCallIndices.removeValue(forKey: oldToolCallId)
                    restoreToolCallIndex(for: oldToolCallId)
                }
                if let newToolCallId,
                   toolCallIndices[newToolCallId].map({ index < $0 }) ?? true {
                    toolCallIndices[newToolCallId] = index
                }
            }
        case .planNeutral:
            break
        case .prepend, nil:
            rebuildMessageIndexCaches()
        }
    }

    private func rebuildMessageIndexCaches() {
        #if DEBUG
        messageIndexCacheRebuildCountForTests += 1
        #endif
        textMessageIndices.removeAll(keepingCapacity: true)
        toolCallIndices.removeAll(keepingCapacity: true)
        for index in messages.indices {
            cacheMessageIndex(index, for: messages[index])
        }
    }

    private func cacheMessageIndex(_ index: Int, for message: ACPMessage) {
        if let key = textMessageKey(for: message), textMessageIndices[key] == nil {
            textMessageIndices[key] = index
        }
        if let toolCallId = toolCallId(for: message), toolCallIndices[toolCallId] == nil {
            toolCallIndices[toolCallId] = index
        }
    }

    /// Message ids are expected to be unique within their kind, but retain
    /// the old first-match behavior if malformed/restored data contains a
    /// duplicate and the cached first occurrence changes identity.
    private func restoreTextMessageIndex(for key: TextMessageKey) {
        if let index = messages.indices.first(where: { textMessageKey(for: messages[$0]) == key }) {
            textMessageIndices[key] = index
        }
    }

    private func restoreToolCallIndex(for toolCallId: String) {
        if let index = messages.indices.first(where: { self.toolCallId(for: messages[$0]) == toolCallId }) {
            toolCallIndices[toolCallId] = index
        }
    }

    private func textMessageKey(for message: ACPMessage) -> TextMessageKey? {
        switch message {
        case .user(_, let messageId?, _, _, _):
            TextMessageKey(kind: .user, messageId: messageId)
        case .agent(_, let messageId?, _):
            TextMessageKey(kind: .agent, messageId: messageId)
        case .thought(_, let messageId?, _):
            TextMessageKey(kind: .thought, messageId: messageId)
        default:
            nil
        }
    }

    private func toolCallId(for message: ACPMessage) -> String? {
        guard case .toolCall(let toolCall) = message else { return nil }
        return toolCall.toolCallId
    }

    private func updatePlanCaches(for mutation: MessagesMutation?) {
        switch mutation {
        case .append(let message):
            let index = messages.count - 1
            if case .user = message {
                latestUserMessageIndex = index
            } else if case .plan = message {
                latestPlanMessageIndex = index
            }
            publishPlanCaches()
        case .replace(let index, let old, let new):
            switch (old, new) {
            case (.user, .user):
                break
            case (.plan, .plan):
                if index == latestPlanMessageIndex {
                    publishPlanCaches()
                }
            case (.user, _), (_, .user), (.plan, _), (_, .plan):
                rebuildPlanCaches()
            default:
                break
            }
        case .prepend(let count):
            latestPlanMessageIndex = latestPlanMessageIndex.map { $0 + count }
            latestUserMessageIndex = latestUserMessageIndex.map { $0 + count }
            if latestPlanMessageIndex == nil {
                latestPlanMessageIndex = messages[..<count].lastIndex {
                    if case .plan = $0 { return true }
                    return false
                }
            }
            if latestUserMessageIndex == nil {
                latestUserMessageIndex = messages[..<count].lastIndex {
                    if case .user = $0 { return true }
                    return false
                }
            }
            publishPlanCaches()
        case .planNeutral:
            break
        case nil:
            rebuildPlanCaches()
        }
    }

    private func rebuildPlanCaches() {
        #if DEBUG
        planCacheRebuildCountForTests += 1
        #endif
        latestPlanMessageIndex = messages.lastIndex {
            if case .plan = $0 { return true }
            return false
        }
        latestUserMessageIndex = messages.lastIndex {
            if case .user = $0 { return true }
            return false
        }
        publishPlanCaches()
    }

    private func publishPlanCaches() {
        let newCurrentPlan: [ACPMessage.PlanItem]?
        if let index = currentPlanMessageIndex,
           case .plan(_, let items) = messages[index] {
            newCurrentPlan = items
        } else {
            newCurrentPlan = nil
        }
        if currentPlan != newCurrentPlan {
            currentPlan = newCurrentPlan
        }
    }

    // MARK: - Remote change tracking

    /// Classify an array mutation for the change log. Index-shifting
    /// operations (shrink, or an identity change at a surviving index —
    /// i.e. a prepend, mid-removal, or wholesale replacement) are
    /// structural; everything else records per-index dirty entries.
    /// Cost is O(count) enum compares, but unchanged elements share
    /// storage (COW) and `StreamingText` compares by identity, so the
    /// scan is cheap — and it only runs while a remote client is
    /// subscribed.
    private func recordMessagesDiff(old: [ACPMessage]) {
        guard changeLog.isTracking else { return }
        guard messages.count >= old.count else {
            changeLog.recordStructural()
            return
        }
        for i in old.indices where old[i] != messages[i] {
            guard old[i].stableIdentityKey == messages[i].stableIdentityKey else {
                changeLog.recordStructural()
                return
            }
            changeLog.record(index: i)
        }
        for i in old.count..<messages.count {
            changeLog.record(index: i)
        }
    }

    /// Decision returned by `streamingTickAction` for a single streaming
    /// chunk arrival.
    enum StreamingTickAction: Equatable {
        /// Publish `streamingTick` immediately.
        case publishNow
        /// Coalesce this chunk into a trailing-edge publish fired after
        /// `after` seconds, unless a further chunk supersedes it first.
        case scheduleDrain(after: TimeInterval)
        /// A drain is already pending; nothing to do for this chunk.
        case drop
    }

    /// Target throttle interval for `streamingTick` publishes: roughly
    /// display refresh rate, so a fast agent response cannot force more than
    /// ~30 full `ACPMessageList` body re-evals per second. `nonisolated`
    /// alongside `streamingTickAction` so the pure decision function stays
    /// callable (and testable) without main-actor isolation.
    nonisolated static let streamingTickMinInterval: TimeInterval = 1.0 / 30.0

    /// Pure decision for how a streaming chunk arrival should affect the
    /// throttled `streamingTick` publish. Kept side-effect free and
    /// `nonisolated` so it is trivially unit-testable without a running
    /// transcript instance.
    nonisolated static func streamingTickAction(
        elapsedSincePublish: TimeInterval,
        hasPendingDrain: Bool,
        minInterval: TimeInterval = streamingTickMinInterval
    ) -> StreamingTickAction {
        if hasPendingDrain { return .drop }
        if elapsedSincePublish >= minInterval { return .publishNow }
        return .scheduleDrain(after: minInterval - elapsedSincePublish)
    }

    /// Streaming chunk appends mutate a `StreamingText` buffer in place —
    /// the array element compares equal (identity equality), so
    /// `messages.didSet` cannot see them. Callers pass the mutated index.
    /// Replaces direct `streamingTick &+= 1` writes.
    ///
    /// `streamingTick` publishes are throttled to `streamingTickMinInterval`
    /// with a trailing edge (see `streamingTickAction`): a fast burst of
    /// chunks coalesces into at most ~30 publishes/sec, but the last chunk
    /// in a burst is always eventually delivered via the scheduled drain
    /// task, even if no further chunk arrives. The change log recording
    /// below is intentionally NOT throttled — every chunk still records a
    /// per-index dirty entry for remote-web gateway consumers.
    func noteStreamingChange(at index: Int) {
        if changeLog.isTracking, messages.indices.contains(index) {
            changeLog.record(index: index)
        }
        let now = ProcessInfo.processInfo.systemUptime
        switch Self.streamingTickAction(
            elapsedSincePublish: now - lastStreamingTickPublish,
            hasPendingDrain: streamingTickDrain != nil
        ) {
        case .publishNow:
            lastStreamingTickPublish = now
            streamingTick &+= 1
        case .scheduleDrain(let delay):
            streamingTickDrain = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.streamingTickDrain = nil
                self.lastStreamingTickPublish = ProcessInfo.processInfo.systemUptime
                self.streamingTick &+= 1
            }
        case .drop:
            break
        }
    }

    // MARK: - Render window helpers

    /// Reset `visibleHead` to show the last `tailWindow` messages. Call
    /// after hydration applies a transcript. No-op for transcripts shorter
    /// than `tailWindow`.
    func resetWindowToTail() {
        setVisibleWindow(head: max(0, messages.count - Self.tailWindow), tail: nil)
    }

    /// Reveal one more `tailWindow`-sized chunk of older messages.
    /// Clamps at zero. Idempotent at the head.
    ///
    /// `boundTail: false` (AppKit scroller) keeps the current tail so the
    /// window grows monotonically while the user browses history — the
    /// mounted-view cap lives in the tiling controller, not the window model.
    func stepHeadBack(boundTail: Bool = true) {
        let currentTail = visibleTailBound
        let newHead = max(0, visibleHead - Self.tailWindow)
        if boundTail {
            let boundedTail = min(messages.count, newHead + Self.maxVisibleRows)
            setVisibleWindow(head: newHead, tail: min(currentTail, boundedTail))
        } else {
            setVisibleWindow(head: newHead, tail: visibleTail)
        }
    }

    /// Reveal one more chunk of newer messages while keeping the row currently
    /// near the viewport top inside the bounded window when possible.
    ///
    /// `boundHead: false` (AppKit scroller) keeps the current head so newer
    /// rows extend the grown window instead of trimming the top.
    func stepTailForward(preserving preservedIndex: Int?, boundHead: Bool = true) {
        let currentTail = visibleTailBound
        guard currentTail < messages.count else { return }
        var newTail = min(messages.count, currentTail + Self.tailWindow)
        if let preservedIndex,
           preservedIndex >= visibleHead,
           preservedIndex < currentTail {
            let preservingTail = min(newTail, preservedIndex + Self.maxVisibleRows)
            if preservingTail > currentTail {
                newTail = preservingTail
            }
        }
        guard newTail > currentTail else { return }
        let boundedHead = boundHead ? max(0, newTail - Self.maxVisibleRows) : visibleHead
        setVisibleWindow(head: boundedHead, tail: newTail)
    }

    /// Pin `visibleTail` to the current message count when it is still
    /// unbounded (`nil`). Tail-follow deliberately leaves `visibleTail == nil`
    /// so the window tracks the growing end; the moment the user pauses that
    /// follow we must freeze the tail to a finite bound. Otherwise later
    /// appends (a long, tool-heavy turn can add far more than `maxVisibleRows`
    /// messages) would grow `visibleTailBound` to `messages.count` while the
    /// head stays put, and the eager transcript stack would lay out an
    /// ever-larger window. Newer tail messages are then revealed through the
    /// normal bottom-pagination / resume paths instead of unbounded growth.
    ///
    /// No-op when the tail is already finite. The only state carrying a `nil`
    /// tail is the tail-follow window (`resetWindowToTail`), whose head is
    /// `messages.count - tailWindow`, so freezing keeps the span at
    /// `tailWindow`.
    func freezeVisibleTail() {
        guard visibleTail == nil else { return }
        setVisibleWindow(head: visibleHead, tail: messages.count)
    }

    /// Restore around a remembered non-tail row without rendering the entire
    /// suffix from that row to the transcript tail.
    func setVisibleWindow(containing index: Int) {
        let head = max(0, min(index, messages.count))
        let tail = min(messages.count, head + Self.maxVisibleRows)
        setVisibleWindow(head: head, tail: tail)
    }

    /// Select a full bounded window around a navigation target, with one
    /// page of older context when available. Near either transcript edge the
    /// window shifts inward instead of shrinking.
    func setVisibleWindow(around index: Int) {
        guard !messages.isEmpty else {
            setVisibleWindow(head: 0, tail: 0)
            return
        }
        let target = max(0, min(index, messages.count - 1))
        let latestHead = max(0, messages.count - Self.maxVisibleRows)
        let preferredHead = max(0, target - Self.tailWindow)
        let head = min(preferredHead, latestHead)
        setVisibleWindow(head: head, tail: min(messages.count, head + Self.maxVisibleRows))
    }

    /// Move the render window head, dropping markdown caches for any message
    /// whose index is now below the new head. No-op if `newHead` is not greater
    /// than the current `visibleHead`. Use this instead of writing
    /// `visibleHead` directly when advancing the window.
    func setVisibleHead(_ newHead: Int) {
        setVisibleWindow(head: newHead, tail: nil)
    }

    /// Shift the render window after hidden messages are prepended at the
    /// front. This trims every row below the shifted head because prepended
    /// rows never passed through `setVisibleHead`.
    func shiftVisibleHeadAfterPrepending(_ insertedCount: Int) {
        guard insertedCount > 0 else { return }
        let shiftedHead = max(0, min(visibleHead + insertedCount, messages.count))
        let shiftedTail = visibleTail.map { max(shiftedHead, min($0 + insertedCount, messages.count)) }
        trimHiddenMessages(in: [0..<shiftedHead])
        visibleHead = shiftedHead
        visibleTail = shiftedTail
    }

    var visibleTailBound: Int {
        max(visibleHead, min(visibleTail ?? messages.count, messages.count))
    }

    private func setVisibleWindow(head newHead: Int, tail newTail: Int?) {
        let clampedHead = max(0, min(newHead, messages.count))
        let clampedTail = newTail.map { max(clampedHead, min($0, messages.count)) }
        let normalizedTail = clampedTail
        guard clampedHead != visibleHead || normalizedTail != visibleTail else { return }
        var rangesToTrim: [Range<Int>] = []
        if clampedHead > visibleHead {
            rangesToTrim.append(visibleHead..<clampedHead)
        }
        let oldTail = visibleTailBound
        let newTail = normalizedTail ?? messages.count
        if newTail < oldTail {
            rangesToTrim.append(newTail..<oldTail)
        }
        trimHiddenMessages(in: rangesToTrim)
        visibleHead = clampedHead
        visibleTail = normalizedTail
    }

    private func trimHiddenMessages(in ranges: [Range<Int>]) {
        guard !ranges.isEmpty else { return }
        var updatedMessages = messages
        var didChangeMessages = false
        for range in ranges {
            for index in range {
                markdownCaches.removeValue(forKey: updatedMessages[index].stableId)
                if case .toolCall(var tc) = updatedMessages[index],
                   tc.status != "in_progress", tc.status != "pending" {
                    let revision = tc.contentRevision
                    tc.truncateForOffWindow()
                    if tc.contentRevision != revision {
                        updatedMessages[index] = .toolCall(tc)
                        didChangeMessages = true
                    }
                }
            }
        }
        if didChangeMessages {
            pendingMessagesMutation = .planNeutral
            messages = updatedMessages
        }
    }

    #if DEBUG
    var markdownCacheCountForTests: Int { markdownCaches.count }
    func hasMarkdownCacheForTests(messageId: String) -> Bool {
        markdownCaches[messageId] != nil
    }
    #endif
}
