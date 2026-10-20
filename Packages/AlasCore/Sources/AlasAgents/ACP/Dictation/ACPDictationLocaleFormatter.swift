import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

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

/// One entry in the mic button's language menu.
public struct ACPDictationMenuItem: Equatable, Identifiable, Sendable {
    /// Empty string means the automatic choice.
    public let localeIdentifier: String
    public let title: String
    public let isSelected: Bool

    public var id: String { localeIdentifier }

    public init(localeIdentifier: String, title: String, isSelected: Bool) {
        self.localeIdentifier = localeIdentifier
        self.title = title
        self.isSelected = isSelected
    }
}
