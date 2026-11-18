import AlasHighlight
import Testing
import SwiftUI
@testable import Alas

struct OKLCHTests {
    @Test func toColorIsFinite() throws {
        let _: Color = try OKLCH.parse("oklch(0.5 0.10 100)").toColor()
    }
}
