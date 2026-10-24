import Foundation

/// Which elements take keyboard text, and when a key chord must be refused because a secure
/// text field may receive it.
public enum ComputerUseSecureFocus {
    /// An element's role and subrole, as read.
    public struct Element: Equatable, Sendable {
        public var role: String?
        public var subrole: String?

        public init(role: String?, subrole: String? = nil) {
            self.role = role
            self.subrole = subrole
        }
    }

    static let secureRole = "AXSecureTextField"
    static let textEntryRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", secureRole]

    /// Some apps expose a password field as the role rather than the subrole.
    public static func isSecure(_ element: Element) -> Bool {
        element.role == secureRole || element.subrole == secureRole
    }

    /// Elements a click should put the keyboard in.
    public static func isTextEntry(_ element: Element) -> Bool {
        [element.role, element.subrole].contains { $0.map(textEntryRoles.contains) == true }
    }

    /// Whether `chord` must be refused, given every element that reads as focused: the app's
    /// focused element and the window's own focused ones, which differ in a web page whose
    /// field took AX focus while the keyboard stayed elsewhere (the address bar).
    public static func refuses(_ chord: ComputerUseKeyChord, focused: [Element]) -> Bool {
        chord.mayEditText && focused.contains(where: isSecure)
    }
}
