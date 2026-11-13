import SwiftUI

/// Candidate B: a SwiftUI ScrollView over a LazyVStack.
struct LazyStackTranscriptView: View {
    let model: SpikeTranscriptModel
    let onFirstLayout: () -> Void

    /// Tracks the top visible row id, which keeps that row in place when older rows are prepended.
    @State private var position = ScrollPosition(idType: String.self)
    @State private var phase = ScrollPhase.idle
    @State private var laidOut = false

    init(model: SpikeTranscriptModel, onFirstLayout: @escaping () -> Void) {
        self.model = model
        self.onFirstLayout = onFirstLayout
    }

    private struct Metrics: Equatable {
        var top: CGFloat
        var bottom: CGFloat
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
        .background(Color(.systemBackground))
        .defaultScrollAnchor(.bottom)
        // Tail-follow is the scroll view's own: while the reader is at the bottom, growth keeps
        // the bottom edge in place. No manual scrollTo competes with it.
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollPosition($position, anchor: .top)
        .onScrollPhaseChange { _, new in phase = new }
        .onScrollGeometryChange(for: Metrics.self) { geo in
            Metrics(top: geo.visibleRect.minY, bottom: geo.visibleRect.maxY, contentHeight: geo.contentSize.height)
        } action: { _, new in
            // Like A, "laid out" means the bottom of the transcript is on screen, not merely that
            // some content has a height.
            if !laidOut, new.contentHeight > 0, new.bottom >= new.contentHeight - 1 {
                laidOut = true
                onFirstLayout()
            }
            // Only the reader's own scrolling pages; a programmatic scroll (status-bar
            // scroll-to-top is `.animating`) does not.
            if phase == .interacting || phase == .decelerating, new.top < 600, model.canLoadOlder {
                model.loadOlder()
            }
        }
    }
}
