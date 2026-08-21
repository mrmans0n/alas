import Foundation

/// Debounces review-session selection persistence so scroll-spy driven
/// selection changes don't perform synchronous disk writes on every file
/// boundary crossed during a fling. In-memory state updates immediately at
/// the call site; only the disk write is deferred. Re-scheduling replaces
/// the pending write, so a fling across many files produces one write once
/// scrolling settles. `flush()` forces the pending write to run now — call
/// it before any path that reloads state from disk, so the store never
/// serves a selection older than the one on screen.
@MainActor
final class ReviewSessionSelectionPersister {
    private let debounceNanos: UInt64
    private var pendingTask: Task<Void, Never>?
    private var pendingWrite: (() -> Void)?

    init(debounceNanos: UInt64 = 400_000_000) {
        self.debounceNanos = debounceNanos
    }

    func schedule(_ write: @escaping () -> Void) {
        pendingWrite = write
        pendingTask?.cancel()
        pendingTask = Task { [weak self, debounceNanos] in
            try? await Task.sleep(nanoseconds: debounceNanos)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        pendingTask?.cancel()
        pendingTask = nil
        guard let write = pendingWrite else { return }
        pendingWrite = nil
        write()
    }
}
