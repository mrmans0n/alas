import SwiftUI

/// Capsule chip styled after `BehindChip` (CommitsSectionView.swift).
/// When `onTap` is set, the chip becomes a button with hover highlight.
struct GGStackChip: View {
    let model: GGStackChipModel
    var onTap: (() -> Void)? = nil
    /// Header-sized variant: matches the section count pill's height so the
    /// Commits header stays as tall as Stashes/Working tree.
    var compact: Bool = false
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        if let onTap {
            Button(action: onTap) {
                chipBody(backgroundOpacity: hovering ? 0.22 : 0.12)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .onHover { hovering = $0 }
            .help(model.helpLabel)
        } else {
            chipBody(backgroundOpacity: 0.12)
        }
    }

    private func chipBody(backgroundOpacity: Double) -> some View {
        let tint = theme.color(model.colorToken)
        // The compact (header) variant drops the approval checkmark so the
        // chip stays short next to the behind-count chips.
        return Text(model.approved && !compact ? model.label + " ✓" : model.label)
            .font(.system(size: compact ? 9.5 : 10.5, weight: .semibold))
            .lineLimit(1)
            // Take the width the text needs; the header title side yields.
            .fixedSize()
            .foregroundColor(tint)
            .padding(.horizontal, compact ? 6 : 7)
            .padding(.vertical, compact ? 1 : 2)
            .background(tint.opacity(backgroundOpacity))
            .clipShape(Capsule())
    }
}

/// Tiny CI state dot shown next to the chip.
struct GGCIDot: View {
    let status: GGCIStatus?
    @Environment(\.theme) private var theme

    private var token: String {
        switch status {
        case .success: return "add"
        case .failed: return "del"
        case .pending, .running: return "caution"
        case .canceled, .unknown, nil: return "fg-faint"
        }
    }

    var body: some View {
        Circle()
            .fill(theme.color(token))
            .frame(width: 7, height: 7)
    }
}
