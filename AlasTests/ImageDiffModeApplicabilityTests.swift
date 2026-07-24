import AppKit
import Testing
@testable import Alas

struct ImageDiffModeApplicabilityTests {
    private func pair(
        kind: ImageDiffPairKind,
        before: ImageDiffSide = .missing,
        after: ImageDiffSide = .missing
    ) -> ImageDiffPair {
        ImageDiffPair(before: before, after: after, oldPath: nil, kind: kind)
    }

    private func loadedPair(kind: ImageDiffPairKind) -> ImageDiffPair {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        return pair(
            kind: kind,
            before: .image(image, frameCount: 1),
            after: .image(image, frameCount: 1)
        )
    }

    @Test func nonSideBySideModesRequireTwoLoadedImages() {
        let pair = ImageDiffPair(
            before: .failed(ImageDiffLoadFailure(message: "Before failed")),
            after: .image(NSImage(size: NSSize(width: 1, height: 1)), frameCount: 1),
            oldPath: nil,
            kind: .modified
        )

        #expect(ImageDiffMode.sideBySide.isApplicable(for: pair))
        #expect(!ImageDiffMode.overlay.isApplicable(for: pair))
        #expect(!ImageDiffMode.swipe.isApplicable(for: pair))
        #expect(!ImageDiffMode.difference.isApplicable(for: pair))
    }

    @Test func copiedPairSupportsEveryModeWhenBothSidesLoad() {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        let pair = ImageDiffPair(
            before: .image(image, frameCount: 1),
            after: .image(image, frameCount: 1),
            oldPath: "Assets/Original.png",
            kind: .copied
        )

        for mode in ImageDiffMode.allCases {
            #expect(mode.isApplicable(for: pair))
        }
    }

    @Test func sideBySideAlwaysApplicable() {
        for kind in ImageDiffPairKind.allCases {
            #expect(ImageDiffMode.sideBySide.isApplicable(for: pair(kind: kind)))
        }
    }

    @Test func overlayDisabledForOneSidedDiffs() {
        #expect(ImageDiffMode.overlay.isApplicable(for: loadedPair(kind: .modified)))
        #expect(ImageDiffMode.overlay.isApplicable(for: loadedPair(kind: .renamed)))
        #expect(!ImageDiffMode.overlay.isApplicable(for: pair(kind: .added, after: .image(NSImage(), frameCount: 1))))
        #expect(!ImageDiffMode.overlay.isApplicable(for: pair(kind: .deleted, before: .image(NSImage(), frameCount: 1))))
    }

    @Test func swipeDisabledForOneSidedDiffs() {
        #expect(ImageDiffMode.swipe.isApplicable(for: loadedPair(kind: .modified)))
        #expect(ImageDiffMode.swipe.isApplicable(for: loadedPair(kind: .renamed)))
        #expect(!ImageDiffMode.swipe.isApplicable(for: pair(kind: .added, after: .image(NSImage(), frameCount: 1))))
        #expect(!ImageDiffMode.swipe.isApplicable(for: pair(kind: .deleted, before: .image(NSImage(), frameCount: 1))))
    }

    @Test func differenceDisabledForOneSidedDiffs() {
        #expect(ImageDiffMode.difference.isApplicable(for: loadedPair(kind: .modified)))
        #expect(ImageDiffMode.difference.isApplicable(for: loadedPair(kind: .renamed)))
        #expect(!ImageDiffMode.difference.isApplicable(for: pair(kind: .added, after: .image(NSImage(), frameCount: 1))))
        #expect(!ImageDiffMode.difference.isApplicable(for: pair(kind: .deleted, before: .image(NSImage(), frameCount: 1))))
    }
}
