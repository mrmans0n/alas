import Foundation

/// Captions for turn changes cards, written on this machine by the local model and saved with their
/// session: when a turn finishes, and for an older turn the first time its card shows.
///
/// A session's saved captions load on its first request; a caption is written only when none is saved
/// for the turn's current edits. Requests run one at a time, newest first: the local engine cancels a
/// running job when another arrives, so parallel captions would cut each other off. A request that
/// comes back empty, as a cancelled one does, may run once more the next time it is asked for.
@MainActor
final class ACPTurnCaptionStore: ObservableObject {
    /// A turn's card: its session, its answer's transcript index, and `ACPTurnChanges.digest`.
    struct Key: Hashable {
        let sessionId: String
        let answerIndex: Int
        let digest: String
    }

    @Published private(set) var captions: [Key: String] = [:]

    /// Read on every request, so a card asks again once captions turn back on.
    private let isEnabled: () -> Bool
    private let generate: (ACPTurnCaptionPolicy.Input) async -> String?
    private let load: @MainActor (String) async -> [StoredTurnCaption]
    private let save: @MainActor (String, StoredTurnCaption) async -> Void

    private typealias Request = (key: Key, input: () -> ACPTurnCaptionPolicy.Input?)
    /// Sessions whose saved captions are in `captions`, and requests waiting on a load.
    private var loaded: Set<String> = []
    private var awaitingLoad: [String: [Request]] = [:]
    private var waiting: [(key: Key, input: ACPTurnCaptionPolicy.Input)] = []
    private var running: Key?
    private var attempts: [Key: Int] = [:]
    private var order: [Key] = []
    /// Bumped by `reset`, so work started before it is dropped.
    private var generation = 0

    static let maxAttempts = 2
    private static let capacity = 500
    /// Older waiting requests drop off; their cards ask again when they next show.
    private static let maxWaiting = 20

    init(
        isEnabled: @escaping () -> Bool,
        generate: @escaping (ACPTurnCaptionPolicy.Input) async -> String?,
        load: @escaping @MainActor (String) async -> [StoredTurnCaption] = { _ in [] },
        save: @escaping @MainActor (String, StoredTurnCaption) async -> Void = { _, _ in }
    ) {
        self.isEnabled = isEnabled
        self.generate = generate
        self.load = load
        self.save = save
    }

    /// Shows the saved caption for `key`, or queues one unless it is waiting, running, or out of attempts.
    func request(key: Key, input: @escaping () -> ACPTurnCaptionPolicy.Input?) {
        guard isEnabled(), captions[key] == nil else { return }
        guard loaded.contains(key.sessionId) else {
            let first = awaitingLoad[key.sessionId] == nil
            awaitingLoad[key.sessionId, default: []].append((key, input))
            if first { loadSaved(sessionId: key.sessionId) }
            return
        }
        guard running != key, !waiting.contains(where: { $0.key == key }),
              attempts[key, default: 0] < Self.maxAttempts, let input = input()
        else { return }
        waiting.append((key, input))
        if waiting.count > Self.maxWaiting { waiting.removeFirst() }
        runNext()
    }

    /// Forgets every caption in memory, as when the setting turns off. Saved ones load again when it
    /// turns back on.
    func reset() {
        generation += 1
        loaded.removeAll()
        awaitingLoad.removeAll()
        waiting.removeAll()
        attempts.removeAll()
        order.removeAll()
        captions.removeAll()
    }

    private func loadSaved(sessionId: String) {
        let started = generation
        let load = load
        Task { [weak self] in
            let saved = await load(sessionId)
            guard let self, started == self.generation else { return }
            self.loaded.insert(sessionId)
            for caption in saved {
                self.remember(caption.caption, for: Key(
                    sessionId: sessionId, answerIndex: caption.answerIndex, digest: caption.filesDigest))
            }
            for request in self.awaitingLoad.removeValue(forKey: sessionId) ?? [] {
                self.request(key: request.key, input: request.input)
            }
        }
    }

    private func runNext() {
        guard running == nil, let next = waiting.popLast() else { return }
        running = next.key
        attempts[next.key, default: 0] += 1
        let started = generation
        let generate = generate
        let save = save
        Task { [weak self] in
            let caption = await generate(next.input)
            guard let self else { return }
            self.running = nil
            if let caption, started == self.generation {
                self.remember(caption, for: next.key)
                let key = next.key
                Task {
                    await save(key.sessionId, StoredTurnCaption(
                        answerIndex: key.answerIndex, filesDigest: key.digest, caption: caption))
                }
            }
            self.runNext()
        }
    }

    private func remember(_ caption: String, for key: Key) {
        if captions[key] == nil { order.append(key) }
        captions[key] = caption
        if order.count > Self.capacity {
            let evicted = order.removeFirst()
            captions[evicted] = nil
            attempts[evicted] = nil
            // Its caption is still saved: the session loads again on its next request.
            loaded.remove(evicted.sessionId)
        }
    }
}
