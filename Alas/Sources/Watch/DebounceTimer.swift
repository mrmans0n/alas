import Foundation

final class DebounceTimer {
    var onFire: (() -> Void)?
    private let interval: TimeInterval
    private let maxWait: TimeInterval?
    private var workItem: DispatchWorkItem?
    private var firstPokeAt: Date?
    private let queue: DispatchQueue

    /// - parameter interval: trailing-edge delay since the last `poke()`.
    /// - parameter maxWait: hard ceiling on how long a single burst of
    ///   pokes can delay the fire. Without this, a sender that pokes
    ///   faster than `interval` (e.g. an agent editing files in a tight
    ///   loop) starves the timer because each poke cancels the prior
    ///   work item. With it, fire happens by `firstPoke + maxWait`
    ///   regardless of subsequent pokes. `nil` keeps the classic
    ///   debounce semantics.
    init(interval: TimeInterval, queue: DispatchQueue = .main, maxWait: TimeInterval? = nil) {
        self.interval = interval
        self.queue = queue
        self.maxWait = maxWait
    }

    func poke() {
        workItem?.cancel()
        let now = Date()
        if firstPokeAt == nil { firstPokeAt = now }

        var delay = interval
        if let maxWait, let start = firstPokeAt {
            let elapsed = now.timeIntervalSince(start)
            delay = min(interval, max(0, maxWait - elapsed))
        }

        let item = DispatchWorkItem { [weak self] in
            self?.firstPokeAt = nil
            self?.onFire?()
        }
        workItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
        firstPokeAt = nil
    }
}
