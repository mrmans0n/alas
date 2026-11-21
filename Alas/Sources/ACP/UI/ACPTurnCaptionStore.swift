import Foundation

/// Captions for turn changes cards, written on this machine by the local model the first time a card
/// shows. Kept in memory only: a card from before a relaunch asks again when it next shows.
@MainActor
final class ACPTurnCaptionStore: ObservableObject {
    @Published private(set) var captions: [String: String] = [:]
    /// Read on every request, so a card asks again once captions turn back on.
    private let isEnabled: () -> Bool
    private let generate: (ACPTurnCaptionPolicy.Input) async -> String?

    init(isEnabled: @escaping () -> Bool, generate: @escaping (ACPTurnCaptionPolicy.Input) async -> String?) {
        self.isEnabled = isEnabled
        self.generate = generate
    }

    private var requested: Set<String> = []
    private var order: [String] = []
    private static let capacity = 200

    /// Starts writing the caption for `key` unless one was already asked for.
    func request(key: String, input: @escaping () -> ACPTurnCaptionPolicy.Input?) {
        guard isEnabled(), !requested.contains(key), let input = input() else { return }
        let generate = generate
        requested.insert(key)
        order.append(key)
        if order.count > Self.capacity {
            let evicted = order.removeFirst()
            requested.remove(evicted)
            captions[evicted] = nil
        }
        Task { [weak self] in
            guard let caption = await generate(input), let self, self.requested.contains(key) else { return }
            self.captions[key] = caption
        }
    }

    /// Forgets every caption, as when the setting turns off.
    func reset() {
        requested.removeAll()
        order.removeAll()
        captions.removeAll()
    }
}
