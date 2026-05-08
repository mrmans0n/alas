import AppKit

/// Returns installed monospace font family names. Cached after first call —
/// the system font set doesn't change at runtime.
enum MonospaceFontCatalog {
    private static let cache: [String] = {
        let fm = NSFontManager.shared
        let fixedPSNames = Set(fm.availableFontNames(with: .fixedPitchFontMask) ?? [])
        // availableFontFamilies returns family names; availableFontNames(with:)
        // returns PostScript names. A family is considered monospace if any of
        // its members is fixed-pitch.
        let allFamilies = fm.availableFontFamilies
        var monospace: [String] = []
        for family in allFamilies {
            let members = fm.availableMembers(ofFontFamily: family) ?? []
            let hasFixed = members.contains { row in
                guard let psName = row.first as? String else { return false }
                return fixedPSNames.contains(psName)
            }
            if hasFixed {
                monospace.append(family)
            }
        }
        return monospace.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()

    static func families() -> [String] { cache }
}
