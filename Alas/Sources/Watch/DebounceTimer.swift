import Foundation

final class DebounceTimer {
    var onFire: (() -> Void)?
    private let interval: TimeInterval
    private var workItem: DispatchWorkItem?
    private let queue: DispatchQueue

    init(interval: TimeInterval, queue: DispatchQueue = .main) {
        self.interval = interval
        self.queue = queue
    }

    func poke() {
        workItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.onFire?()
        }
        workItem = item
        queue.asyncAfter(deadline: .now() + interval, execute: item)
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}
