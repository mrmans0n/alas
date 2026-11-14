import SwiftUI

/// What a Mac has running on a host worktree's gg stack.
enum NativePeerGGStackOperation: Equatable {
    case action(HostGGStackAction)
    /// Landing up to and including the entry with this id.
    case land(String)
    case reorder
}

/// A host worktree's gg stack, by the host's settings, with the actions the
/// host runs on it.
struct NativePeerGGStackDrawer: View {
    let read: HostGGStackRead
    let isRefreshing: Bool
    let onRefresh: () -> Void
    /// What the host offers now; empty from a host that runs none.
    var actions: [HostGGStackAction] = []
    var running: NativePeerGGStackOperation?
    var onAction: (HostGGStackAction) -> Void = { _ in }
    /// Nil from a host that neither lands nor reorders.
    var onLand: ((GGStackEntry) -> Void)?
    var onReorder: (() -> Void)?

    private var isPaused: Bool { read.isPaused == true }

    /// The actions a host runs on `read`: Continue and Abort while an
    /// operation is paused, else Sync, and Rebase when behind its base.
    static func offeredActions(for read: HostGGStackRead) -> [HostGGStackAction] {
        if read.isPaused == true { return [.continueOperation, .abortOperation] }
        guard let stack = read.stack else { return [] }
        return (stack.behindBase ?? 0) > 0 ? [.sync, .rebase] : [.sync]
    }

    /// Entries a land can stop at now: open, and it and everything below it
    /// approved and green, so the host merges at once instead of waiting.
    static func landableEntries(in read: HostGGStackRead) -> [GGStackEntry] {
        guard read.isPaused != true, let stack = read.stack else { return [] }
        return stack.entries.filter {
            $0.prState != .merged && GGLandReadiness.canStartLand(target: $0, in: stack, canWaitForReadiness: false)
        }
    }

    static func title(of action: HostGGStackAction) -> String {
        switch action {
        case .sync: "Sync"
        case .rebase: "Rebase"
        case .continueOperation: "Continue"
        case .abortOperation: "Abort"
        }
    }

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
        if isPaused { return "paused" }
        guard let stack = read.stack else { return "unavailable" }
        let summary = stack.summary
        return "\(summary.merged)/\(summary.total) merged"
    }

    private var collapsedRow: some View {
        PaneDrawerRow(
            leading: {
                Circle().fill(theme.color(read.problem == nil && !isPaused ? "accent" : "warn")).frame(width: 6, height: 6)
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
            if isPaused {
                Text("A gg operation is paused on conflicts. Resolve them in the changes list, then Continue, or Abort to roll back.")
                    .font(scale.meta.font).foregroundColor(theme.color("fg-dim"))
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                let landable = onLand == nil ? [] : Self.landableEntries(in: read).map(\.id)
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
                        if running == .land(entry.id) {
                            Spinner(lineWidth: 1.4, duration: 0.8).frame(width: 10, height: 10)
                        } else if landable.contains(entry.id), let onLand {
                            Button("Land") { onLand(entry) }
                                .buttonStyle(.bordered).controlSize(.mini)
                                .disabled(running != nil)
                                .help("Merge this pull request and every one below it")
                        }
                    }
                    .help(entry.title)
                }
            }
            let reorders = onReorder != nil && read.isPaused != true && (read.stack.map { $0.entries.count > 1 } ?? false)
            if !actions.isEmpty || reorders {
                HStack(spacing: scale.space[2]) {
                    ForEach(actions, id: \.self) { action in
                        Button {
                            onAction(action)
                        } label: {
                            HStack(spacing: scale.space[1]) {
                                if running == .action(action) { Spinner(lineWidth: 1.4, duration: 0.8).frame(width: 10, height: 10) }
                                Text(Self.title(of: action))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(running != nil)
                    }
                    if reorders, let onReorder {
                        Button {
                            onReorder()
                        } label: {
                            HStack(spacing: scale.space[1]) {
                                if running == .reorder { Spinner(lineWidth: 1.4, duration: 0.8).frame(width: 10, height: 10) }
                                Text("Reorder\u{2026}")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(running != nil)
                    }
                }
                .padding(.top, scale.space[1])
            }
            if onLand == nil {
                Text("Land and reorder this stack on the host.")
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
