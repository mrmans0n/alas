import SwiftUI

/// Glyph + label capsule shared by the editor badge and toolbar chips.
struct LSPStatusPill: View {
    let glyph: LSPPillGlyph
    let label: String
    let showsWarning: Bool
    var isHighlighted = false

    @Environment(\.theme) private var theme

    init(glyph: LSPPillGlyph, label: String, showsWarning: Bool, isHighlighted: Bool = false) {
        self.glyph = glyph
        self.label = label
        self.showsWarning = showsWarning
        self.isHighlighted = isHighlighted
    }

    init(state: LSPBadgeState, isHighlighted: Bool = false) {
        self.init(glyph: state.glyph, label: state.label, showsWarning: state.isProblem, isHighlighted: isHighlighted)
    }

    var body: some View {
        HStack(spacing: 6) {
            glyphView
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.color("fg-muted"))
            if showsWarning {
                Text("!")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.color("warn"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(theme.color("bg-2").opacity(isHighlighted ? 1 : 0))
        .clipShape(Capsule())
        .contentShape(Capsule())
    }

    @ViewBuilder
    private var glyphView: some View {
        switch glyph {
        case .ready:
            Circle().fill(theme.color("add")).frame(width: 7, height: 7).accessibilityHidden(true)
        case .loading:
            Spinner(lineWidth: 1.5, duration: 0.7).frame(width: 9, height: 9).accessibilityHidden(true)
        case .problem:
            Circle().fill(theme.color("warn")).frame(width: 7, height: 7).accessibilityHidden(true)
        case .none:
            Circle().stroke(theme.color("fg-faint"), lineWidth: 1).frame(width: 7, height: 7).accessibilityHidden(true)
        }
    }
}
