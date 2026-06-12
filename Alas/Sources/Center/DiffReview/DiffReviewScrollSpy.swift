import CoreGraphics

struct DiffReviewSectionFrame: Equatable {
    let id: DiffReviewFileID
    let minY: CGFloat
    let maxY: CGFloat

    func intersects(viewportMinY: CGFloat, viewportMaxY: CGFloat) -> Bool {
        maxY > viewportMinY && minY < viewportMaxY
    }
}

enum DiffReviewScrollSpy {
    static func activeFile(
        in frames: [DiffReviewSectionFrame],
        viewportMinY: CGFloat,
        viewportMaxY: CGFloat
    ) -> DiffReviewFileID? {
        let intersectingFrames = frames.filter {
            $0.intersects(viewportMinY: viewportMinY, viewportMaxY: viewportMaxY)
        }

        if let nearestFromBelow = intersectingFrames
            .filter({ $0.minY >= viewportMinY })
            .min(by: sectionOrder)
        {
            return nearestFromBelow.id
        }

        return intersectingFrames
            .filter { $0.minY < viewportMinY }
            .min {
                let lhsDistance = viewportMinY - $0.minY
                let rhsDistance = viewportMinY - $1.minY

                if lhsDistance != rhsDistance {
                    return lhsDistance < rhsDistance
                }
                return $0.id.rawValue < $1.id.rawValue
            }?
            .id
    }

    private static func sectionOrder(_ lhs: DiffReviewSectionFrame, _ rhs: DiffReviewSectionFrame) -> Bool {
        if lhs.minY != rhs.minY {
            return lhs.minY < rhs.minY
        }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}

enum DiffReviewActiveFileSelection {
    static func updatedSelection(
        current: DiffReviewFileID?,
        frames: [DiffReviewSectionFrame],
        viewportHeight: CGFloat,
        programmaticScroll: DiffReviewProgrammaticScrollController
    ) -> DiffReviewFileID? {
        guard
            let active = DiffReviewScrollSpy.activeFile(
                in: frames,
                viewportMinY: 0,
                viewportMaxY: viewportHeight
            ),
            active != current,
            programmaticScroll.acceptsScrollSpyUpdate(for: active)
        else { return nil }

        return active
    }
}

struct DiffReviewProgrammaticScrollController: Equatable {
    struct Token: Equatable {
        fileprivate let generation: Int
    }

    private(set) var target: DiffReviewFileID?
    private(set) var isSuppressing = false
    private var generation = 0

    mutating func beginProgrammaticScroll(to target: DiffReviewFileID) -> Token {
        generation += 1
        self.target = target
        isSuppressing = true
        return Token(generation: generation)
    }

    mutating func finishProgrammaticScroll(_ token: Token) {
        guard isSuppressing, token.generation == generation else { return }

        target = nil
        isSuppressing = false
    }

    func acceptsScrollSpyUpdate(for id: DiffReviewFileID) -> Bool {
        !isSuppressing || id == target
    }
}
