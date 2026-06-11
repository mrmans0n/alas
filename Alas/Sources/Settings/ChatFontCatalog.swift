import AppKit

/// Returns installed font family names for chat prose. Cached after first call
/// because the system font set does not change during normal app runtime.
enum ChatFontCatalog {
    private static let cache: [String] = sortedFamilies(NSFontManager.shared.availableFontFamilies)

    static func families() -> [String] { cache }

    static func sortedFamilies(_ families: [String]) -> [String] {
        families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
