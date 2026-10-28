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

    /// Elements that take typed text.
    public static func isTextEntry(_ element: Element) -> Bool {
        [element.role, element.subrole].contains { $0.map(textEntryRoles.contains) == true }
    }

    /// Focused roles that are an editing surface without being a text field: a spreadsheet grid
    /// or cell, a document canvas, the scroll view that hosts one (Numbers, Pages, LibreOffice).
    static let editorSurfaceRoles: Set<String> = ["AXLayoutArea", "AXLayoutItem", "AXScrollArea", "AXTable", "AXCell", "AXGroup"]

    /// Apps whose windows act on typed keys outside a text field: Finder's type-to-select moves
    /// the selection to the file whose name starts with them.
    static let itemBrowserBundleIDs: Set<String> = ["com.apple.finder", "com.apple.dock"]

    /// Whether text typed as keys without a ref may go to the app's focused element (nil when
    /// nothing has focus): a text-entry element, one with a text selection (`selectsText`, a text
    /// view of another role), anything in a web page (`inWebArea`, a contenteditable), anything in
    /// a terminal or code editor (`keyCommandApp`), or an editing surface. Lists, outlines and
    /// buttons are refused, since keys there act on the view instead of typing; in Finder and the
    /// Dock (`bundleID`) only a text field takes them, even with nothing focused.
    public static func acceptsTypedKeys(
        _ element: Element?, selectsText: Bool, inWebArea: Bool, keyCommandApp: Bool, bundleID: String?
    ) -> Bool {
        let itemBrowser = itemBrowserBundleIDs.contains(bundleID ?? "")
        guard let element else { return !itemBrowser }
        if isTextEntry(element) || selectsText || inWebArea || keyCommandApp { return true }
        return !itemBrowser && element.role.map(editorSurfaceRoles.contains) == true
    }

    /// Whether a left click by ref puts the keyboard in the element through AX focus: only a web
    /// page's field, where an AX press may mark it focused in the page while the keyboard stays
    /// in the address bar. A native field keeps the plain click: some select all their text on
    /// taking focus, and a later ref-less type would replace it.
    public static func focusesOnClick(_ element: Element, inWebArea: Bool) -> Bool {
        inWebArea && isTextEntry(element)
    }

    /// Whether `chord` must be refused, given every element that reads as focused: the app's
    /// focused element and the window's own focused ones, which differ in a web page whose
    /// field took AX focus while the keyboard stayed elsewhere (the address bar).
    public static func refuses(_ chord: ComputerUseKeyChord, focused: [Element]) -> Bool {
        chord.mayEditText && focused.contains(where: isSecure)
    }
}
