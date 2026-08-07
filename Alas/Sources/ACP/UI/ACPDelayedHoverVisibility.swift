import SwiftUI

@MainActor
final class ACPDelayedHoverVisibility: ObservableObject {
    @Published private(set) var isVisible = false

    private let hideDelayNanoseconds: UInt64
    private var hideTask: Task<Void, Never>?

    init(hideDelayNanoseconds: UInt64 = 350_000_000) {
        self.hideDelayNanoseconds = hideDelayNanoseconds
    }

    deinit {
        hideTask?.cancel()
    }

    func enter() {
        hideTask?.cancel()
        hideTask = nil
        isVisible = true
    }

    func leave() {
        hideTask?.cancel()
        let delay = hideDelayNanoseconds
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.isVisible = false
                self?.hideTask = nil
            }
        }
    }
}
