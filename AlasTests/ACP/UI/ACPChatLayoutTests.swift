import Testing
@testable import Alas

@Suite("ACP chat layout")
struct ACPChatLayoutTests {
    @Test func keepsCurrentWidthForNormalPanes() {
        #expect(ACPChatLayout.contentMaxWidth(forPaneWidth: 900) == 720)
        #expect(ACPChatLayout.contentMaxWidth(forPaneWidth: 1_080) == 720)
    }

    @Test func growsOnWidePanes() {
        let width = ACPChatLayout.contentMaxWidth(forPaneWidth: 1_200)

        #expect(width > 720)
        #expect(width < 960)
    }

    @Test func capsOnUltrawidePanes() {
        #expect(ACPChatLayout.contentMaxWidth(forPaneWidth: 1_600) == 960)
        #expect(ACPChatLayout.contentMaxWidth(forPaneWidth: 3_000) == 960)
    }

    @Test func contentWidthUsesMeasuredChatColumnWidth() {
        #expect(ACPChatLayout.contentMaxWidth(forChatColumnWidth: 1_200) == 840)
        #expect(ACPChatLayout.contentMaxWidth(forChatColumnWidth: 880) == 720)
    }
}
