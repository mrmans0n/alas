import Testing
import Foundation
import CoreFoundation
@testable import Alas

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
}
