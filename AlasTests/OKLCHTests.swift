import Testing
import SwiftUI
@testable import Alas

struct OKLCHTests {
    @Test func parsesNoAlpha() throws {
        let parsed = try OKLCH.parse("oklch(0.74 0.11 195)")
        #expect(abs(parsed.l - 0.74) < 1e-6)
        #expect(abs(parsed.c - 0.11) < 1e-6)
        #expect(abs(parsed.h - 195) < 1e-6)
        #expect(abs(parsed.a - 1.0) < 1e-6)
    }

    @Test func parsesWithAlpha() throws {
        let parsed = try OKLCH.parse("oklch(0.32 0.020 220 / 0.6)")
        #expect(abs(parsed.a - 0.6) < 1e-6)
    }

    @Test func parseInvalidThrows() {
        #expect(throws: OKLCH.ParseError.self) {
            _ = try OKLCH.parse("rgb(1 2 3)")
        }
    }

    @Test func toColorIsFinite() throws {
        let _: Color = try OKLCH.parse("oklch(0.5 0.10 100)").toColor()
    }
}
