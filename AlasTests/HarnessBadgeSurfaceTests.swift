import Testing
@testable import Alas

/// E1 paints the agent tile as a filled gradient chip rather than the hollow
/// outlined one that shipped before, so the surface ramp is worth pinning.
struct HarnessBadgeSurfaceTests {
    @Test func rampKeepsTokenHueAndChroma() throws {
        // cool-slate's `add`.
        let stops = try #require(HarnessSessionBadgeChrome.surfaceRamp(from: "oklch(0.78 0.14 155)"))
        #expect(stops.count == 2)
        for stop in stops {
            #expect(stop.h == 155)
            #expect(stop.c == 0.14)
        }
    }

    @Test func rampDarkensFromTopToBottom() throws {
        let stops = try #require(HarnessSessionBadgeChrome.surfaceRamp(from: "oklch(0.78 0.14 155)"))
        // A flat pair would render as a solid block, losing E1's dimensionality.
        #expect(stops[0].l > stops[1].l)
        #expect(stops[0].l == HarnessSessionBadgeChrome.surfaceTopLightness)
        #expect(stops[1].l == HarnessSessionBadgeChrome.surfaceBottomLightness)
    }

    @Test func rampIsOpaque() throws {
        // The tile is a surface, not a tint of the row behind it — the old
        // chrome filled at 8-14% opacity, which is what made it read as hollow.
        let stops = try #require(HarnessSessionBadgeChrome.surfaceRamp(from: "oklch(0.78 0.14 155)"))
        for stop in stops {
            #expect(stop.a == 1)
        }
    }

    @Test func runningAndAwaitingStaySeparableByHue() throws {
        let running = try #require(HarnessSessionBadgeChrome.surfaceRamp(from: "oklch(0.78 0.14 155)"))
        let awaiting = try #require(HarnessSessionBadgeChrome.surfaceRamp(from: "oklch(0.80 0.13 95)"))
        // E1 only ever drew the running tile; keeping the token's hue is what
        // preserves the running/awaiting distinction the design does not model.
        #expect(running[0].h != awaiting[0].h)
    }

    @Test func missingOrUnparseableTokenYieldsNoRamp() {
        // Theme.fallback ships no tokens; callers fall back to a flat fill
        // rather than gradient-ing the pink sentinel.
        #expect(HarnessSessionBadgeChrome.surfaceRamp(from: nil) == nil)
        #expect(HarnessSessionBadgeChrome.surfaceRamp(from: "#ff00ff") == nil)
        #expect(HarnessSessionBadgeChrome.surfaceRamp(from: "") == nil)
    }
}
