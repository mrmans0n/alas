import Testing
import Foundation
import CoreFoundation
@testable import Alas

@MainActor
struct ImageDiffSideBySideViewTests {
    @Test func failedSideUsesFailureMessageAsItsPlaceholder() {
        let side = ImageDiffSide.failed(ImageDiffLoadFailure(message: "Could not decode image"))

        #expect(
            ImageDiffSideBySideView.placeholderMessage(for: side, missingText: "No before")
                == "Could not decode image"
        )
    }

    @Test func transformResetReturnsToIdentity() {
        var t = ImageDiffTransform(scale: 3.0, offset: .init(width: 50, height: 50))
        t.reset()
        #expect(t.scale == 1.0)
        #expect(t.offset == .zero)
    }

    @Test func zoomClampsToRange() {
        var t = ImageDiffTransform()
        t.applyZoomDelta(100) // try to zoom way past max
        #expect(t.scale == 10.0)
        t.applyZoomDelta(-100)
        #expect(t.scale == 1.0)
    }

    @Test func panAccumulates() {
        var t = ImageDiffTransform()
        t.applyPanDelta(dx: 10, dy: 20)
        t.applyPanDelta(dx: 5, dy: -10)
        #expect(t.offset.width == 15)
        #expect(t.offset.height == 10)
    }

    @Test func dragTranslationIsAddedToCommittedPanOffset() {
        let offset = ImageDiffSideBySideView.displayOffset(
            committed: CGSize(width: 12, height: -8),
            translation: CGSize(width: 5, height: 11)
        )

        #expect(offset == CGSize(width: 17, height: 3))
    }

    @Test func unmodifiedScrollIsNotCapturedByImageViewer() {
        #expect(!ScrollEventCapturingView.shouldCaptureScroll(modifierFlags: []))
    }

    @Test func commandScrollIsCapturedByImageViewer() {
        #expect(
            ScrollEventCapturingView.shouldCaptureScroll(modifierFlags: [.command])
        )
    }

    @Test func scrollCaptureViewDoesNotBlockMouseHitTesting() {
        let view = ScrollEventCapturingView.Backing()
        view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)

        #expect(view.hitTest(CGPoint(x: 50, y: 50)) == nil)
    }

    @Test func annotationGeometryMapsBetweenDisplayAndNormalizedCoordinates() throws {
        let geometry = ImageDiffAnnotationGeometry(
            imageSize: CGSize(width: 400, height: 200),
            viewportSize: CGSize(width: 300, height: 300),
            transform: ImageDiffTransform(scale: 2, offset: CGSize(width: 10, height: -20))
        )

        let displayPoint = try #require(geometry.displayPoint(normalizedX: 0.75, normalizedY: 0.25))
        #expect(displayPoint.x == 310)
        #expect(displayPoint.y == 55)
        let normalized = try #require(geometry.normalizedPoint(at: displayPoint))
        #expect(abs(normalized.x - 0.75) < 0.0001)
        #expect(abs(normalized.y - 0.25) < 0.0001)
    }

    @Test func annotationGeometryIgnoresClicksInLetterbox() {
        let geometry = ImageDiffAnnotationGeometry(
            imageSize: CGSize(width: 400, height: 200),
            viewportSize: CGSize(width: 300, height: 300),
            transform: ImageDiffTransform()
        )

        #expect(geometry.normalizedPoint(at: CGPoint(x: 150, y: 25)) == nil)
        #expect(geometry.normalizedPoint(at: CGPoint(x: 150, y: 150)) != nil)
    }
}
