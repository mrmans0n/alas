import Combine
import CoreGraphics
import Foundation

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
        updatedSelection(
            current: current,
            frames: frames,
            viewportMinY: 0,
            viewportHeight: viewportHeight,
            programmaticScroll: programmaticScroll
        )
    }

    static func updatedSelection(
        current: DiffReviewFileID?,
        frames: [DiffReviewSectionFrame],
        viewportMinY: CGFloat,
        viewportHeight: CGFloat,
        programmaticScroll: DiffReviewProgrammaticScrollController
    ) -> DiffReviewFileID? {
        guard
            let active = DiffReviewScrollSpy.activeFile(
                in: frames,
                viewportMinY: viewportMinY,
                viewportMaxY: viewportMinY + viewportHeight
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

    /// Whether `token` still refers to the in-flight programmatic scroll.
    /// A newer `beginProgrammaticScroll` supersedes older tokens (the
    /// generation advances), so a delayed scroll task can use this to abort
    /// rather than yank the viewport back to a stale destination.
    func isCurrent(_ token: Token) -> Bool {
        token.generation == generation
    }

    func acceptsScrollSpyUpdate(for id: DiffReviewFileID) -> Bool {
        !isSuppressing || id == target
    }
}

struct DiffReviewScrollCommand: Equatable {
    let id: DiffReviewFileID
    let generation: Int
}

struct DiffReviewScrollCommandController: Equatable {
    private var generation = 0

    mutating func command(to id: DiffReviewFileID) -> DiffReviewScrollCommand {
        generation += 1
        return DiffReviewScrollCommand(id: id, generation: generation)
    }

    mutating func reset() {
        generation = 0
    }
}

enum DiffReviewScrollCommandConsumption {
    static func consume(
        current: DiffReviewScrollCommand?,
        consumed: DiffReviewScrollCommand
    ) -> DiffReviewScrollCommand? {
        current == consumed ? nil : current
    }
}

enum DiffReviewFileSectionHeightEstimator {
    private static let fileHeaderHeight: CGFloat = 45
    private static let hunkHeaderHeight: CGFloat = 38
    private static let hunkVerticalPadding: CGFloat = 20
    private static let rowHeight: CGFloat = 22
    private static let hunkSpacing: CGFloat = 10
    private static let minimumHeight: CGFloat = 116

    static func estimatedHeight(for file: DiffReviewFileSectionModel) -> CGFloat {
        guard let displayModel = file.displayModel else {
            return minimumHeight
        }

        let bodyHeight = displayModel.groups.reduce(CGFloat(0)) { total, group in
            let rowCount = max(group.rows.count, 1)
            return total
                + hunkHeaderHeight
                + hunkVerticalPadding
                + CGFloat(rowCount) * rowHeight
                + hunkSpacing
        }

        return max(minimumHeight, fileHeaderHeight + bodyHeight)
    }
}

/// The file the scroll spy reports while the user scrolls a review.
///
/// Writing the surface's selected-file binding re-renders the whole review
/// (row plan, rail, and the owning tab, which may persist the selection), and
/// a fling crosses file boundaries a few times a second. Only the rail needs
/// to follow along live, so it alone observes `liveFileID`; the binding gets
/// the final file once scrolling has been still for `settleInterval`.
@MainActor
final class DiffReviewScrollSpySelection: ObservableObject {
    @Published private(set) var liveFileID: DiffReviewFileID?
    /// Writes the settled file to the selection binding.
    var onSettle: (DiffReviewFileID) -> Void = { _ in }
    private let settleInterval: TimeInterval
    private var lastMotion: TimeInterval = 0
    private var isSettleCheckScheduled = false

    init(settleInterval: TimeInterval = 0.3) {
        self.settleInterval = settleInterval
    }

    func report(_ fileID: DiffReviewFileID) {
        if liveFileID != fileID { liveFileID = fileID }
        userDidScroll()
    }

    /// Called on every user scroll tick; postpones the settle while moving.
    func userDidScroll() {
        lastMotion = ProcessInfo.processInfo.systemUptime
        guard liveFileID != nil, !isSettleCheckScheduled else { return }
        scheduleSettleCheck(after: settleInterval)
    }

    /// Hands any pending file to the binding now, e.g. when the surface goes away.
    func settle() {
        guard let fileID = liveFileID else { return }
        liveFileID = nil
        onSettle(fileID)
    }

    /// Drops a pending file the binding has been set past.
    func discard() {
        if liveFileID != nil { liveFileID = nil }
    }

    private func scheduleSettleCheck(after delay: TimeInterval) {
        isSettleCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            isSettleCheckScheduled = false
            let still = ProcessInfo.processInfo.systemUptime - lastMotion
            if still >= settleInterval {
                settle()
            } else if liveFileID != nil {
                scheduleSettleCheck(after: settleInterval - still)
            }
        }
    }
}
