import Foundation

/// Apps whose windows show content another process draws (System Settings' panes): posted
/// events don't reach it, so an x/y click or scroll there goes as AX on the element at the point,
/// found by walking down the window.
public enum ComputerUseRemoteContent {
    public static let bundleIDs: Set<String> = ["com.apple.systempreferences"]

    public static func hostsContentRemotely(bundleID: String?) -> Bool {
        bundleIDs.contains(bundleID ?? "")
    }

    public static let pressableRoles: Set<String> = [
        "AXButton", "AXRow", "AXCell", "AXLink", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXMenuButton",
    ]

    public enum Input: Sendable { case click, scroll }

    /// An element on the way down the window to the point: its role and AX actions.
    public struct Step: Sendable, Equatable {
        public var role: String
        public var actions: [String]

        public init(role: String, actions: [String] = []) {
            self.role = role
            self.actions = actions
        }
    }

    /// The index in `path` (the window first, the deepest element at the point last) of the
    /// element the input goes to: for a click the deepest pressable one, for a scroll the deepest
    /// scroll area; nil when there is none, and events go as for any app. Never the window itself.
    public static func target(for input: Input, path: [Step]) -> Int? {
        let candidates = path.indices.dropFirst()
        switch input {
        case .click:
            return candidates.last { pressableRoles.contains(path[$0].role) || path[$0].actions.contains("AXPress") }
        case .scroll:
            return candidates.last { path[$0].role == "AXScrollArea" }
        }
    }
}
