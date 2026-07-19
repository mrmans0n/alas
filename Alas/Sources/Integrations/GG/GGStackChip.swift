import SwiftUI

/// Presentation model for a stack entry's PR/MR chip. Pure so the
/// label/color mapping is unit-testable without rendering.
struct GGStackChipModel: Equatable {
    let label: String
    let colorToken: String

    static func model(for entry: GGStackEntry, kind: CodeHostKind?) -> GGStackChipModel? {
        guard let number = entry.prNumber else { return nil }
        let prefix = kind == .gitlab ? "!" : "#"
        let label = "\(prefix)\(number)" + (entry.approved ? " ✓" : "")
        let token: String
        switch entry.prState {
        case .open: token = "add"
        case .merged: token = "accent"
        case .draft: token = "fg-muted"
        case .closed: token = "del"
        case nil: token = "fg-faint"
        }
        return GGStackChipModel(label: label, colorToken: token)
    }
}

/// Capsule chip styled after `BehindChip` (CommitsSectionView.swift).
struct GGStackChip: View {
    let model: GGStackChipModel
    @Environment(\.theme) private var theme

    var body: some View {
        let tint = theme.color(model.colorToken)
        Text(model.label)
            .font(.system(size: 9.5, weight: .semibold))
            .lineLimit(1)
            .foregroundColor(tint)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(tint.opacity(0.12))
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
