import Foundation

/// Turns dictation locale identifiers into names for the UI.
///
/// Names are rendered in English rather than the user's language because
/// the app itself ships English-only; a Spanish-region user reading an
/// otherwise-English Settings pane should see "Spanish (Spain)", not
/// "español (España)".
enum ACPDictationLocaleFormatter {
    /// Identifier meaning "detect the language automatically".
    static let automaticIdentifier = ""

    private static let displayLocale = Locale(identifier: "en_US")

    static func displayName(for identifier: String) -> String {
        guard !identifier.isEmpty else { return "Automatic" }
        let normalized = identifier.replacingOccurrences(of: "-", with: "_")
        guard let name = displayLocale.localizedString(forIdentifier: normalized), !name.isEmpty else {
            return identifier
        }
        return name
    }

    static func sortedByDisplayName(_ identifiers: [String]) -> [String] {
        identifiers.sorted {
            displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending
        }
    }
}

/// One entry in the mic button's language menu.
struct ACPDictationMenuItem: Equatable, Identifiable {
    /// Empty string means the automatic choice.
    let localeIdentifier: String
    let title: String
    let isSelected: Bool

    var id: String { localeIdentifier }
}
