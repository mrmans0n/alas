import Foundation

/// Minimal semantic version (major.minor.patch) with numeric ordering.
/// Pre-release / build metadata suffixes are parsed but ignored for comparison.
struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(parsing raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }

        // Drop any "-prerelease" / "+build" suffix; compare on the core triple.
        let core = s.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? s
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { return nil }

        func component(_ index: Int) -> Int? {
            guard index < parts.count else { return 0 }
            guard let value = Int(parts[index]), value >= 0 else { return nil }
            return value
        }
        guard let ma = component(0), let mi = component(1), let pa = component(2) else { return nil }
        self.init(major: ma, minor: mi, patch: pa)
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}
