import Testing
@testable import Alas

@Suite("ACPMessageList scroller switch")
struct ACPMessageListSwitchTests {
    @Test("switch follows the flag")
    func followsFlag() {
        #expect(ACPMessageList.usesAppKitScroller(flagEnabled: true))
        #expect(!ACPMessageList.usesAppKitScroller(flagEnabled: false))
    }
}
