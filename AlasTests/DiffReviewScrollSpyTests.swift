import Foundation
import Testing
@testable import Alas

struct DiffReviewScrollSpyTests {
    @Test func picksVisibleSectionNearestViewportTopFromBelow() {
        let activeID = DiffReviewFileID(namespace: "unstaged", path: "b.swift")
        let frames = [
            DiffReviewSectionFrame(id: DiffReviewFileID(namespace: "unstaged", path: "a.swift"), minY: -180, maxY: 200),
            DiffReviewSectionFrame(id: activeID, minY: 24, maxY: 360),
            DiffReviewSectionFrame(id: DiffReviewFileID(namespace: "unstaged", path: "c.swift"), minY: 380, maxY: 720),
        ]

        let activeFile = DiffReviewScrollSpy.activeFile(in: frames, viewportMinY: 0, viewportMaxY: 500)

        #expect(activeFile == activeID)
    }

    @Test func keepsLongFileActiveWhenItsTopHasScrolledAboveViewport() {
        let activeID = DiffReviewFileID(namespace: "unstaged", path: "large.swift")
        let frames = [
            DiffReviewSectionFrame(id: activeID, minY: -500, maxY: 700),
            DiffReviewSectionFrame(id: DiffReviewFileID(namespace: "unstaged", path: "next.swift"), minY: 760, maxY: 1000),
        ]

        let activeFile = DiffReviewScrollSpy.activeFile(in: frames, viewportMinY: 0, viewportMaxY: 500)

        #expect(activeFile == activeID)
    }

    @Test func ignoresNonIntersectingSections() {
        let frames = [
            DiffReviewSectionFrame(id: DiffReviewFileID(namespace: "unstaged", path: "above.swift"), minY: -400, maxY: -20),
            DiffReviewSectionFrame(id: DiffReviewFileID(namespace: "unstaged", path: "below.swift"), minY: 520, maxY: 700),
        ]

        let activeFile = DiffReviewScrollSpy.activeFile(in: frames, viewportMinY: 0, viewportMaxY: 500)

        #expect(activeFile == nil)
    }

    @Test func breaksEqualMinYTiesByFileID() {
        let expectedID = DiffReviewFileID(namespace: "unstaged", path: "a.swift")
        let frames = [
            DiffReviewSectionFrame(id: DiffReviewFileID(namespace: "unstaged", path: "b.swift"), minY: 24, maxY: 280),
            DiffReviewSectionFrame(id: expectedID, minY: 24, maxY: 320),
        ]

        let activeFile = DiffReviewScrollSpy.activeFile(in: frames, viewportMinY: 0, viewportMaxY: 500)

        #expect(activeFile == expectedID)
    }

    @Test func suppressionIgnoresUpdatesUntilReleased() {
        let first = DiffReviewFileID(namespace: "unstaged", path: "first.swift")
        let second = DiffReviewFileID(namespace: "staged", path: "second.swift")
        var controller = DiffReviewProgrammaticScrollController()

        #expect(controller.acceptsScrollSpyUpdate(for: first))
        #expect(controller.acceptsScrollSpyUpdate(for: second))

        let token = controller.beginProgrammaticScroll(to: second)

        #expect(!controller.acceptsScrollSpyUpdate(for: first))
        #expect(controller.acceptsScrollSpyUpdate(for: second))

        controller.finishProgrammaticScroll(token)

        #expect(controller.acceptsScrollSpyUpdate(for: first))
    }

    @Test func staleProgrammaticScrollFinishDoesNotReleaseNewerSuppression() {
        let first = DiffReviewFileID(namespace: "unstaged", path: "first.swift")
        let second = DiffReviewFileID(namespace: "staged", path: "second.swift")
        var controller = DiffReviewProgrammaticScrollController()

        let tokenA = controller.beginProgrammaticScroll(to: first)
        let tokenB = controller.beginProgrammaticScroll(to: second)

        controller.finishProgrammaticScroll(tokenA)

        #expect(controller.isSuppressing)
        #expect(controller.target == second)
        #expect(!controller.acceptsScrollSpyUpdate(for: first))
        #expect(controller.acceptsScrollSpyUpdate(for: second))

        controller.finishProgrammaticScroll(tokenB)

        #expect(!controller.isSuppressing)
        #expect(controller.target == nil)
        #expect(controller.acceptsScrollSpyUpdate(for: first))
    }

    @Test func resetScrollCommandGenerationStartsNewToggleSequence() {
        let file = DiffReviewFileID(namespace: "unstaged", path: "first.swift")
        var controller = DiffReviewScrollCommandController()
        _ = controller.command(to: file)
        controller.reset()

        #expect(controller.command(to: file).generation == 1)
    }

    @Test func activeSelectionSkipsRedundantScrollUpdates() {
        let first = DiffReviewFileID(namespace: "unstaged", path: "first.swift")
        let second = DiffReviewFileID(namespace: "unstaged", path: "second.swift")
        let frames = [
            DiffReviewSectionFrame(id: first, minY: -20, maxY: 220),
            DiffReviewSectionFrame(id: second, minY: 260, maxY: 420),
        ]

        let unchanged = DiffReviewActiveFileSelection.updatedSelection(
            current: first,
            frames: frames,
            viewportHeight: 200,
            programmaticScroll: DiffReviewProgrammaticScrollController()
        )
        let changed = DiffReviewActiveFileSelection.updatedSelection(
            current: second,
            frames: frames,
            viewportHeight: 200,
            programmaticScroll: DiffReviewProgrammaticScrollController()
        )

        #expect(unchanged == nil)
        #expect(changed == first)
    }

    @Test func activeSelectionUsesScrolledContentCoordinatesNearEndOfReview() {
        let penultimate = DiffReviewFileID(namespace: "commit", path: "Penultimate.swift")
        let last = DiffReviewFileID(namespace: "commit", path: "Last.swift")
        let frames = [
            DiffReviewSectionFrame(id: penultimate, minY: 1_000, maxY: 1_620),
            DiffReviewSectionFrame(id: last, minY: 1_634, maxY: 1_980),
        ]

        let changed = DiffReviewActiveFileSelection.updatedSelection(
            current: penultimate,
            frames: frames,
            viewportMinY: 1_500,
            viewportHeight: 500,
            programmaticScroll: DiffReviewProgrammaticScrollController()
        )
        let unchanged = DiffReviewActiveFileSelection.updatedSelection(
            current: last,
            frames: frames,
            viewportMinY: 1_500,
            viewportHeight: 500,
            programmaticScroll: DiffReviewProgrammaticScrollController()
        )

        #expect(changed == last)
        #expect(unchanged == nil)
    }
}
