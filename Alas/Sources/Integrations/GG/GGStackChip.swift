import SwiftUI

/// Presentation model for a stack entry's PR/MR chip. Pure so the
/// label/color mapping is unit-testable without rendering.
struct GGStackChipModel: Equatable {
    let label: String
    let colorToken: String
    /// Tooltip for the clickable chip, e.g. "Open PR #840" / "Open MR !840".
    let helpLabel: String

    static func model(for entry: GGStackEntry, kind: CodeHostKind?) -> GGStackChipModel? {
        guard let number = entry.prNumber else { return nil }
        let prefix = kind == .gitlab ? "!" : "#"
        let reference = "\(prefix)\(number)"
        let label = reference + (entry.approved ? " ✓" : "")
        let token: String
        switch entry.prState {
        case .open: token = "add"
        case .merged: token = "accent"
        case .draft: token = "fg-muted"
        case .closed: token = "del"
        case nil: token = "fg-faint"
        }
        return GGStackChipModel(
            label: label,
            colorToken: token,
            helpLabel: "Open \(kind?.reviewRequestLabel ?? "PR") \(reference)"
        )
    }
}

/// Capsule chip styled after `BehindChip` (CommitsSectionView.swift).
/// When `onTap` is set, the chip becomes a button with hover highlight.
struct GGStackChip: View {
    let model: GGStackChipModel
    var onTap: (() -> Void)? = nil
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
        return Text(model.label)
            .font(.system(size: 9.5, weight: .semibold))
            .lineLimit(1)
            .foregroundColor(tint)
            .padding(.horizontal, 6).padding(.vertical, 1)
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
            .frame(width: 6, height: 6)
    }
}
