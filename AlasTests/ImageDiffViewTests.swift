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

    @MainActor
    @Test func snapsToSideBySideWhenCurrentModeIsDisabledForAdded() {
        let state = ImageDiffPresentationState()
        state.mode = .overlay

        state.snapToApplicableMode(for: pair(kind: .added))

        #expect(state.mode == .sideBySide)
    }

    @MainActor
    @Test func snapsToSideBySideWhenCurrentModeIsDisabledForDeleted() {
        let state = ImageDiffPresentationState()
        state.mode = .difference

        state.snapToApplicableMode(for: pair(kind: .deleted))

        #expect(state.mode == .sideBySide)
    }

    @MainActor
    @Test func leavesApplicableModeAloneForModified() {
        let state = ImageDiffPresentationState()
        state.mode = .difference

        state.snapToApplicableMode(for: loadedPair(kind: .modified))

        #expect(state.mode == .difference)
    }

    @MainActor
    @Test func leavesSideBySideAloneAlways() {
        for kind in ImageDiffPairKind.allCases {
            let state = ImageDiffPresentationState()
            state.snapToApplicableMode(for: pair(kind: kind))
            #expect(state.mode == .sideBySide)
        }
    }

    @MainActor
    @Test func presentationResetsWhenDisplayedPairChanges() {
        let firstPair = loadedPair(kind: .modified)
        let secondPair = loadedPair(kind: .modified)
        let state = ImageDiffPresentationState()

        state.updateDisplayedPair(
            firstPair,
            identity: ImageDiffPairPresentationIdentity(
                pair: firstPair,
                relativePath: "first.png"
            )
        )
        state.mode = .difference
        state.transform = ImageDiffTransform(
            scale: 2,
            offset: CGSize(width: 20, height: 10)
        )
        state.percentChanged = 42

        state.updateDisplayedPair(
            secondPair,
            identity: ImageDiffPairPresentationIdentity(
                pair: secondPair,
                relativePath: "second.png"
            )
        )

        #expect(state.mode == .sideBySide)
        #expect(state.transform == ImageDiffTransform())
        #expect(state.percentChanged == nil)
    }

    @MainActor
    @Test func presentationSnapsAwayFromUnavailableMode() {
        let state = ImageDiffPresentationState()
        state.mode = .overlay
        let pair = ImageDiffPair(
            before: .missing,
            after: .image(NSImage(size: NSSize(width: 1, height: 1)), frameCount: 1),
            oldPath: nil,
            kind: .added
        )

        state.snapToApplicableMode(for: pair)

        #expect(state.mode == .sideBySide)
    }
}
