import Foundation

/// A transcript message, or a selection of one, quoted into the composer as Markdown.
public enum ACPMessageQuote {
    public static func canQuote(_ message: String) -> Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func markdown(_ message: String) -> String {
        message
            .components(separatedBy: "\n")
            .map { "> \($0)" }
            .joined(separator: "\n")
    }

    /// `draft` with `message` quoted on its own lines after it, ending on a fresh line to type the reply on.
    public static func appending(_ message: String, to draft: String) -> String {
        let leading = draft.isEmpty || draft.hasSuffix("\n") ? "" : "\n"
        return draft + leading + markdown(message) + "\n"
    }
}
