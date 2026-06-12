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

    private static func sectionOrder(_ lhs: ReviewChangesSectionFrame, _ rhs: ReviewChangesSectionFrame) -> Bool {
        if lhs.minY != rhs.minY {
            return lhs.minY < rhs.minY
        }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}

enum ReviewChangesActiveFileSelection {
    static func updatedSelection(
        current: ReviewChangesFileID?,
        frames: [ReviewChangesSectionFrame],
        viewportHeight: CGFloat,
        programmaticScroll: ReviewChangesProgrammaticScrollController
    ) -> ReviewChangesFileID? {
        guard
            let active = ReviewChangesScrollSpy.activeFile(
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

struct ReviewChangesProgrammaticScrollController: Equatable {
    struct Token: Equatable {
        fileprivate let generation: Int
    }

    private(set) var target: ReviewChangesFileID?
    private(set) var isSuppressing = false
    private var generation = 0

    mutating func beginProgrammaticScroll(to target: ReviewChangesFileID) -> Token {
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

    func acceptsScrollSpyUpdate(for id: ReviewChangesFileID) -> Bool {
        !isSuppressing || id == target
    }
}
