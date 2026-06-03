import Testing
import Darwin
@testable import Alas

@Suite struct ACPProcessLivenessTests {
    @Test("current process is reported alive")
    func currentAlive() {
        #expect(ACPProcessLiveness.pidAlive(Int64(getpid())) == true)
    }

    @Test("absurd pid is reported dead")
    func bogusDead() {
        #expect(ACPProcessLiveness.pidAlive(999_999_99) == false)
    }

    @Test("non-positive pid is dead")
    func nonPositiveDead() {
        #expect(ACPProcessLiveness.pidAlive(0) == false)
        #expect(ACPProcessLiveness.pidAlive(-1) == false)
    }
}
