import Foundation
import Testing
@testable import Alas

@MainActor
struct SpacePagerIndicatorTests {
    @Test func inactiveEmojiUsesGrayscaleStyle() {
        #expect(SpacePagerItemStyle.style(isActive: true).opacity == 1)
        #expect(SpacePagerItemStyle.style(isActive: false).opacity < 1)
        #expect(!SpacePagerItemStyle.style(isActive: true).isGrayscale)
        #expect(SpacePagerItemStyle.style(isActive: false).isGrayscale)
    }
}
