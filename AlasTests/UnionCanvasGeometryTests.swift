import Testing
import Foundation
@testable import Alas

struct UnionCanvasGeometryTests {
    @Test func identicalSizesScaleToFitViewport() {
        let g = UnionCanvasGeometry(
            before: CGSize(width: 100, height: 100),
            after: CGSize(width: 100, height: 100),
            viewport: CGSize(width: 200, height: 200)
        )
        #expect(g.unionSize == CGSize(width: 100, height: 100))
        #expect(g.scale == 2.0)
        #expect(g.scaledUnionSize == CGSize(width: 200, height: 200))
        #expect(g.origin == .zero)
    }

    @Test func mismatchedDimensionsUseUnionMax() {
        let g = UnionCanvasGeometry(
            before: CGSize(width: 100, height: 50),
            after: CGSize(width: 50, height: 200),
            viewport: CGSize(width: 200, height: 400)
        )
        // Union = 100×200; viewport = 200×400. Both axes want scale=2 →
        // scaledUnion = 200×400, perfectly fills viewport.
        #expect(g.unionSize == CGSize(width: 100, height: 200))
        #expect(g.scale == 2.0)
        #expect(g.scaledUnionSize == CGSize(width: 200, height: 400))
        #expect(g.origin == .zero)
    }

    @Test func limitingAxisDeterminesScale() {
        let g = UnionCanvasGeometry(
            before: CGSize(width: 200, height: 100),
            after: CGSize(width: 200, height: 100),
            viewport: CGSize(width: 100, height: 100)
        )
        // Union = 200×100; viewport = 100×100. Width-limited: scale = 0.5.
        #expect(g.scale == 0.5)
        #expect(g.scaledUnionSize == CGSize(width: 100, height: 50))
        // Centered vertically: (100-50)/2 = 25.
        #expect(g.origin == CGPoint(x: 0, y: 25))
    }

    @Test func degenerateUnionReturnsIdentityScale() {
        let g = UnionCanvasGeometry(
            before: .zero, after: .zero,
            viewport: CGSize(width: 200, height: 200)
        )
        #expect(g.scale == 1.0)
    }

    @Test func degenerateViewportReturnsIdentityScale() {
        let g = UnionCanvasGeometry(
            before: CGSize(width: 100, height: 100),
            after: CGSize(width: 100, height: 100),
            viewport: .zero
        )
        #expect(g.scale == 1.0)
    }
}
