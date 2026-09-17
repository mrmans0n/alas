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
                .modifier(HarnessSessionBadgeChrome(surface: .init(state: session.state), isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }

    private var tooltip: String {
        "\(session.agent.displayName) · \(session.state == .running ? "running" : "waiting")"
    }
}

struct HarnessSessionOverflowBadge: View {
    let sessions: [HarnessService.WorktreeHarnessSession]
    let onActivate: (String) -> Void
    var isSelected = false

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
                .badge(session.state == .running ? "Running" : "Waiting")
            }
        } label: {
            Text("+\(sessions.count)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.color("fg-dim"))
                .frame(width: HarnessSessionBadge.diameter, height: HarnessSessionBadge.diameter)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: HarnessSessionBadge.diameter, height: HarnessSessionBadge.diameter)
        .modifier(HarnessSessionBadgeChrome(surface: .init(sessions: sessions), isSelected: isSelected))
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
    case mixed

    init(state: HarnessService.AggregatedState) {
        switch state {
        case .running: self = .running
        case .awaiting: self = .awaiting
        }
    }

    init(sessions: [HarnessService.WorktreeHarnessSession]) {
        let hasRunning = sessions.contains { $0.state == .running }
        let hasAwaiting = sessions.contains { $0.state == .awaiting }

        switch (hasRunning, hasAwaiting) {
        case (true, true): self = .mixed
        case (true, false): self = .running
        case (false, true), (false, false): self = .awaiting
        }
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
/// The surface is determined by the sessions it represents: a uniform state
/// uses that state's token, while mixed hidden sessions transition from running
/// green to waiting orange. The fixed lightness ramp keeps either surface
/// legible against the logo and both themes.
struct HarnessSessionBadgeChrome: ViewModifier {
    /// Lightness of the gradient's first stop, from E1's `.agent`.
    nonisolated static let surfaceTopLightness: Double = 0.58
    /// Lightness of the final stop.
    nonisolated static let surfaceBottomLightness: Double = 0.46

    let surface: HarnessSessionBadgeSurface
    var isSelected = false

    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: HarnessSessionBadge.cornerRadius)
                    .fill(background)
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

    private var background: LinearGradient {
        let gradientColors: [Color]
        switch surface {
        case .running:
            gradientColors = colors(for: "add")
        case .awaiting:
            gradientColors = colors(for: "caution")
        case .mixed:
            let stops = Self.mixedSurfaceRamp(
                running: theme.tokens["add"],
                awaiting: theme.tokens["caution"]
            )
            gradientColors = stops?.map { $0.toColor() } ?? [theme.color("add"), theme.color("caution")]
        }
        return LinearGradient(
            colors: gradientColors,
            // CSS measures gradient angles clockwise from "to top", so E1's
            // 160deg runs top-slightly-left to bottom-slightly-right.
            startPoint: UnitPoint(x: 0.33, y: 0),
            endPoint: UnitPoint(x: 0.67, y: 1)
        )
    }

    private func colors(for token: String) -> [Color] {
        let stops = Self.surfaceRamp(from: theme.tokens[token])
        return stops?.map { $0.toColor() } ?? [theme.color(token), theme.color(token)]
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

    /// Builds a mixed-state surface from the bright running stop through the
    /// darker waiting stop, retaining each token's hue and chroma.
    nonisolated static func mixedSurfaceRamp(running: String?, awaiting: String?) -> [OKLCH]? {
        guard
            let runningStops = surfaceRamp(from: running),
            let awaitingStops = surfaceRamp(from: awaiting)
        else {
            return nil
        }
        return [runningStops[0], awaitingStops[1]]
    }
}
