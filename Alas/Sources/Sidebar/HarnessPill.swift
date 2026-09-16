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

    var body: some View {
        switch variant {
        case .full:
            let background = isSelected ? theme.color("bg-3") : theme.color("bg-4")
            HStack(spacing: 4) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 5, height: 5)
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.color("fg-dim"))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 4))
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
        }
    }

    private var label: String {
        switch summary.state {
        case .running:  return "run"
        case .awaiting: return "wait"
        }
    }
}

struct HarnessSessionBadge: View {
    /// E1's agent tile size. `WorktreeRowView` sizes its "+N" overflow
    /// control to match so the badge group stays on one baseline.
    static let diameter: CGFloat = 17
    static let logoSize: CGFloat = 12
    static let cornerRadius: CGFloat = 5.5

    let session: HarnessService.WorktreeHarnessSession
    let onActivate: () -> Void
    var isSelected = false

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onActivate) {
            Image(session.agent.logoAssetName)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: Self.logoSize, height: Self.logoSize)
                .frame(width: Self.diameter, height: Self.diameter)
                .modifier(HarnessSessionBadgeChrome(state: session.state, isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }

    private var tooltip: String {
        "\(session.agent.displayName) · \(session.state == .running ? "running" : "waiting")"
    }
}

/// E1's agent tile surface: a filled gradient chip with a hairline of light
/// along its edge, lifted off the row by a soft drop shadow.
///
/// ```css
/// background: linear-gradient(160deg, oklch(0.58 0.13 158), oklch(0.46 0.12 162));
/// box-shadow: inset 0 0 0 0.5px oklch(1 0 0/0.22), 0 1px 3px rgba(0,0,0,0.35);
/// ```
///
/// The hue and chroma come from the state's theme token so running and awaiting
/// stay distinguishable and both themes are honoured; only the lightness ramp is
/// taken from E1, because the tile is a solid surface rather than a tint of the
/// row behind it and so needs its own fixed contrast against the logo.
struct HarnessSessionBadgeChrome: ViewModifier {
    /// Lightness of the gradient's first stop, from E1's `.agent`.
    nonisolated static let surfaceTopLightness: Double = 0.58
    /// Lightness of the final stop.
    nonisolated static let surfaceBottomLightness: Double = 0.46

    let state: HarnessService.AggregatedState
    var isSelected = false

    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: HarnessSessionBadge.cornerRadius)
                    .fill(surface)
            )
            // E1's `inset 0 0 0 0.5px oklch(1 0 0/0.22)`. `strokeBorder` draws
            // inside the shape's bounds, which is what makes it read as an edge
            // highlight on the tile rather than a ring around it.
            .overlay(
                RoundedRectangle(cornerRadius: HarnessSessionBadge.cornerRadius)
                    .strokeBorder(.white.opacity(isSelected ? 0.30 : 0.22), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
    }

    /// Token carrying the hue for each state.
    private var token: String {
        switch state {
        case .running:  return "add"
        case .awaiting: return "caution"
        }
    }

    private var surface: LinearGradient {
        let stops = Self.surfaceRamp(from: theme.tokens[token])
        let colors = stops?.map { $0.toColor() } ?? [theme.color(token), theme.color(token)]
        return LinearGradient(
            colors: colors,
            // CSS measures gradient angles clockwise from "to top", so E1's
            // 160deg runs top-slightly-left to bottom-slightly-right.
            startPoint: UnitPoint(x: 0.33, y: 0),
            endPoint: UnitPoint(x: 0.67, y: 1)
        )
    }

    /// Builds E1's two gradient stops from a raw OKLCH token, keeping the
    /// token's hue and chroma and substituting E1's lightness ramp.
    ///
    /// Returns nil when the token is missing or unparseable — `Theme.fallback`
    /// ships no tokens at all — so the caller can fall back to a flat fill
    /// rather than rendering the pink sentinel as a gradient.
    nonisolated static func surfaceRamp(from raw: String?) -> [OKLCH]? {
        guard let raw, let base = try? OKLCH.parse(raw) else { return nil }
        return [
            OKLCH(l: surfaceTopLightness, c: base.c, h: base.h, a: 1),
            OKLCH(l: surfaceBottomLightness, c: base.c, h: base.h, a: 1)
        ]
    }
}
