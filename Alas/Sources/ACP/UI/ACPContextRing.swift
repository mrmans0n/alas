import SwiftUI

/// Fraction of the context window in use, clamped to `0...1`. Guards
/// divide-by-zero: a non-positive `size` yields `0`.
func contextRatio(used: Int, size: Int) -> Double {
    guard size > 0 else { return 0 }
    return min(max(Double(used) / Double(size), 0), 1)
}

/// Severity of context usage, driving the ring/bar color.
enum ContextRingLevel {
    case neutral, warning, critical

    init(ratio: Double) {
        if ratio >= 0.95 { self = .critical }
        else if ratio >= 0.80 { self = .warning }
        else { self = .neutral }
    }

    /// Theme token for this level.
    var token: String {
        switch self {
        case .neutral:  return "accent"
        case .warning:  return "warn"
        case .critical: return "del"
        }
    }
}

/// Compact token count, e.g. `53000 -> "53.0k"`, `1_200_000 -> "1.2M"`.
func formatContextTokens(_ n: Int) -> String {
    let v = max(0, n)
    if v >= 1_000_000 { return String(format: "%.1fM", Double(v) / 1_000_000) }
    if v >= 1_000 { return String(format: "%.1fk", Double(v) / 1_000) }
    return "\(v)"
}

/// Whole-percent for display, e.g. `0.265 -> 27`.
func contextPercent(ratio: Double) -> Int { Int((ratio * 100).rounded()) }

/// Thin progress ring. `ratio` is expected pre-clamped (see `contextRatio`).
struct ACPContextRing: View {
    let ratio: Double
    var diameter: CGFloat = 16
    var lineWidth: CGFloat = 2.5

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Circle()
                .stroke(theme.color("line"), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, ratio))
                .stroke(theme.color(ContextRingLevel(ratio: ratio).token),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
        .animation(.easeOut(duration: 0.25), value: ratio)
    }
}
