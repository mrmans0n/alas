import Foundation

/// Turns dictation locale identifiers into names for the UI.
///
/// Names are rendered in English rather than the user's language because
/// the app itself ships English-only; a Spanish-region user reading an
/// otherwise-English Settings pane should see "Spanish (Spain)", not
/// "español (España)".
public enum ACPDictationLocaleFormatter: Sendable {
    /// Identifier meaning "detect the language automatically".
    public static let automaticIdentifier = ""

    private static let displayLocale = Locale(identifier: "en_US")

    public static func displayName(for identifier: String) -> String {
        guard !identifier.isEmpty else { return "Automatic" }
        let normalized = identifier.replacingOccurrences(of: "-", with: "_")
        guard let name = displayLocale.localizedString(forIdentifier: normalized), !name.isEmpty else {
            return identifier
        }
        return name
    }

    public static func sortedByDisplayName(_ identifiers: [String]) -> [String] {
        identifiers.sorted {
            displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending
        }
    }
}

/// One entry in the mic button's language or microphone menu.
public struct ACPDictationMenuItem: Equatable, Identifiable, Sendable {
    /// A locale identifier or a microphone UID. Empty means the automatic
    /// language or the system default microphone.
    public let identifier: String
    public let title: String
    public let isSelected: Bool

    public var id: String { identifier }

    public init(identifier: String, title: String, isSelected: Bool) {
        self.identifier = identifier
        self.title = title
        self.isSelected = isSelected
    }
}
