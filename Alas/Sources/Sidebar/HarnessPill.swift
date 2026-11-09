import SwiftUI

/// Sidebar badge for harness activity.
/// - `.full` renders a pill `[• run]` / `[• wait]` for worktree rows.
/// - `.dotOnly` renders a bare colored dot for collapsed repo headers.
struct HarnessPill: View {
    enum Variant { case full, dotOnly }

    let summary: HarnessService.WorktreeHarnessSummary
    let variant: Variant
    let tooltip: String
    var isSelected: Bool = false

    @Environment(\.theme) var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        switch variant {
        case .full:
            let background = isSelected ? theme.color("bg-3") : theme.color("bg-4")
            HStack(spacing: 4) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 5, height: 5)
                Text(label)
                    .font(scale.captionFont)
                    .foregroundColor(theme.color("fg-dim"))
            }
            .padding(.horizontal, scale.space[1])
            .padding(.vertical, scale.space[0])
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
            .help(tooltip)

        case .dotOnly:
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .help(tooltip)
        }
    }

    private var dotColor: Color {
        switch summary.state {
        case .running:  return theme.color("add")
        case .awaiting: return theme.color("mod")
        case .limited:  return theme.color("warn")
        case .failed:   return theme.color("del")
        }
    }

    private var label: String {
        switch summary.state {
        case .running:  return "run"
        case .awaiting: return "wait"
        case .limited:  return "limit"
        case .failed:   return "fail"
        }
    }
}

struct HarnessSessionBadge: View {
    /// The badge's frame. `WorktreeRowView` sizes its "+N" overflow control
    /// to match so the badge group stays on one baseline; the tile inside is
    /// inset by `HarnessSessionBadgeChrome.tileInset`.
    static let diameter: CGFloat = 17
    static let logoSize: CGFloat = 10
    static let cornerRadius: CGFloat = 4

    let session: HarnessService.WorktreeHarnessSession
    let onActivate: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onActivate) {
            Image(session.agent.logoAssetName)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: Self.logoSize, height: Self.logoSize)
                .frame(width: Self.diameter, height: Self.diameter)
                .modifier(HarnessSessionBadgeChrome(surface: .init(state: session.state)))
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(tooltip)
        // Dropped on an agent composer, attaches the session as context.
        .draggable(Self.dragURL(sessionId: session.id))
    }

    nonisolated static func dragURL(sessionId: String) -> URL {
        // The id is percent-encoded into the host, so the string always parses.
        URL(string: ACPSessionReference.uri(sessionId: sessionId))!
    }

    private var tooltip: String {
        "\(session.agent.displayName) · \(session.state.statusNote)"
    }
}

struct HarnessSessionOverflowBadge: View {
    let sessions: [HarnessService.WorktreeHarnessSession]
    let onActivate: (String) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Menu {
            ForEach(sessions) { session in
                Button {
                    onActivate(session.id)
                } label: {
                    Label {
                        Text(session.agent.displayName)
                    } icon: {
                        Image(nsImage: AgentLogoView.menuImage(for: session.agent, size: 14))
                    }
                }
                .badge(session.state.statusNote.capitalized)
            }
        } label: {
            Text("+\(sessions.count)")
                .font(.system(size: 9, weight: .medium)) // design-literal: "+N" has to fit the 17pt agent tile
                .monospacedDigit()
                .foregroundStyle(theme.color("fg-dim"))
                .frame(width: HarnessSessionBadge.diameter, height: HarnessSessionBadge.diameter)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: HarnessSessionBadge.diameter, height: HarnessSessionBadge.diameter)
        .modifier(HarnessSessionBadgeChrome(surface: .init(sessions: sessions)))
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        "\(sessions.count) more active session\(sessions.count == 1 ? "" : "s")"
    }
}

enum HarnessSessionBadgeSurface: Equatable {
    case running
    case awaiting
    case limited
    case failed
    case mixed

    init(state: HarnessService.AggregatedState) {
        switch state {
        case .running: self = .running
        case .awaiting: self = .awaiting
        case .limited: self = .limited
        case .failed: self = .failed
        }
    }

    /// A mix of running and waiting shows the wait: that is the one to act on.
    var colorToken: String {
        switch self {
        case .running: "add"
        case .awaiting, .mixed: "caution"
        case .limited: "warn"
        case .failed: "del"
        }
    }

    init(sessions: [HarnessService.WorktreeHarnessSession]) {
        if let first = sessions.first, sessions.allSatisfy({ $0.state == first.state }) {
            self.init(state: first.state)
            return
        }
        let hasRunning = sessions.contains { $0.state == .running }
        let hasAwaiting = sessions.contains { $0.state == .awaiting }

        switch (hasRunning, hasAwaiting) {
        case (true, true): self = .mixed
        case (true, false): self = .running
        case (false, true): self = .awaiting
        case (false, false):
            // Only stopped sessions remain; a failure is the one to act on.
            self = sessions.contains { $0.state == .failed } ? .failed : .awaiting
        }
    }
}

/// The agent tile: one flat fill in the state's hue, inset inside the badge's
/// frame so it stays clear of a selected row's edge. No gradient, edge
/// highlight or shadow, so it reads with the sidebar's flat icons. The fill
/// stays opaque and mid-lightness because vendor logos are drawn in their own
/// colors, some black, and need a surface that holds them in both themes.
struct HarnessSessionBadgeChrome: ViewModifier {
    /// Lightness of the fill, the middle of E1's old gradient.
    nonisolated static let surfaceLightness: Double = 0.52
    /// Between the tile and the badge's frame.
    nonisolated static let tileInset: CGFloat = 1.5

    let surface: HarnessSessionBadgeSurface

    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: HarnessSessionBadge.cornerRadius)
                    .fill(fill)
                    .padding(Self.tileInset)
            )
    }

    private var fill: Color {
        Self.surfaceColor(from: theme.tokens[surface.colorToken])?.toColor() ?? theme.color(surface.colorToken)
    }

    /// The token's hue and chroma at `surfaceLightness`, opaque. Nil when the
    /// token is missing or unparseable — `Theme.fallback` ships no tokens — so
    /// the caller falls back to the token's own color.
    nonisolated static func surfaceColor(from raw: String?) -> OKLCH? {
        guard let raw, let base = try? OKLCH.parse(raw) else { return nil }
        return OKLCH(l: surfaceLightness, c: base.c, h: base.h, a: 1)
    }
}
