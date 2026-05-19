import SwiftUI

/// Thin styled wrapper around SwiftUI's `Slider`. Keeps the look in line
/// with `AlasToggle` / `Seg` so the settings rows feel consistent.
struct AlasSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double? = nil
    @Environment(\.theme) var theme

    var body: some View {
        HStack(spacing: 10) {
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
            Text(percentLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.color("fg-muted"))
                .frame(width: 36, alignment: .trailing)
        }
        .frame(width: 240)
    }

    private var percentLabel: String {
        let lo = range.lowerBound
        let hi = range.upperBound
        let normalized = (value - lo) / max(hi - lo, .leastNonzeroMagnitude)
        return "\(Int((normalized * 100).rounded()))%"
    }
}
