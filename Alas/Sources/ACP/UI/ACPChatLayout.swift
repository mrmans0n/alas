import CoreGraphics
import SwiftUI

enum ACPChatLayout {
    static let defaultContentMaxWidth: CGFloat = 720
    static let wideContentMaxWidth: CGFloat = 960
    static func contentMaxWidth(forChatColumnWidth columnWidth: CGFloat) -> CGFloat {
        let growthStartPaneWidth: CGFloat = 1_080
        guard columnWidth > growthStartPaneWidth else {
            return defaultContentMaxWidth
        }

        let extraWidth = columnWidth - growthStartPaneWidth
        return min(wideContentMaxWidth, defaultContentMaxWidth + extraWidth)
    }

    /// The agent transcript's column. Unlike the panes above it never grows
    /// past `readingColumnMax`: long lines are what it exists to prevent.
    static func readingColumnWidth(scale: DesignScale) -> CGFloat {
        scale.readingColumnMax
    }

    static func contentMaxWidth(forPaneWidth paneWidth: CGFloat) -> CGFloat {
        contentMaxWidth(forChatColumnWidth: paneWidth)
    }

    /// Where a transcript row's content goes. Prose sits in the reading column;
    /// code, tables and diffs share its left edge and run on to `breakoutWidth`.
    struct TranscriptColumns: Equatable {
        let minX: CGFloat
        let readingWidth: CGFloat
        let breakoutWidth: CGFloat

        var breakoutMaxX: CGFloat { minX + breakoutWidth }
    }

    /// Clear of a row's edge on each side: padding plus a lane for the actions menu.
    static var transcriptRowInset: CGFloat {
        ACPTranscriptCoreTextRowView.columnHorizontalPadding + ACPMessageGutterLayout.laneWidth
    }

    /// Centers the reading column, moving it left only as far as the breakout
    /// width needs to fit. Shared by native rows and `ACPTranscriptColumnLayout`,
    /// so both put text in the same place.
    static func transcriptColumns(rowWidth: CGFloat, readingMax: CGFloat) -> TranscriptColumns {
        let breakout = min(
            max(contentMaxWidth(forChatColumnWidth: rowWidth), readingMax),
            max(0, rowWidth - 2 * transcriptRowInset)
        )
        let reading = min(readingMax, breakout)
        let minX = min((rowWidth - reading) / 2, rowWidth - transcriptRowInset - breakout)
        return TranscriptColumns(minX: max(0, minX.rounded()), readingWidth: reading, breakoutWidth: breakout)
    }
}

/// Places one transcript row, or the composer aligned with it, in the columns
/// of `ACPChatLayout.transcriptColumns`.
struct ACPTranscriptColumnLayout: Layout {
    enum Role {
        case reading
        /// Takes the breakout width; prose inside is held back by `acpMarkdownProseMaxWidth`.
        case breakout
        /// The reading column, except that a narrow pane gets its old, smaller
        /// margins: the toolbar needs the room more than it needs the alignment.
        case composer
    }

    let readingMax: CGFloat
    var role: Role = .reading

    private static let composerNarrowInset: CGFloat = 24

    private func frame(in rowWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let columns = ACPChatLayout.transcriptColumns(rowWidth: rowWidth, readingMax: readingMax)
        switch role {
        case .reading:
            return (columns.minX, columns.readingWidth)
        case .breakout:
            return (columns.minX, columns.breakoutWidth)
        case .composer:
            guard columns.readingWidth < readingMax else { return (columns.minX, columns.readingWidth) }
            return (Self.composerNarrowInset, min(readingMax, max(0, rowWidth - 2 * Self.composerNarrowInset)))
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        guard let rowWidth = proposal.width, rowWidth.isFinite else {
            let ideal = child.sizeThatFits(.unspecified)
            return CGSize(width: min(ideal.width, readingMax) + 2 * ACPChatLayout.transcriptRowInset, height: ideal.height)
        }
        let height = child.sizeThatFits(ProposedViewSize(width: frame(in: rowWidth).width, height: proposal.height)).height
        return CGSize(width: rowWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let frame = frame(in: bounds.width)
        child.place(
            at: CGPoint(x: bounds.minX + frame.x, y: bounds.minY), anchor: .topLeading,
            proposal: ProposedViewSize(width: frame.width, height: bounds.height)
        )
    }
}

extension EnvironmentValues {
    /// The widest prose may get inside a row that takes the breakout width.
    /// Nil everywhere else, where prose fills what it is given.
    @Entry var acpMarkdownProseMaxWidth: CGFloat? = nil
}

extension View {
    /// For content indented by `inset` inside a breakout row, so its prose still
    /// ends at the reading column's edge, as native rows' does.
    func acpInsetsProse(by inset: CGFloat) -> some View {
        transformEnvironment(\.acpMarkdownProseMaxWidth) { width in
            width = width.map { $0 - inset }
        }
    }
}
