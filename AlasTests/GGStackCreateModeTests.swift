import Testing
@testable import Alas

struct GGStackCreateModeTests {
    @Test func hiddenWhenGateFails() {
        #expect(GGStackCreateMode.availability(gatePassed: false, username: "nacho") == .hidden)
    }

    @Test func disabledWithHintWhenUsernameMissing() {
        let availability = GGStackCreateMode.availability(gatePassed: true, username: nil)
        guard case .disabled(let hint) = availability else {
            Issue.record("expected disabled")
            return
        }
        #expect(hint.contains("branch_username"))
    }

    @Test func enabledCarriesUsername() {
        #expect(GGStackCreateMode.availability(gatePassed: true, username: "nacho") == .enabled(username: "nacho"))
    }
}
