import Testing
import Foundation
@testable import Alas

struct DebounceTimerTests {
    // Reference type so the closure mutation propagates without capture warnings.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.withLock { value += 1 }
        }

        var n: Int {
            lock.withLock { value }
        }
    }

    @Test func firesOnceAfterDelay() async throws {
        let counter = Counter()
        let queue = DispatchQueue(label: "io.nlopez.alas.tests.debounce")

        let timer = DebounceTimer(interval: 0.1, queue: queue)
        timer.onFire = { counter.increment() }
        timer.poke()
        timer.poke()
        timer.poke()

        // 100ms interval + 400ms grace beats CI-load scheduling jitter without
        // making the test feel slow. Earlier 50ms+200ms was flaky under load.
        try await Task.sleep(nanoseconds: 500_000_000)
        queue.sync {}
        #expect(counter.n == 1)
    }

    @Test func maxWaitFiresEvenWhileBeingPoked() async throws {
        // Continuous pokes faster than `interval` would normally starve the
        // debouncer (each poke cancels the prior work item). With `maxWait`
        // set, fire must happen by `firstPoke + maxWait` regardless. This is
        // the starvation case observed for the right-pane watcher when an
        // agent is editing files faster than the 0.5s debounce window.
        let counter = Counter()
        let queue = DispatchQueue(label: "io.nlopez.alas.tests.debounce.maxwait")

        let timer = DebounceTimer(interval: 0.2, queue: queue, maxWait: 0.3)
        timer.onFire = { counter.increment() }

        // Poke every 50ms for 500ms — well below the 200ms interval so a
        // plain debouncer never fires. Total span 500ms > maxWait 300ms so
        // the max-wait must trigger exactly one fire during the burst.
        let start = Date()
        while Date().timeIntervalSince(start) < 0.5 {
            timer.poke()
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // Drain trailing fire after the burst stops.
        try await Task.sleep(nanoseconds: 300_000_000)
        queue.sync {}
        #expect(counter.n >= 1, "max-wait should force at least one fire during continuous pokes")
    }

    @Test func maxWaitResetsAfterFire() async throws {
        // After firing, the next poke starts a fresh max-wait window — we
        // shouldn't immediately re-fire just because the previous burst was
        // long. This guards against an edge of "fire immediately on every
        // poke once maxWait has elapsed since some long-ago first poke."
        let counter = Counter()
        let queue = DispatchQueue(label: "io.nlopez.alas.tests.debounce.reset")

        let timer = DebounceTimer(interval: 0.1, queue: queue, maxWait: 0.2)
        timer.onFire = { counter.increment() }

        timer.poke()
        try await Task.sleep(nanoseconds: 250_000_000) // Let it fire.
        queue.sync {}
        let afterFirst = counter.n
        #expect(afterFirst == 1)

        // Single poke: should fire once after `interval`, not immediately.
        timer.poke()
        queue.sync {}
        #expect(counter.n == afterFirst, "fire should not be instantaneous after reset")
        try await Task.sleep(nanoseconds: 250_000_000)
        queue.sync {}
        #expect(counter.n == afterFirst + 1)
    }
}
