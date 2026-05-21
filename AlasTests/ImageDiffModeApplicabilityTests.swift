import Testing
@testable import Alas

struct ImageDiffModeApplicabilityTests {
    @Test func sideBySideAlwaysApplicable() {
        for kind in ImageDiffPairKind.allCases {
            #expect(ImageDiffMode.sideBySide.isApplicable(for: kind))
        }
    }

    @Test func overlayDisabledForOneSidedDiffs() {
        #expect(ImageDiffMode.overlay.isApplicable(for: .modified))
        #expect(ImageDiffMode.overlay.isApplicable(for: .renamed))
        #expect(!ImageDiffMode.overlay.isApplicable(for: .added))
        #expect(!ImageDiffMode.overlay.isApplicable(for: .deleted))
    }

    @Test func swipeDisabledForOneSidedDiffs() {
        #expect(ImageDiffMode.swipe.isApplicable(for: .modified))
        #expect(ImageDiffMode.swipe.isApplicable(for: .renamed))
        #expect(!ImageDiffMode.swipe.isApplicable(for: .added))
        #expect(!ImageDiffMode.swipe.isApplicable(for: .deleted))
    }

    @Test func differenceDisabledForOneSidedDiffs() {
        #expect(ImageDiffMode.difference.isApplicable(for: .modified))
        #expect(ImageDiffMode.difference.isApplicable(for: .renamed))
        #expect(!ImageDiffMode.difference.isApplicable(for: .added))
        #expect(!ImageDiffMode.difference.isApplicable(for: .deleted))
    }
}
