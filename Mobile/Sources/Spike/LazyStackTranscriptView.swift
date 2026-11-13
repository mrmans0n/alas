import SwiftUI

/// Candidate B: a SwiftUI ScrollView over a LazyVStack.
struct LazyStackTranscriptView: View {
    let model: SpikeTranscriptModel
    let onFirstLayout: () -> Void

    /// Tracks the top visible row id, which keeps that row in place when older rows are
    /// prepended, and scrolls to the bottom edge for tail-follow.
    @State private var position = ScrollPosition(idType: String.self)
    @State private var atBottom = true
    @State private var phase = ScrollPhase.idle
    @State private var laidOut = false

    init(model: SpikeTranscriptModel, onFirstLayout: @escaping () -> Void) {
        self.model = model
        self.onFirstLayout = onFirstLayout
    }

    private struct Metrics: Equatable {
        var top: CGFloat
        var bottomGap: CGFloat
        var contentHeight: CGFloat
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.rows) { row in
                    SpikeRowView(row: row, isExpanded: model.expanded.contains(row.id)) {
                        model.expanded.formSymmetricDifference([row.id])
                    }
                }
            }
            .scrollTargetLayout()
        }
        .defaultScrollAnchor(.bottom)
        .scrollPosition($position, anchor: .top)
        .onScrollPhaseChange { _, new in phase = new }
        .onScrollGeometryChange(for: Metrics.self) { geo in
            Metrics(
                top: geo.visibleRect.minY,
                bottomGap: geo.contentSize.height - geo.visibleRect.maxY,
                contentHeight: geo.contentSize.height)
        } action: { old, new in
            if !laidOut, new.contentHeight > 0 {
                laidOut = true
                onFirstLayout()
            }
            // "At bottom" only changes when the reader moves it. A content-height change while
            // idle keeps the earlier decision and re-pins after the layout that changed it.
            if phase.isScrolling || new.contentHeight == old.contentHeight {
                atBottom = new.bottomGap <= 8
            } else if atBottom, new.bottomGap > 0.5 {
                // The edge, not the last row's id: a row id makes the lazy stack estimate the
                // rows it has not measured and can land past the content.
                position.scrollTo(edge: .bottom)
            }
            if phase.isScrolling, new.top < 600, model.canLoadOlder {
                model.loadOlder()
            }
        }
    }
}
