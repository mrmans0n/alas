import Foundation
import Testing
@testable import Alas

struct ReviewChangesScrollSpyTests {
    @Test func picksVisibleSectionNearestViewportTopFromBelow() {
        let activeID = ReviewChangesFileID(source: .unstaged, path: "b.swift")
        let frames = [
            ReviewChangesSectionFrame(id: ReviewChangesFileID(source: .unstaged, path: "a.swift"), minY: -180, maxY: 200),
            ReviewChangesSectionFrame(id: activeID, minY: 24, maxY: 360),
            ReviewChangesSectionFrame(id: ReviewChangesFileID(source: .unstaged, path: "c.swift"), minY: 380, maxY: 720),
        ]

        let activeFile = ReviewChangesScrollSpy.activeFile(in: frames, viewportMinY: 0, viewportMaxY: 500)

        #expect(activeFile == activeID)
    }

    @Test func keepsLongFileActiveWhenItsTopHasScrolledAboveViewport() {
        let activeID = ReviewChangesFileID(source: .unstaged, path: "large.swift")
        let frames = [
            ReviewChangesSectionFrame(id: activeID, minY: -500, maxY: 700),
            ReviewChangesSectionFrame(id: ReviewChangesFileID(source: .unstaged, path: "next.swift"), minY: 760, maxY: 1000),
        ]

        let activeFile = ReviewChangesScrollSpy.activeFile(in: frames, viewportMinY: 0, viewportMaxY: 500)

        #expect(activeFile == activeID)
    }

    @Test func ignoresNonIntersectingSections() {
        let frames = [
            ReviewChangesSectionFrame(id: ReviewChangesFileID(source: .unstaged, path: "above.swift"), minY: -400, maxY: -20),
            ReviewChangesSectionFrame(id: ReviewChangesFileID(source: .unstaged, path: "below.swift"), minY: 520, maxY: 700),
        ]

        let activeFile = ReviewChangesScrollSpy.activeFile(in: frames, viewportMinY: 0, viewportMaxY: 500)

        #expect(activeFile == nil)
    }

    @Test func breaksEqualMinYTiesByFileID() {
        let expectedID = ReviewChangesFileID(source: .unstaged, path: "a.swift")
        let frames = [
            ReviewChangesSectionFrame(id: ReviewChangesFileID(source: .unstaged, path: "b.swift"), minY: 24, maxY: 280),
            ReviewChangesSectionFrame(id: expectedID, minY: 24, maxY: 320),
        ]

        let activeFile = ReviewChangesScrollSpy.activeFile(in: frames, viewportMinY: 0, viewportMaxY: 500)

        #expect(activeFile == expectedID)
    }

    @Test func suppressionIgnoresUpdatesUntilReleased() {
        let first = ReviewChangesFileID(source: .unstaged, path: "first.swift")
        let second = ReviewChangesFileID(source: .staged, path: "second.swift")
        var controller = ReviewChangesProgrammaticScrollController()

        #expect(controller.acceptsScrollSpyUpdate(for: first))
        #expect(controller.acceptsScrollSpyUpdate(for: second))

        let token = controller.beginProgrammaticScroll(to: second)

        #expect(!controller.acceptsScrollSpyUpdate(for: first))
        #expect(controller.acceptsScrollSpyUpdate(for: second))

        controller.finishProgrammaticScroll(token)

        #expect(controller.acceptsScrollSpyUpdate(for: first))
    }

    @Test func staleProgrammaticScrollFinishDoesNotReleaseNewerSuppression() {
        let first = ReviewChangesFileID(source: .unstaged, path: "first.swift")
        let second = ReviewChangesFileID(source: .staged, path: "second.swift")
        var controller = ReviewChangesProgrammaticScrollController()

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

    @Test func activeSelectionSkipsRedundantScrollUpdates() {
        let first = ReviewChangesFileID(source: .unstaged, path: "first.swift")
        let second = ReviewChangesFileID(source: .unstaged, path: "second.swift")
        let frames = [
            ReviewChangesSectionFrame(id: first, minY: -20, maxY: 220),
            ReviewChangesSectionFrame(id: second, minY: 260, maxY: 420),
        ]

        let unchanged = ReviewChangesActiveFileSelection.updatedSelection(
            current: first,
            frames: frames,
            viewportHeight: 200,
            programmaticScroll: ReviewChangesProgrammaticScrollController()
        )
        let changed = ReviewChangesActiveFileSelection.updatedSelection(
            current: second,
            frames: frames,
            viewportHeight: 200,
            programmaticScroll: ReviewChangesProgrammaticScrollController()
        )

        #expect(unchanged == nil)
        #expect(changed == first)
    }
}
