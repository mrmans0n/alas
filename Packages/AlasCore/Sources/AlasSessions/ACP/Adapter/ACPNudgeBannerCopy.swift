import Foundation
import AlasACP

public enum ACPSetupNudgeMode: Equatable, Sendable {
    case install
    case update(current: String, latest: String)
    /// Update for an agent CLI Alas detected but did not install; `manager`
    /// names the package manager that runs the upgrade.
    case agentUpdate(current: String, latest: String, manager: String)
}

/// Kept out of the SwiftUI view so tests and Remote can use it without one.
public enum ACPSetupNudgeBannerCopy: Sendable {
    public static func idleMessage(
        mode: ACPSetupNudgeMode,
        agentDisplayName: String,
        targetHost: String? = nil
    ) -> String {
        let target = targetHost.map { " on \($0)" } ?? ""
        switch mode {
        case .install:
            return "\(agentDisplayName) requires the ACP adapter to be installed\(target)."
        case .update(let current, let latest):
            return "\(agentDisplayName) adapter update\(target) available (\(current) → \(latest))."
        case .agentUpdate(let current, let latest, let manager):
            return "\(agentDisplayName) update available (\(current) → \(latest)) via \(manager)."
        }
    }

    public static func installedMessage(
        mode: ACPSetupNudgeMode,
        agentDisplayName: String,
        targetHost: String? = nil
    ) -> String {
        let target = targetHost.map { " on \($0)" } ?? ""
        switch mode {
        case .install:
            return "\(agentDisplayName) adapter installed\(target) — connecting…"
        case .update:
            return "\(agentDisplayName) adapter updated\(target) — reconnecting…"
        case .agentUpdate:
            return "\(agentDisplayName) updated — reconnecting…"
        }
    }

    public static func installingMessage(
        mode: ACPSetupNudgeMode,
        agentDisplayName: String,
        targetHost: String? = nil
    ) -> String {
        let target = targetHost.map { " on \($0)" } ?? ""
        switch mode {
        case .install: return "Installing \(agentDisplayName) adapter\(target)…"
        case .update:  return "Updating \(agentDisplayName) adapter\(target)…"
        case .agentUpdate(_, _, let manager): return "Updating \(agentDisplayName) with \(manager)…"
        }
    }

    public static func errorMessage(mode: ACPSetupNudgeMode, detail: String) -> String {
        switch mode {
        case .install: return "Install failed: \(detail)"
        case .update, .agentUpdate: return "Update failed: \(detail)"
        }
    }

    public static func installButtonTitle(mode: ACPSetupNudgeMode, errored: Bool) -> String {
        if errored { return "Retry" }
        switch mode {
        case .install: return "Install"
        case .update, .agentUpdate: return "Update"
        }
    }
}

public enum ACPAuthNudgeBannerCopy: Sendable {
    public static func message(agentDisplayName: String, reason: String?) -> String {
        let base = "\(agentDisplayName) needs sign-in before it can continue."
        guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty
        else { return base }
        return "\(base) \(reason)"
    }

    public static func unsupportedMessage(agentDisplayName: String) -> String {
        "\(agentDisplayName) requires environment credentials or agent sign-in, and sign-in is not supported yet. Add credentials outside Alas, then reconnect."
    }

    public static func buttonTitle(method: ACPInitializeResult.ACPAuthMethod) -> String {
        if let label = method.terminalAuth?.label?.trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            return label
        }
        let name = method.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Sign In" : name
    }
}
