import Foundation

/// Captions for turn changes cards, written on this machine by the local model the first time a card
/// shows. Kept in memory only: a card from before a relaunch asks again when it next shows.
///
/// Requests run one at a time, newest first: the local engine cancels a running job when another
/// arrives, so parallel captions would cut each other off. A request that comes back empty, as a
/// cancelled one does, may run once more the next time its card shows.
@MainActor
final class ACPTurnCaptionStore: ObservableObject {
    @Published private(set) var captions: [String: String] = [:]

    /// Read on every request, so a card asks again once captions turn back on.
    private let isEnabled: () -> Bool
    private let generate: (ACPTurnCaptionPolicy.Input) async -> String?

    private var waiting: [(key: String, input: ACPTurnCaptionPolicy.Input)] = []
    private var running: String?
    private var attempts: [String: Int] = [:]
    private var order: [String] = []
    /// Bumped by `reset`, so a caption started before it is dropped.
    private var generation = 0

    static let maxAttempts = 2
    private static let capacity = 200
    /// Older waiting requests drop off; their cards ask again when they next show.
    private static let maxWaiting = 20

    init(isEnabled: @escaping () -> Bool, generate: @escaping (ACPTurnCaptionPolicy.Input) async -> String?) {
        self.isEnabled = isEnabled
        self.generate = generate
    }

    /// Queues the caption for `key` unless it is written, waiting, running, or out of attempts.
    func request(key: String, input: () -> ACPTurnCaptionPolicy.Input?) {
        guard isEnabled(), captions[key] == nil, running != key, !waiting.contains(where: { $0.key == key }),
              attempts[key, default: 0] < Self.maxAttempts, let input = input()
        else { return }
        waiting.append((key, input))
        if waiting.count > Self.maxWaiting { waiting.removeFirst() }
        runNext()
    }

    /// Forgets every caption, as when the setting turns off.
    func reset() {
        generation += 1
        waiting.removeAll()
        attempts.removeAll()
        order.removeAll()
        captions.removeAll()
    }

    private func runNext() {
        guard running == nil, let next = waiting.popLast() else { return }
        running = next.key
        attempts[next.key, default: 0] += 1
        let started = generation
        let generate = generate
        Task { [weak self] in
            let caption = await generate(next.input)
            guard let self else { return }
            self.running = nil
            if let caption, started == self.generation { self.store(caption, for: next.key) }
            self.runNext()
        }
    }

    private func store(_ caption: String, for key: String) {
        captions[key] = caption
        order.append(key)
        if order.count > Self.capacity {
            let evicted = order.removeFirst()
            captions[evicted] = nil
            attempts[evicted] = nil
        }
    }
}
