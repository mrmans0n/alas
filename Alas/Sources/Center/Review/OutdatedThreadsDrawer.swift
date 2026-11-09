import SwiftUI

enum OutdatedThreadsDrawerPresentation {
    static let defaultMaxExpandedListHeight: CGFloat = 280

    static func expandedListMaxHeight(availableHeight: CGFloat) -> CGFloat {
        guard availableHeight.isFinite, availableHeight > 0 else {
            return defaultMaxExpandedListHeight
        }

        return min(defaultMaxExpandedListHeight, max(80, floor(availableHeight * 0.35)))
    }

    /// Height applied to the expanded list's ScrollView: shrink-wraps to the measured
    /// content when it's shorter than the cap, otherwise clamps to the cap so long lists
    /// stay within the drawer and scroll instead of overflowing past it.
    static func cappedListHeight(measuredContentHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        min(max(measuredContentHeight, 1), maxHeight)
    }
}

struct OutdatedThreadsDrawer: View {
    @Environment(\.designScale) private var scale
    let threads: [ReviewThread]  // already filtered: isFileLevel || isOutdated
    let maxExpandedListHeight: CGFloat
    @State private var isExpanded = false
    @State private var contentHeight: CGFloat = 0

    @Environment(\.theme) private var theme

    init(
        threads: [ReviewThread],
        maxExpandedListHeight: CGFloat = OutdatedThreadsDrawerPresentation.defaultMaxExpandedListHeight,
        initiallyExpanded: Bool = false
    ) {
        self.threads = threads
        self.maxExpandedListHeight = maxExpandedListHeight
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        if threads.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: scale.space[2]) {
                        Image(systemName: "chevron.right")
                            .font(scale.caption.font(weight: .semibold))
                            .foregroundColor(theme.color("fg-dim"))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.18), value: isExpanded)
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(scale.metaFont)
                            .foregroundColor(theme.color("fg-dim"))
                        Text("Outdated & file-level (\(threads.count))")
                            .font(scale.meta.font(weight: .medium))
                            .foregroundColor(theme.color("fg-dim"))
                        Spacer()
                    }
                    .padding(.horizontal, scale.space[4])
                    .padding(.vertical, scale.space[2])
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Divider().overlay(theme.color("line"))
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(threads) { thread in
                                OutdatedThreadRow(thread: thread)
                            }
                        }
                        .padding(.vertical, scale.space[1])
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            contentHeight = height
                        }
                    }
                    // Shrink-wrap short lists, but never exceed the cap — a plain
                    // .fixedSize(vertical: true) + .frame(maxHeight:) combo lets the
                    // ScrollView render at its full (uncapped) content height because
                    // fixedSize ignores the frame's proposal, so long lists overflowed
                    // past the drawer instead of clipping and scrolling.
                    .frame(
                        height: OutdatedThreadsDrawerPresentation.cappedListHeight(
                            measuredContentHeight: contentHeight,
                            maxHeight: maxExpandedListHeight
                        )
                    )
                    .clipped()
                }
            }
            .background(theme.color("bg-2"))
            .overlay(alignment: .bottom) {
                Divider().overlay(theme.color("line"))
            }
        }
    }
}

private struct OutdatedThreadRow: View {
    @Environment(\.designScale) private var scale
    let thread: ReviewThread
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space[1]) {
            HStack(spacing: scale.space[2]) {
                if thread.isOutdated {
                    Text("Outdated")
                        .font(scale.caption.font(weight: .semibold))
                        .foregroundColor(theme.color("fg-dim"))
                        .padding(.horizontal, scale.space[1])
                        .padding(.vertical, scale.space[0])
                        .background(theme.color("fg-dim").opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
                }
                if thread.isFileLevel {
                    Text("File-level")
                        .font(scale.caption.font(weight: .semibold))
                        .foregroundColor(theme.color("fg-dim"))
                        .padding(.horizontal, scale.space[1])
                        .padding(.vertical, scale.space[0])
                        .background(theme.color("fg-dim").opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
                }
                if let path = thread.path {
                    Text(path)
                        .font(scale.caption.font(weight: .regular, design: .monospaced))
                        .foregroundColor(theme.color("fg-dim"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if let url = thread.url {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(scale.caption.font(weight: .regular))
                            .foregroundColor(theme.color("fg-dim"))
                    }
                    .buttonStyle(.plain)
                    .help("Open in browser")
                }
            }
            if let hunk = thread.diffHunk {
                Text(hunk)
                    .font(scale.caption.font(weight: .regular, design: .monospaced))
                    .foregroundColor(theme.color("fg-muted"))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .padding(scale.space[2])
                    .background(theme.color("bg-3"))
                    .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
            }
            let body = thread.body
            if !body.isEmpty {
                if let author = thread.author {
                    Text(author)
                        .font(scale.caption.font(weight: .semibold))
                        .foregroundColor(theme.color("accent"))
                }
                DiffReviewInlineFeedbackMarkdown.view(body)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .frame(maxHeight: 72, alignment: .top)
                    .clipped()
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, scale.space[4])
        .padding(.vertical, scale.space[2])
        Divider().overlay(theme.color("line").opacity(0.5))
    }
}
