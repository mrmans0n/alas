import CoreGraphics

/// Pure-logic layout table for the stacked review surface.
///
/// Maps each file section to its content-space vertical span using cached or
/// estimated heights, mirroring the `LazyVStack(spacing:)` + `.padding()` of
/// `DiffReviewSurface`. Replaces the per-section `GeometryReader` frames that
/// went dark on macOS 15+ (Tahoe). Feeds the existing `DiffReviewScrollSpy` /
/// `DiffReviewRenderWindow` logic via synthesized `DiffReviewSectionFrame`s.
struct DiffReviewLayoutModel {
    private let frames: [DiffReviewSectionFrame]

    init(
        orderedFileIDs: [DiffReviewFileID],
        height: (DiffReviewFileID) -> CGFloat,
        topInset: CGFloat,
        spacing: CGFloat
    ) {
        var result: [DiffReviewSectionFrame] = []
        result.reserveCapacity(orderedFileIDs.count)
        var cursor = topInset
        for id in orderedFileIDs {
            let h = height(id)
            result.append(DiffReviewSectionFrame(id: id, minY: cursor, maxY: cursor + h))
            cursor += h + spacing
        }
        frames = result
    }

    func sectionFrames() -> [DiffReviewSectionFrame] {
        frames
    }

    func viewportRelativeFrames(scrollMinY: CGFloat) -> [DiffReviewSectionFrame] {
        frames.map {
            DiffReviewSectionFrame(id: $0.id, minY: $0.minY - scrollMinY, maxY: $0.maxY - scrollMinY)
        }
    }
}
