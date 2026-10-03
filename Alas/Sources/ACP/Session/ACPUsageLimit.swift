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
/// nil, or a time already past, falls back to probing (`ACPUsageLimitResumePolicy`).
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
            if explicitYear == nil, now.timeIntervalSince(date) >= recentPastTolerance,
               let year = components.year {
                components.year = year + 1
                date = cal.date(from: components) ?? date
            }
            return date
        }
        guard let today = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
        return now.timeIntervalSince(today) < recentPastTolerance ? today : cal.date(byAdding: .day, value: 1, to: today)
    }

    /// A reset that passed less than this long ago is returned as is, not
    /// rolled to the next day or year: a limit still active just after its
    /// stated reset means the reset was wrong, so the caller should probe
    /// rather than wait a day (or a year).
    static let recentPastTolerance: TimeInterval = 3600
}

/// Classifies a failed `session/prompt` as a provider usage limit. Uses only
/// structured signals and the SDK's exact message prefixes, never loose prose:
/// a false positive would stop a session from retrying for hours.
enum ACPUsageLimitDetector {
    /// Mirrors `USAGE_LIMIT_ERROR_PREFIXES` in @anthropic-ai/claude-agent-sdk
    /// (sdk.d.ts); claude-agent-acp matches the same list.
    static let claudeUsageLimitPrefixes: [String] = [
        "You've hit your",
        "You've reached your",
        "You're out of usage credits",
        "Your org is out of usage · add funds to continue",
        "Your org is out of usage · contact your admin",
        "Your seat type doesn't include usage credits",
        "Your seat type doesn't include usage",
        "Your usage allocation has been disabled by your admin",
        "Your group's usage limit is set to $0",
        "Fable 5 requires usage credits",
        "You're out of extra usage",
        "Your seat type doesn't include extra usage",
    ]
    /// The prefixes a limit window reset lifts. The rest are account, seat or
    /// credit blocks that need someone to act.
    static let resettableClaudePrefixes: [String] = ["You've hit your", "You've reached your"]
    /// codex-acp puts `codexErrorInfo` in the JSON-RPC error `data`.
    static let codexUsageLimitInfo: Set<String> = ["usageLimitExceeded", "usage_limit_exceeded"]
    /// The longest provider window is a week; a parsed reset further out is
    /// a misread, so it is treated as unknown and probed.
    static let maxParsedResetAhead: TimeInterval = 8 * 24 * 3600

    static func detect(
        error: Error,
        turnAgentText: String?,
        claudeRateLimit: ACPClaudeRateLimit?,
        now: Date,
        calendar: Calendar = .current
    ) -> ACPUsageLimit? {
        guard let rpc = jsonRPCError(error) else { return nil }
        let data = object(rpc.data)
        let message = strippedMessage(rpc.message)
        let agentText = turnAgentText?.trimmingCharacters(in: .whitespacesAndNewlines)

        let candidates: [String]
        let resettable: Bool
        if let info = data?["codexErrorInfo"] as? String, codexUsageLimitInfo.contains(info) {
            candidates = [data?["message"] as? String, message, agentText].compactMap { $0 }
            resettable = true
        } else if let text = [message, agentText].compactMap({ $0 }).first(where: { text in
            claudeUsageLimitPrefixes.contains { text.hasPrefix($0) }
        }) {
            candidates = [text]
            resettable = resettableClaudePrefixes.contains { text.hasPrefix($0) }
        } else {
            return nil
        }

        var resetsAt: Date?
        var source = ACPUsageLimit.ResetSource.unknown
        if let rateLimit = claudeRateLimit, rateLimit.status == "rejected",
           let structured = rateLimit.resetsAt, structured > now {
            resetsAt = structured
            source = .structured
        } else if let parsed = candidates.lazy
            .compactMap({ ACPUsageLimitResetParser.resetDate(in: $0, now: now, calendar: calendar) })
            .first, parsed > now, parsed.timeIntervalSince(now) <= maxParsedResetAhead {
            resetsAt = parsed
            source = .parsed
        }
        return ACPUsageLimit(
            detectedAt: now, resetsAt: resetsAt, resetSource: source,
            probeAttempt: 0, resettable: resettable
        )
    }

    private static func jsonRPCError(_ error: Error) -> JSONRPCError? {
        if let rpc = error as? JSONRPCError { return rpc }
        if case ACPClientError.jsonrpc(let rpc) = error { return rpc }
        return nil
    }

    /// `RequestError.internalError` prefixes the adapter's message.
    private static func strippedMessage(_ message: String) -> String {
        let prefix = "Internal error: "
        return message.hasPrefix(prefix) ? String(message.dropFirst(prefix.count)) : message
    }

    private static func object(_ value: AnyCodable?) -> [String: Any]? {
        if let dict = value?.value as? [String: AnyCodable] { return dict.mapValues(\.value) }
        return value?.value as? [String: Any]
    }
}

/// When to resume a session stopped by a usage limit.
enum ACPUsageLimitResumePolicy {
    static let continueText = "The usage limit has reset. Continue where you left off."
    /// Slack after a known reset so the first attempt doesn't race the provider's clock.
    static let resetGrace: TimeInterval = 60
    /// Stop auto-resuming this long after the first detection.
    static let giveUpAfter: TimeInterval = 24 * 3600

    /// Nil means "don't auto-resume": not resettable, or given up.
    static func nextResumeAt(_ limit: ACPUsageLimit, now: Date) -> Date? {
        guard limit.resettable, now.timeIntervalSince(limit.detectedAt) < giveUpAfter else { return nil }
        if let resetsAt = limit.resetsAt, resetsAt > now {
            return resetsAt + resetGrace
        }
        // Unknown, or a reset that turned out wrong: probe. A probe that
        // hits the limit again is rejected immediately and costs nothing.
        let delay: TimeInterval = switch limit.probeAttempt {
        case 0: 15 * 60
        case 1: 30 * 60
        default: 60 * 60
        }
        return now + delay
    }

    /// Fold a new detection into the episode already in progress.
    static func merge(previous: ACPUsageLimit?, detected: ACPUsageLimit) -> ACPUsageLimit {
        guard let previous else { return detected }
        var merged = detected
        merged.detectedAt = previous.detectedAt
        merged.probeAttempt = previous.probeAttempt + 1
        return merged
    }
}
