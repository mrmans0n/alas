import AppKit
import SwiftUI

enum DiffFeedbackLane: String, Equatable, Hashable, Sendable {
    case left
    case right
    case full
}

enum DiffFeedbackLaneResolver {
    static func lane(for anchor: DiffReviewLineAnchor) -> DiffFeedbackLane {
        let changedSides = Set(anchor.selectedLines.lazy.filter(\.isChange).map(\.side))

        if changedSides.contains(.new) {
            return .right
        }
        if changedSides.contains(.old) {
            return .left
        }
        return lane(for: anchor.side)
    }

    static func lane(for comment: ReviewDraftComment) -> DiffFeedbackLane {
        lane(for: comment.side)
    }

    static func lane(for feedback: DiffReviewInlineFeedback) -> DiffFeedbackLane {
        lane(for: feedback.anchor.side)
    }

    static func lane(for thread: DiffInlineCommentThread) -> DiffFeedbackLane {
        thread.isOldSide ? .left : .right
    }

    static func lane(for annotation: DiffInlineAnnotation) -> DiffFeedbackLane {
        lane(for: DiffReviewInlineFeedbackSide.new)
    }

    static func lane(for side: DiffReviewInlineFeedbackSide) -> DiffFeedbackLane {
        switch side {
        case .old:
            .left
        case .new, .unknown:
            .right
        }
    }
}

@MainActor
enum DiffPaneLineNumberGutterGeometry {
    static let minimumThickness: CGFloat = 42
    static let horizontalPadding: CGFloat = 8
    static var labelFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    }

    static func thickness(labels: [String]) -> CGFloat {
        let maxDigits = labels
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "+- ")) }
            .map(\.count)
            .max() ?? 1
        let sample = String(repeating: "8", count: max(maxDigits, 1)) as NSString
        let width = ceil(sample.size(withAttributes: [.font: labelFont]).width)
        return max(minimumThickness, width + horizontalPadding * 2)
    }
}

struct DiffPaneSplitFrames: Equatable {
    let oldPane: CGRect
    let divider: CGRect
    let newPane: CGRect
}

enum DiffPaneSplitGeometry {
    static let dividerWidth: CGFloat = 1

    static func frames(containerWidth: CGFloat) -> DiffPaneSplitFrames {
        let width = max(containerWidth, 0)
        let dividerExtent = min(dividerWidth, width)
        let oldWidth = floor(max(width - dividerExtent, 0) / 2)
        let newOrigin = oldWidth + dividerExtent
        let newWidth = max(width - newOrigin, 0)

        return DiffPaneSplitFrames(
            oldPane: CGRect(x: 0, y: 0, width: oldWidth, height: 0),
            divider: CGRect(x: oldWidth, y: 0, width: dividerExtent, height: 0),
            newPane: CGRect(x: newOrigin, y: 0, width: newWidth, height: 0)
        )
    }
}

enum DiffFeedbackLineLabels {
    static func labels(
        for rows: [DiffDisplayRow],
        layoutMode: DiffLayoutMode,
        lane: DiffFeedbackLane
    ) -> [String] {
        switch layoutMode {
        case .split:
            switch lane {
            case .left:
                rows.compactMap { $0.old?.lineNumber.map(String.init) }
            case .right, .full:
                rows.compactMap { $0.new?.lineNumber.map(String.init) }
            }
        case .stacked:
            DiffPaneRowProjection.stackedLines(for: rows).compactMap {
                $0.line.lineNumber.map(String.init)
            }
        }
    }
}

enum DiffFeedbackLaneGeometry {
    static let dividerWidth = DiffPaneSplitGeometry.dividerWidth

    static func containerWidth(for proposal: ProposedViewSize) -> CGFloat {
        proposal.width.map { max($0, 0) } ?? 0
    }

    static func contentFrame(
        containerWidth: CGFloat,
        layoutMode: DiffLayoutMode,
        lane: DiffFeedbackLane,
        gutterWidth: CGFloat
    ) -> CGRect {
        let width = max(containerWidth, 0)
        guard layoutMode == .split else {
            let inset = min(max(gutterWidth, 0), width)
            return CGRect(x: inset, y: 0, width: width - inset, height: 0)
        }

        let splitFrames = DiffPaneSplitGeometry.frames(containerWidth: width)
        if lane == .left {
            let inset = min(max(gutterWidth, 0), splitFrames.oldPane.width)
            return CGRect(
                x: splitFrames.oldPane.minX + inset,
                y: 0,
                width: splitFrames.oldPane.width - inset,
                height: 0
            )
        }

        let inset = min(max(gutterWidth, 0), splitFrames.newPane.width)
        return CGRect(
            x: splitFrames.newPane.minX + inset,
            y: 0,
            width: splitFrames.newPane.width - inset,
            height: 0
        )
    }
}

private struct DiffFeedbackLaneLayout: Layout {
    let layoutMode: DiffLayoutMode
    let lane: DiffFeedbackLane
    let gutterWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else {
            return CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
        }
        let width = DiffFeedbackLaneGeometry.containerWidth(for: proposal)
        let frame = DiffFeedbackLaneGeometry.contentFrame(
            containerWidth: width,
            layoutMode: layoutMode,
            lane: lane,
            gutterWidth: gutterWidth
        )
        let contentSize = subview.sizeThatFits(.init(width: frame.width, height: proposal.height))
        return CGSize(width: width, height: contentSize.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        let frame = DiffFeedbackLaneGeometry.contentFrame(
            containerWidth: bounds.width,
            layoutMode: layoutMode,
            lane: lane,
            gutterWidth: gutterWidth
        )
        subview.place(
            at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: .init(width: frame.width, height: proposal.height)
        )
    }
}

struct DiffFeedbackLaneView<Content: View>: View {
    let lane: DiffFeedbackLane
    let layoutMode: DiffLayoutMode
    let rows: [DiffDisplayRow]
    private let content: Content

    @Environment(\.theme) private var theme

    init(
        lane: DiffFeedbackLane,
        layoutMode: DiffLayoutMode,
        rows: [DiffDisplayRow],
        @ViewBuilder content: () -> Content
    ) {
        self.lane = lane
        self.layoutMode = layoutMode
        self.rows = rows
        self.content = content()
    }

    private var effectiveLane: DiffFeedbackLane {
        layoutMode == .stacked ? .full : lane
    }

    var body: some View {
        let labels = DiffFeedbackLineLabels.labels(for: rows, layoutMode: layoutMode, lane: lane)
        let gutterWidth = DiffPaneLineNumberGutterGeometry.thickness(labels: labels)

        DiffFeedbackLaneLayout(
            layoutMode: layoutMode,
            lane: effectiveLane,
            gutterWidth: gutterWidth
        ) {
            VStack(spacing: 0) {
                content
            }
        }
        .overlay(alignment: .topLeading) {
            if layoutMode == .split {
                GeometryReader { geometry in
                    let divider = DiffPaneSplitGeometry.frames(
                        containerWidth: geometry.size.width
                    ).divider

                    Rectangle()
                        .fill(theme.color("line"))
                        .frame(width: divider.width, height: geometry.size.height)
                        .background(DiffFeedbackAccessibilityMarker(
                            identifier: "diff-feedback-divider"
                        ))
                        .offset(x: divider.minX)
                }
                .allowsHitTesting(false)
            }
        }
        .background(DiffFeedbackAccessibilityMarker(
            identifier: "diff-feedback-lane-\(effectiveLane.rawValue)"
        ))
    }
}

private struct DiffFeedbackAccessibilityMarker: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityIdentifier(identifier)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.setAccessibilityIdentifier(identifier)
    }
}
