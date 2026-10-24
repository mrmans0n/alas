import Foundation

/// Whether a direct paste may borrow the clipboard: only when every item the user had
/// can be put back as it was. Otherwise the text is typed instead.
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

    /// The most clipboard data a paste saves and restores.
    public static let sizeCap = 16 * 1024 * 1024

    /// Types whose data stands for something produced later, which a copy of the bytes doesn't bring back.
    public static let promiseTypes: Set<String> = [
        "com.apple.pasteboard.promised-file-url",
        "com.apple.NSFilePromiseItemMetaData",
        "NSPromiseContentsPboardType",
    ]

    /// Whether the type is a promise, which a paste refuses before reading any data.
    public static func isPromise(_ type: String) -> Bool {
        promiseTypes.contains(type)
    }

    /// False when any type's data couldn't be read, any type is a promise
    /// (a `dyn.` type without data counts as one), or the data adds up to more than `sizeCap`.
    public static func canRestore(_ items: [[SavedType]]) -> Bool {
        var total = 0
        for item in items {
            for saved in item {
                if isPromise(saved.type) { return false }
                guard let size = saved.size else { return false }
                total += size
                if total > sizeCap { return false }
            }
        }
        return true
    }
}
