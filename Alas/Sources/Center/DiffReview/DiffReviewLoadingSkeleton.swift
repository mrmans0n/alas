import SwiftUI

/// Stands in for the review surface until its file list is known: a rail of
/// file rows and a couple of diff cards, in the surface's own layout.
struct DiffReviewLoadingSkeleton: View {
    @Environment(\.designScale) private var scale
    var railCollapsed = false

    @Environment(\.theme) private var theme

    private static let railRowWidths: [CGFloat] = [150, 110, 170, 96, 132, 118, 84]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: scale.space[3]) {
                if !railCollapsed {
                    ForEach(Array(Self.railRowWidths.enumerated()), id: \.offset) { _, width in
                        DiffReviewSkeletonBar(width: width)
                    }
                }
            }
            .padding(.horizontal, scale.space[4])
            .padding(.vertical, scale.space[4])
            .frame(
                width: railCollapsed ? DiffReviewRailMetrics.collapsedWidth : DiffReviewRailMetrics.expandedWidth,
                alignment: .topLeading
            )
            .frame(maxHeight: .infinity, alignment: .top)
            .overlay(Rectangle().fill(theme.color("line")).frame(width: 0.5), alignment: .trailing)

            VStack(spacing: scale.space[4]) {
                DiffReviewSkeletonCard(lineWidths: [0.62, 0.48, 0.71, 0.4, 0.55, 0.66])
                DiffReviewSkeletonCard(lineWidths: [0.5, 0.68, 0.36, 0.59])
                Spacer(minLength: 0)
            }
            .padding(scale.space[4])
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("bg-1"))
        .diffReviewSkeletonPulse()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading review")
    }
}

/// The diff body of a file whose diff is still loading.
struct DiffReviewSkeletonLines: View {
    @Environment(\.designScale) private var scale
    let lineWidths: [CGFloat]

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: scale.space[2]) {
                ForEach(Array(lineWidths.enumerated()), id: \.offset) { _, fraction in
                    DiffReviewSkeletonBar(width: max(40, proxy.size.width * fraction))
                }
            }
        }
        .diffReviewSkeletonPulse()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading diff")
    }
}

private struct DiffReviewSkeletonCard: View {
    @Environment(\.designScale) private var scale
    let lineWidths: [CGFloat]

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: scale.space[2]) {
                DiffReviewSkeletonBar(width: 180)
                Spacer(minLength: 0)
                DiffReviewSkeletonBar(width: 48)
            }
            .padding(.horizontal, scale.space[3])
            .frame(height: 40)
            .background(theme.color("bg-2"))
            Rectangle().fill(theme.color("line")).frame(height: 0.5)
            DiffReviewSkeletonLines(lineWidths: lineWidths)
                .frame(height: CGFloat(lineWidths.count) * 19)
                .padding(scale.space[3])
        }
        .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
        .overlay(RoundedRectangle(cornerRadius: scale.radius.medium).stroke(theme.color("line"), lineWidth: 0.5))
    }
}

private struct DiffReviewSkeletonBar: View {
    @Environment(\.designScale) private var scale
    let width: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: scale.radius.small)
            .fill(theme.color("fg-dim").opacity(0.16))
            .frame(width: width, height: 10)
    }
}

private struct DiffReviewSkeletonPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.55 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}

private extension View {
    func diffReviewSkeletonPulse() -> some View {
        modifier(DiffReviewSkeletonPulse())
    }
}
