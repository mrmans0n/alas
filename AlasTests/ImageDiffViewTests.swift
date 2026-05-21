import Testing
@testable import Alas

struct ImageDiffViewTests {
    @Test func snapsToSideBySideWhenCurrentModeIsDisabledForAdded() {
        var mode: ImageDiffMode = .overlay
        ImageDiffView.snapToApplicableMode(&mode, for: .added)
        #expect(mode == .sideBySide)
    }

    @Test func snapsToSideBySideWhenCurrentModeIsDisabledForDeleted() {
        var mode: ImageDiffMode = .difference
        ImageDiffView.snapToApplicableMode(&mode, for: .deleted)
        #expect(mode == .sideBySide)
    }

    @Test func leavesApplicableModeAloneForModified() {
        var mode: ImageDiffMode = .difference
        ImageDiffView.snapToApplicableMode(&mode, for: .modified)
        #expect(mode == .difference)
    }

    @Test func leavesSideBySideAloneAlways() {
        for kind in ImageDiffPairKind.allCases {
            var mode: ImageDiffMode = .sideBySide
            ImageDiffView.snapToApplicableMode(&mode, for: kind)
            #expect(mode == .sideBySide)
        }
    }
}
