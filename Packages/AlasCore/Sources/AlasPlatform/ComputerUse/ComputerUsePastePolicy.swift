import Foundation

/// Whether a direct paste may borrow the clipboard: only when it is empty or holds one item of
/// plain text, which can always be put back as it was. Anything richer (file copies, images, rich
/// text, several items, promised data) is left alone, and the text typed instead.
public enum ComputerUsePastePolicy {
    /// One type of one clipboard item, with the size of its data.
    public struct SavedType: Sendable {
        public var type: String
        /// Nil when the data couldn't be read.
        public var size: Int?

        public init(type: String, size: Int?) {
            self.type = type
            self.size = size
        }
    }

    /// The most clipboard text a paste saves and restores.
    public static let sizeCap = 16 * 1024 * 1024

    /// The plain-text flavours, with their legacy aliases. A `dyn.` type is never one: it may
    /// stand for data the app produces later.
    public static let plainTextTypes: Set<String> = [
        "public.utf8-plain-text",
        "public.utf16-plain-text",
        "public.utf16-external-plain-text",
        "public.plain-text",
        "NSStringPboardType",
        "com.apple.traditional-mac-plain-text",
    ]

    /// Whether the clipboard is empty or one item whose types are all plain text, decided from
    /// the type list alone, so nothing richer is ever read.
    public static func isPlainText(_ items: [[String]]) -> Bool {
        guard !items.isEmpty else { return true }
        guard items.count == 1, let types = items.first, !types.isEmpty else { return false }
        return types.allSatisfy(plainTextTypes.contains)
    }

    /// True for an empty clipboard, or one item whose types are all plain text, all read, and
    /// adding up to at most `sizeCap`.
    public static func canPaste(_ items: [[SavedType]]) -> Bool {
        guard isPlainText(items.map { $0.map(\.type) }) else { return false }
        var total = 0
        for saved in items.flatMap({ $0 }) {
            guard let size = saved.size else { return false }
            total += size
            if total > sizeCap { return false }
        }
        return true
    }
}
