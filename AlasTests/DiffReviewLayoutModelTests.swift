import CoreGraphics
import Testing
@testable import Alas

struct DiffReviewLayoutModelTests {
    private func id(_ path: String) -> DiffReviewFileID {
        DiffReviewFileID(namespace: "unstaged", path: path)
    }

    @Test func stacksFramesWithTopInsetAndSpacing() {
        let a = id("a.swift")
        let b = id("b.swift")
        let c = id("c.swift")
        let heights: [DiffReviewFileID: CGFloat] = [a: 100, b: 200, c: 50]
        let model = DiffReviewLayoutModel(
            orderedFileIDs: [a, b, c],
            height: { heights[$0] ?? 0 },
            topInset: 16,
            spacing: 14
        )

        let frames = model.sectionFrames()

        #expect(frames.count == 3)
        // a: starts at topInset 16, height 100
        #expect(frames[0].minY == 16)
        #expect(frames[0].maxY == 116)
        // b: 116 + spacing 14 = 130, height 200
        #expect(frames[1].minY == 130)
        #expect(frames[1].maxY == 330)
        // c: 330 + 14 = 344, height 50
        #expect(frames[2].minY == 344)
        #expect(frames[2].maxY == 394)
    }

    @Test func viewportRelativeFramesSubtractScrollOffset() {
        let a = id("a.swift")
        let b = id("b.swift")
        let model = DiffReviewLayoutModel(
            orderedFileIDs: [a, b],
            height: { _ in 100 },
            topInset: 0,
            spacing: 0
        )

        // Scrolled down so the top 150pt are above the viewport.
        let frames = model.viewportRelativeFrames(scrollMinY: 150)

        // a: content 0..100 -> relative -150..-50
        #expect(frames[0].minY == -150)
        #expect(frames[0].maxY == -50)
        // b: content 100..200 -> relative -50..50
        #expect(frames[1].minY == -50)
        #expect(frames[1].maxY == 50)
    }

    @Test func emptyFilesProduceNoFrames() {
        let model = DiffReviewLayoutModel(
            orderedFileIDs: [],
            height: { _ in 100 },
            topInset: 16,
            spacing: 14
        )
        #expect(model.sectionFrames().isEmpty)
        #expect(model.viewportRelativeFrames(scrollMinY: 0).isEmpty)
    }
}
