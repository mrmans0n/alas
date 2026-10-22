import Foundation

public enum ComputerUsePermission: String, CaseIterable, Sendable {
    case screenRecording, accessibility

    public var displayName: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        }
    }

    public var settingsURL: URL {
        switch self {
        case .screenRecording:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
    }
}

public enum ComputerUseReadiness: Equatable, Sendable {
    case disabled
    case missingPermissions([ComputerUsePermission])
    case ready

    public static func evaluate(enabled: Bool, granted: Set<ComputerUsePermission>) -> ComputerUseReadiness {
        guard enabled else { return .disabled }
        let missing = ComputerUsePermission.allCases.filter { !granted.contains($0) }
        return missing.isEmpty ? .ready : .missingPermissions(missing)
    }

    /// The error an MCP tool returns instead of acting; nil when ready.
    public var toolError: String? {
        switch self {
        case .ready:
            return nil
        case .disabled:
            return "computer_disabled: Computer use is turned off. Ask the user to enable it in Alas Settings → Computer Use."
        case .missingPermissions(let missing):
            let names = missing.map(\.displayName).joined(separator: " and ")
            let noun = missing.count == 1 ? "permission" : "permissions"
            let pronoun = missing.count == 1 ? "it" : "them"
            return "computer_permissions: Alas is missing the macOS \(names) \(noun). Ask the user to grant \(pronoun) in Alas Settings → Computer Use."
        }
    }
}
