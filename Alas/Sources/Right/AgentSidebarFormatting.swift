import Foundation

/// Turns a raw model id (as advertised by an ACP adapter, e.g.
/// `claude-sonnet-4-5-20250929`) into a short, human-friendly label that fits
/// the sidebar's single-line metadata caption.
enum AgentSidebarModelDisplay {
    /// Known short acronyms that should stay uppercase rather than being
    /// title-cased. Kept intentionally small — everything else falls back to
    /// `String.capitalized`, which already does the right thing for family
    /// names like "sonnet" or "gemini".
    private static let acronyms: Set<String> = ["gpt"]

    static func shortName(for rawID: String) -> String {
        guard !rawID.isEmpty else { return rawID }
        // Cursor encodes thinking/effort/context as a bracket-suffixed variant,
        // e.g. "claude-opus-4-6[thinking=true,context=200k]"; that payload
        // belongs in the dedicated thinking chip, not this caption, so only
        // the base id gets tokenized.
        let base = CursorModelVariants.parse(rawID).base
        var tokens = base.split(separator: "-").map(String.init)

        // Drop a trailing snapshot date stamp, e.g. "-20250929".
        if let last = tokens.last, last.count == 8, last.allSatisfy(\.isNumber) {
            tokens.removeLast()
        }
        // The logo tile already identifies the "Claude" family; the prefix is
        // redundant in the caption.
        if let first = tokens.first, first.lowercased() == "claude", tokens.count > 1 {
            tokens.removeFirst()
        }
        guard !tokens.isEmpty else { return base }

        // Anthropic ids place the version both after the family (the current
        // "sonnet-4-5" scheme) and before it (older ids like "3-5-sonnet"),
        // so pure-integer tokens are pulled out by type rather than only
        // from one end, then dot-joined in their original order, e.g.
        // ["4", "5"] -> "4.5". Tokens that already contain a dot (as in
        // "2.5") are left as ordinary name tokens instead of being merged.
        var versionParts: [String] = []
        var nameTokens: [String] = []
        for token in tokens {
            if !token.isEmpty, token.allSatisfy(\.isNumber) {
                versionParts.append(token)
            } else {
                nameTokens.append(token)
            }
        }
        tokens = nameTokens

        let nameParts = tokens.map { token -> String in
            acronyms.contains(token.lowercased()) ? token.uppercased() : token.capitalized
        }

        let name = nameParts.joined(separator: " ")
        let version = versionParts.joined(separator: ".")
        switch (name.isEmpty, version.isEmpty) {
        case (false, false): return "\(name) \(version)"
        case (false, true): return name
        case (true, false): return version
        case (true, true): return base
        }
    }
}

/// Compact relative timestamps for the sidebar's metadata caption, where
/// `RelativeDateTimeFormatter`'s "3 min. ago" is too long to coexist with the
/// model name and host.
enum AgentSidebarRelativeTime {
    static func compact(from date: Date, to now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60:
            return "now"
        case ..<3_600:
            return "\(Int(seconds / 60))m"
        case ..<86_400:
            return "\(Int(seconds / 3_600))h"
        case ..<(86_400 * 30):
            return "\(Int(seconds / 86_400))d"
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
    }
}

/// Strips the mDNS `.local` suffix from a hostname; other hostnames pass
/// through unchanged.
enum AgentSidebarHostDisplay {
    static func shortName(for host: String) -> String {
        guard host.hasSuffix(".local") else { return host }
        return String(host.dropLast(".local".count))
    }
}
