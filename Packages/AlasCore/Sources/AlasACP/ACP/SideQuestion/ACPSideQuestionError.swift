import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public enum ACPSideQuestionError: LocalizedError, Equatable, Sendable {
    case notAccepted
    case unsafeMode
    case attachFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAccepted:
            "The side session couldn't accept the question."
        case .unsafeMode:
            "Couldn't switch the side session to a read-only mode, so the question wasn't sent."
        case .attachFailed(let reason):
            reason
        }
    }
}

/// Whether a side session's read-only mode holds. The permission gate only
/// sees calls an agent asks about, and agents run tools that the user's own
/// rules allow without asking. Claude's plan mode and Codex's read-only
/// sandbox hold regardless of those rules. Other agents (OpenCode, Pi,
/// Copilot, …) still get side questions, with the mode switch and the gate
/// applied where they can be, but the card says read-only isn't guaranteed.
public enum ACPSideQuestionSupportPolicy: Sendable {
    public static func enforcesReadOnly(agentId: String) -> Bool {
        ["claude", "codex"].contains(agentId)
    }
}

/// What a read-only `/btw` side session may run. Reads are allowed so the
/// side agent can look things up; `fetch` asks because it sends data off the
/// machine; anything else, including unknown kinds, is rejected.
public enum ACPSideQuestionPermissionRule: Sendable {
    public enum Decision: Equatable, Sendable { case allow, ask, reject }

    public static func decide(kind: String?) -> Decision {
        switch kind {
        case "read", "search", "think": .allow
        case "fetch": .ask
        default: .reject
        }
    }
}

/// The mode a side session switches to: plan when the agent has one,
/// otherwise away from modes that approve tool calls on their own. Works on
/// the mode chip's options, whether the agent backs them with
/// `session/set_mode` or a config option. Adapters that don't send
/// `_meta.kind` fall back to well-known mode ids; a current mode that stays
/// unclassified is not trusted.
public enum ACPSideQuestionModePolicy: Sendable {
    /// Nil when the current mode can stay.
    public static func preferredModeID(options: [ChipSpec.Item], currentID: String?) -> String? {
        if let plan = options.first(where: { kind(of: $0) == .plan }) {
            return plan.id == currentID ? nil : plan.id
        }
        guard !allows(options: options, currentID: currentID) else { return nil }
        return options.first { kind(of: $0) == .standard }?.id
    }

    /// Whether a config-option mode change took effect. An empty echo comes
    /// from adapters that don't return the refreshed options, and stands; a
    /// full one must show the target selected.
    public static func acceptsEcho(_ echoed: [ACPConfigOption], configID: String, target: String) -> Bool {
        guard !echoed.isEmpty else { return true }
        return echoed.first { $0.id == configID }?.currentValue == .string(target)
    }

    /// Whether a side session may ask its question in `currentID`.
    public static func allows(options: [ChipSpec.Item], currentID: String?) -> Bool {
        guard !options.isEmpty else { return true }
        guard let current = options.first(where: { $0.id == currentID }),
              let kind = kind(of: current)
        else { return false }
        // These run tool calls without asking, so the read-only permission
        // gate would never see them.
        return kind != .fullAccess && kind != .autoReview
    }

    package static func kind(of item: ChipSpec.Item) -> ACPModeKind? {
        item.kind ?? knownKinds[item.id]
    }

    /// Mode ids of Claude and Codex adapters that predate `_meta.kind`.
    private static let knownKinds: [String: ACPModeKind] = [
        "default": .standard,
        "read-only": .standard,
        "plan": .plan,
        "auto": .autoReview,
        "agent": .autoReview,
        "bypassPermissions": .fullAccess,
        "agent-full-access": .fullAccess,
    ]
}
