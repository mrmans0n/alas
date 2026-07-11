import Testing
@testable import Alas

struct RemotePollCadenceTests {
    @Test func cadenceUsesActiveAndInactiveIntervals() {
        #expect(RemotePollCadence.nextDelay(succeeded: true, appActive: true, previous: 300) == 5)
        #expect(RemotePollCadence.nextDelay(succeeded: true, appActive: false, previous: 5) == 45)
    }
    @Test func failuresBackOffAndCap() {
        #expect(RemotePollCadence.nextDelay(succeeded: false, appActive: true, previous: 5) == 10)
        #expect(RemotePollCadence.nextDelay(succeeded: false, appActive: true, previous: 200) == 300)
    }
}
