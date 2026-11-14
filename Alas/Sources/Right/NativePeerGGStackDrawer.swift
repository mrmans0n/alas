import SwiftUI

/// A host worktree's gg stack, read-only: the host's settings make it a
/// stack, and its gg actions run only on the host.
struct NativePeerGGStackDrawer: View {
    let read: HostGGStackRead
    let isRefreshing: Bool
    let onRefresh: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    private var layout: PaneDrawerLayout { PaneDrawerLayout(expanded: expanded) }

    var body: some View {
        VStack(spacing: 0) {
            collapsedRow
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(PaneDrawerLayout.animation(reduceMotion: reduceMotion)) { expanded.toggle() }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isButton)
            if expanded { expandedBody.transition(.paneDrawerBody) }
        }
        .paneDrawer(layout, fill: theme.color("section-head-bg"), hairline: theme.color("line"))
    }

    private var title: String { read.stack.map { "Stack \($0.name)" } ?? "gg stack" }

    private var summaryChip: String {
        guard let stack = read.stack else { return "unavailable" }
        let summary = stack.summary
        return "\(summary.merged)/\(summary.total) merged"
    }

    private var collapsedRow: some View {
        PaneDrawerRow(
            leading: {
                Circle().fill(theme.color(read.problem == nil ? "accent" : "warn")).frame(width: 6, height: 6)
                Icon(name: "branch", size: 11, color: theme.color("fg-faint"))
            },
            identity: {
                Text(title.uppercased())
                    .font(scale.caption.font(weight: .semibold)).tracking(0.5)
                    .foregroundColor(theme.color("fg-muted")).lineLimit(1).truncationMode(.middle)
                    .help(title)
            },
            chips: { _ in
                Text(summaryChip)
                    .font(scale.meta.font(weight: .medium)).foregroundColor(theme.color("fg-dim"))
                    .lineLimit(1)
            },
            trailing: {
                if isRefreshing {
                    Spinner(lineWidth: 1.4, duration: 0.8).frame(width: 11, height: 11)
                } else {
                    Button(action: onRefresh) {
                        Icon(name: "arrow.clockwise", size: 10, color: theme.color("fg-faint"))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("Refresh stack and PR status")
                }
                Icon(name: "chev-right", size: 10, color: theme.color("fg-faint"))
                    .rotationEffect(layout.chevronAngle)
            }
        )
        .padding(.horizontal, layout.innerHorizontal(scale.space[3])).padding(.vertical, scale.space[2])
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: scale.space[1]) {
            if let problem = read.problem {
                Text(problem)
                    .font(scale.meta.font).foregroundStyle(theme.color("warn"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let stack = read.stack {
                if let behind = stack.behindBase, behind > 0 {
                    Text("\(behind) behind \(stack.base)")
                        .font(scale.meta.font).foregroundColor(theme.color("fg-dim"))
                }
                ForEach(stack.entries) { entry in
                    HStack(spacing: scale.space[2]) {
                        Text("\(entry.position)")
                            .font(scale.meta.font(design: .monospaced)).foregroundColor(theme.color("fg-faint"))
                        Text(entry.title)
                            .font(scale.meta.font(weight: entry.isCurrent ? .semibold : .regular))
                            .foregroundColor(theme.color("fg"))
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: scale.space[2])
                        if let status = Self.status(of: entry) {
                            Text(status)
                                .font(scale.meta.font).foregroundColor(theme.color("fg-dim"))
                                .lineLimit(1)
                        }
                    }
                    .help(entry.title)
                }
                Text("Sync, land and reorder this stack on the host.")
                    .font(scale.meta.font).foregroundColor(theme.color("fg-faint"))
            }
        }
        .padding(.horizontal, layout.innerHorizontal(scale.space[3])).padding(.bottom, scale.space[3])
    }

    /// "#7 merged · CI success · approved", or nil for an entry with no request.
    static func status(of entry: GGStackEntry) -> String? {
        guard let number = entry.prNumber else { return nil }
        var parts = ["#\(number)" + (entry.prState.map { " \($0.rawValue)" } ?? "")]
        if let ci = entry.ciStatus, ci != .unknown { parts.append("CI \(ci.rawValue)") }
        if entry.approved { parts.append("approved") }
        return parts.joined(separator: " · ")
    }
}
