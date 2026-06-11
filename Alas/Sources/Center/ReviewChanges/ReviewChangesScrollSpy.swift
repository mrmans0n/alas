import CoreGraphics

struct ReviewChangesSectionFrame: Equatable {
    let id: ReviewChangesFileID
    let minY: CGFloat
    let maxY: CGFloat

    func intersects(viewportMinY: CGFloat, viewportMaxY: CGFloat) -> Bool {
        maxY > viewportMinY && minY < viewportMaxY
    }
}

enum ReviewChangesScrollSpy {
    static func activeFile(
        in frames: [ReviewChangesSectionFrame],
        viewportMinY: CGFloat,
        viewportMaxY: CGFloat
    ) -> ReviewChangesFileID? {
        let intersectingFrames = frames.filter {
            $0.intersects(viewportMinY: viewportMinY, viewportMaxY: viewportMaxY)
        }

        if let nearestFromBelow = intersectingFrames
            .filter({ $0.minY >= viewportMinY })
            .min(by: { $0.minY < $1.minY })
        {
            return nearestFromBelow.id
        }

        return intersectingFrames
            .filter { $0.minY < viewportMinY }
            .max(by: { $0.minY < $1.minY })?
            .id
    }
}

struct ReviewChangesProgrammaticScrollController: Equatable {
    private(set) var target: ReviewChangesFileID?
    private(set) var isSuppressing = false

    mutating func beginProgrammaticScroll(to target: ReviewChangesFileID) {
        self.target = target
        isSuppressing = true
    }

    mutating func finishProgrammaticScroll() {
        target = nil
        isSuppressing = false
    }

    func acceptsScrollSpyUpdate(for id: ReviewChangesFileID) -> Bool {
        !isSuppressing || id == target
    }
}
