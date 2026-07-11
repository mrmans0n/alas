import Testing
@testable import Alas

struct ACPReconnectPolicyTests {
    @Test func delaysBackOffAndGiveUp() {
        #expect(ACPReconnectPolicy.delay(forAttempt: 0) == 2)
        #expect(ACPReconnectPolicy.delay(forAttempt: 1) == 5)
        #expect(ACPReconnectPolicy.delay(forAttempt: 4) == 60)
        #expect(ACPReconnectPolicy.delay(forAttempt: 5) == nil)
        #expect(ACPReconnectPolicy.delay(forAttempt: -1) == nil)
    }
}
