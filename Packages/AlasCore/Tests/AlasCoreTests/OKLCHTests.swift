import Testing
import AlasCore

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

    /// Golden linear-sRGB values for real light.json tokens, so a change to the conversion
    /// matrices shifts every theme colour visibly here.
    @Test(arguments: [
        ("oklch(0.50 0.13 295)", 0.14338327574434814, 0.0819498150535034, 0.37366638080523923), // syntax-keyword
        ("oklch(0.20 0.012 220)", 0.005202000851381082, 0.00878222637106227, 0.010209386069376429), // fg
        ("oklch(0.48 0.14 155)", 0.0, 0.17204118809627522, 0.03907161972019717), // add
    ])
    func linearSRGBMatchesGolden(token: String, r: Double, g: Double, b: Double) throws {
        let c = try OKLCH.parse(token).linearSRGB()
        #expect(abs(c.red - r) < 1e-9 && abs(c.green - g) < 1e-9 && abs(c.blue - b) < 1e-9)
    }
}
