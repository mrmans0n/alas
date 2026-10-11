import Foundation

/// Presentation model for a stack entry's PR/MR chip. Pure so the
/// label/color mapping is unit-testable without rendering.
struct GGStackChipModel: Equatable {
    let label: String
    /// Whether the PR/MR is approved. Rendered as a ` ✓` suffix, but the
    /// compact (header) variant drops it to keep the chip short.
    let approved: Bool
    let colorToken: String
    /// Tooltip for the clickable chip, e.g. "Open PR #840" / "Open MR !840".
    let helpLabel: String

    static func model(for entry: GGStackEntry, kind: CodeHostKind?) -> GGStackChipModel? {
        guard let number = entry.prNumber else { return nil }
        let prefix = kind == .gitlab ? "!" : "#"
        let reference = "\(prefix)\(number)"
        let token: String
        switch entry.prState {
        case .open: token = "add"
        case .merged: token = "accent"
        case .draft: token = "fg-muted"
        case .closed: token = "del"
        case nil: token = "fg-faint"
        }
        return GGStackChipModel(
            label: reference,
            approved: entry.approved,
            colorToken: token,
            helpLabel: "Open \(kind?.reviewRequestLabel ?? "PR") \(reference)"
        )
    }
}
