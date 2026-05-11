import Testing
import Foundation
@testable import Alas

struct DebounceTimerTests {
    @Test func firesOnceAfterDelay() async throws {
        // Reference type so the closure mutation propagates without capture warnings.
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0

            func increment() {
                lock.withLock { value += 1 }
            }

            var n: Int {
                lock.withLock { value }
            }
        }
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
}
