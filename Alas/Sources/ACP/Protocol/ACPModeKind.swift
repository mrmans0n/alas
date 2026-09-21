import Foundation

/// Adapter-classified mode kind carried in `_meta.kind` on `ACPModeInfo`
/// (`availableModes[]`) and `ACPConfigOptionItem` (the `mode` config
/// option's `options[]`) — claude-agent-acp ≥ 0.71 via #1025, codex-acp
/// ≥ 1.7 via #430. Gives the mode chip a consistent icon/tint across
/// agents instead of the generic look, and flags `fullAccess` so the UI
/// can warn before the agent runs unsupervised.
///
/// | kind | Claude | Codex |
/// |---|---|---|
/// | `standard` | default ("Manual"), acceptEdits | read-only ("Ask for approval") |
/// | `plan` | plan | collaboration_mode `plan` |
/// | `autoReview` | auto | agent ("Approve for me") |
/// | `fullAccess` | bypassPermissions | agent-full-access ("Full access") |
enum ACPModeKind: String, Equatable, Hashable, Sendable {
    case standard
    case plan
    case autoReview = "auto_review"
    case fullAccess = "full_access"

    /// SF Symbol for the mode chip. `fullAccess` gets a warning glyph so a
    /// bypass-permissions / full-access mode reads as risky at a glance.
    var iconSystemName: String {
        switch self {
        case .standard: return "checkmark.shield"
        case .plan: return "list.bullet.clipboard"
        case .autoReview: return "wand.and.stars"
        case .fullAccess: return "exclamationmark.triangle.fill"
        }
    }
}

/// Wire shape for the `_meta` object carrying a mode/option kind. Unknown
/// or absent kinds decode to `nil` on the caller side (via
/// `ACPModeKind(rawValue:)`) so the chip keeps its generic look rather than
/// failing to decode the whole mode/option.
struct ACPModeKindMetadata: Decodable {
    let kind: String?
}
