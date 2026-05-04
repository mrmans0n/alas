import Testing
import Foundation
@testable import Alas

struct DebounceTimerTests {
    @Test func firesOnceAfterDelay() async throws {
        // Reference type so the closure mutation propagates without capture warnings.
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()

        let timer = DebounceTimer(interval: 0.1)
        timer.onFire = { counter.n += 1 }
        timer.poke()
        timer.poke()
        timer.poke()

        // 100ms interval + 400ms grace beats CI-load scheduling jitter without
        // making the test feel slow. Earlier 50ms+200ms was flaky under load.
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(counter.n == 1)
    }
}
