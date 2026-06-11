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

    @Test func suppressionIgnoresUpdatesUntilReleased() {
        let first = ReviewChangesFileID(source: .unstaged, path: "first.swift")
        let second = ReviewChangesFileID(source: .staged, path: "second.swift")
        var controller = ReviewChangesProgrammaticScrollController()

        #expect(controller.acceptsScrollSpyUpdate(for: first))
        #expect(controller.acceptsScrollSpyUpdate(for: second))

        controller.beginProgrammaticScroll(to: second)

        #expect(!controller.acceptsScrollSpyUpdate(for: first))
        #expect(controller.acceptsScrollSpyUpdate(for: second))

        controller.finishProgrammaticScroll()

        #expect(controller.acceptsScrollSpyUpdate(for: first))
    }
}
