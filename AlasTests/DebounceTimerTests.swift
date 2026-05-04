import Testing
import Foundation
@testable import Alas

struct DebounceTimerTests {
    @Test func firesOnceAfterDelay() async throws {
        var fires = 0
        let timer = DebounceTimer(interval: 0.05)
        timer.onFire = { fires += 1 }
        timer.poke()
        timer.poke()
        timer.poke()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(fires == 1)
    }
}
