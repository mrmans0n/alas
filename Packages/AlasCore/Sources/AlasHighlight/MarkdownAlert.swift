import Foundation

/// GitHub alerts: a blockquote whose first line is `[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]` or
/// `[!CAUTION]`. Shared by the Mac's markdown parser and the phone's, like `MermaidFence` and `VisualFence`.
public enum MarkdownAlert: Sendable {
    public enum Kind: String, CaseIterable, Equatable, Sendable {
        case note, tip, important, warning, caution

        /// GitHub's wording.
        public var title: String {
            switch self {
            case .note: "Note"
            case .tip: "Tip"
            case .important: "Important"
            case .warning: "Warning"
            case .caution: "Caution"
            }
        }

        /// An SF Symbol close to GitHub's octicon.
        public var symbol: String {
            switch self {
            case .note: "info.circle"
            case .tip: "lightbulb"
            case .important: "exclamationmark.bubble"
            case .warning: "exclamationmark.triangle"
            case .caution: "exclamationmark.octagon"
            }
        }
    }

    /// The alert the quote's lines (without their `>` prefixes) open with, and the body after the marker.
    /// Text on the marker line, which GitHub drops, is kept as the body's first line.
    public static func match(_ quoted: [String]) -> (kind: Kind, body: String)? {
        guard let first = quoted.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("[!"),
              let close = first.firstIndex(of: "]"),
              let kind = Kind(rawValue: first[first.index(first.startIndex, offsetBy: 2)..<close].lowercased())
        else { return nil }
        let rest = first[first.index(after: close)...].trimmingCharacters(in: .whitespaces)
        let body = (rest.isEmpty ? [] : [rest]) + quoted.dropFirst()
        return (kind, body.joined(separator: "\n"))
    }
}
