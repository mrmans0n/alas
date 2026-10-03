import Foundation

/// A provider usage limit that stopped a turn. Lives on `ACPSession` and,
/// while a resume is scheduled, on that resume `QueuedPrompt`, which is what
/// carries it across a relaunch.
struct ACPUsageLimit: Codable, Equatable, Sendable {
    enum ResetSource: String, Codable, Sendable {
        /// From the adapter's structured rate-limit metadata.
        case structured
        /// Read out of the limit message text.
        case parsed
        case unknown
    }

    /// First detection of this limit episode; repeated hits keep it.
    var detectedAt: Date
    /// Always in the future when set at detection time.
    var resetsAt: Date?
    var resetSource: ResetSource
    /// How many resume attempts hit the limit again.
    var probeAttempt: Int
    /// False for blocks a reset does not lift (org out of credits, seat
    /// type). Those are shown but never auto-resumed.
    var resettable: Bool
}

/// Claude's `rate_limit_event` info, forwarded by claude-agent-acp as
/// `usage_update._meta["_claude/rateLimit"]` (`SDKRateLimitInfo`).
struct ACPClaudeRateLimit: Codable, Equatable, Sendable {
    let status: String
    let resetsAt: Date?

    init(status: String, resetsAt: Date?) {
        self.status = status
        self.resetsAt = resetsAt
    }

    private enum CodingKeys: String, CodingKey { case status, resetsAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        // Epoch seconds; tolerate milliseconds.
        if let raw = try? c.decode(Double.self, forKey: .resetsAt) {
            resetsAt = Date(timeIntervalSince1970: raw > 1e12 ? raw / 1000 : raw)
        } else {
            resetsAt = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(resetsAt?.timeIntervalSince1970, forKey: .resetsAt)
    }
}

/// Reads the reset time out of a provider's usage-limit message. Best effort:
/// nil falls back to probing (`ACPUsageLimitResumePolicy`).
///
/// Phrasings seen:
/// - Codex: "…or try again at Sep 21st, 2026 4:35 PM." (local time)
/// - Claude Code: "You've hit your limit · resets 3pm (Europe/Madrid)",
///   "… · resets Oct 4, 3:30pm (America/New_York)"
enum ACPUsageLimitResetParser {
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:resets|try again at)\s+(?:([A-Za-z]{3})[A-Za-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(?:(\d{4}),?\s+)?(?:at\s+)?)?(\d{1,2})(?::(\d{2}))?\s*([ap]\.?m\.?)(?:\s*\(([^)]+)\))?"#,
        options: [.caseInsensitive]
    )
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    static func resetDate(in text: String, now: Date, calendar: Calendar = .current) -> Date? {
        let ns = text as NSString
        guard let match = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
        var cal = calendar
        if let zone = group(7).flatMap(TimeZone.init(identifier:)) {
            cal.timeZone = zone
        }
        guard let hour12 = group(4).flatMap(Int.init), (1...12).contains(hour12),
              let meridiem = group(6)
        else { return nil }
        let minute = group(5).flatMap(Int.init) ?? 0
        let hour = hour12 % 12 + (meridiem.lowercased().hasPrefix("p") ? 12 : 0)

        if let monthName = group(1)?.lowercased(),
           let monthIndex = months.firstIndex(of: monthName),
           let day = group(2).flatMap(Int.init) {
            let explicitYear = group(3).flatMap(Int.init)
            var components = DateComponents(
                year: explicitYear ?? cal.component(.year, from: now),
                month: monthIndex + 1, day: day, hour: hour, minute: minute
            )
            guard var date = cal.date(from: components) else { return nil }
            if explicitYear == nil, date <= now, let year = components.year {
                components.year = year + 1
                date = cal.date(from: components) ?? date
            }
            return date
        }
        guard let today = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
        return today > now ? today : cal.date(byAdding: .day, value: 1, to: today)
    }
}
