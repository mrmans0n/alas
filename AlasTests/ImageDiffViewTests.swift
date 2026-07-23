import AppKit
import Testing
@testable import Alas

struct ImageDiffViewTests {
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

    @Test func snapsToSideBySideWhenCurrentModeIsDisabledForAdded() {
        var mode: ImageDiffMode = .overlay
        ImageDiffView.snapToApplicableMode(&mode, for: pair(kind: .added))
        #expect(mode == .sideBySide)
    }

    @Test func snapsToSideBySideWhenCurrentModeIsDisabledForDeleted() {
        var mode: ImageDiffMode = .difference
        ImageDiffView.snapToApplicableMode(&mode, for: pair(kind: .deleted))
        #expect(mode == .sideBySide)
    }

    @Test func leavesApplicableModeAloneForModified() {
        var mode: ImageDiffMode = .difference
        ImageDiffView.snapToApplicableMode(&mode, for: loadedPair(kind: .modified))
        #expect(mode == .difference)
    }

    @Test func leavesSideBySideAloneAlways() {
        for kind in ImageDiffPairKind.allCases {
            var mode: ImageDiffMode = .sideBySide
            ImageDiffView.snapToApplicableMode(&mode, for: pair(kind: kind))
            #expect(mode == .sideBySide)
        }
    }
}
