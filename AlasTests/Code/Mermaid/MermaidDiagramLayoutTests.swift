import CoreGraphics
import Testing
@testable import Alas

struct MermaidDiagramLayoutTests {
    @Test("fit preserves ratio, respects height, and never upscales")
    func fitRules() {
        #expect(MermaidDiagramLayout.fittedSize(
            intrinsic: CGSize(width: 1_000, height: 500),
            availableWidth: 400,
            maxHeight: 420
        ) == CGSize(width: 400, height: 200))
        #expect(MermaidDiagramLayout.fittedSize(
            intrinsic: CGSize(width: 500, height: 1_000),
            availableWidth: 400,
            maxHeight: 420
        ) == CGSize(width: 210, height: 420))
        #expect(MermaidDiagramLayout.fittedSize(
            intrinsic: CGSize(width: 100, height: 50),
            availableWidth: 400,
            maxHeight: 420
        ) == CGSize(width: 100, height: 50))
    }

    @Test("fit rejects invalid dimensions")
    func invalidDimensions() {
        #expect(MermaidDiagramLayout.fittedSize(
            intrinsic: CGSize(width: 0, height: 100),
            availableWidth: 400,
            maxHeight: 420
        ) == .zero)
        #expect(MermaidDiagramLayout.fittedSize(
            intrinsic: CGSize(width: 100, height: 100),
            availableWidth: 0,
            maxHeight: 420
        ) == .zero)
    }
}
