import Foundation
import Testing
@testable import Alas

@Suite("ACP usage limits")
struct ACPUsageLimitTests {
    static let madrid: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return cal
    }()

    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, tz: String = "Europe/Madrid") -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    struct ResetCase: Sendable, CustomTestStringConvertible {
        let text: String
        let now: Date
        let expected: Date?
        var testDescription: String { text }
    }

    static let resetCases: [ResetCase] = [
        // Codex, absolute local time with ordinal and year.
        .init(text: "You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Sep 21st, 2026 4:35 PM.",
              now: date(2026, 9, 20, 10, 0), expected: date(2026, 9, 21, 16, 35)),
        // Claude, time only, later today in the named zone.
        .init(text: "You've hit your limit · resets 3pm (Europe/Madrid)",
              now: date(2026, 10, 3, 10, 0), expected: date(2026, 10, 3, 15, 0)),
        // Claude, time only, an hour or more past today: next day.
        .init(text: "You've hit your limit · resets 3pm (Europe/Madrid)",
              now: date(2026, 10, 3, 16, 0), expected: date(2026, 10, 4, 15, 0)),
        // Claude, time only, just past: kept in the past (the reset was wrong).
        .init(text: "You've hit your limit · resets 3pm (Europe/Madrid)",
              now: date(2026, 10, 3, 15, 2), expected: date(2026, 10, 3, 15, 0)),
        // Claude, month/day just past: kept, not rolled to next year.
        .init(text: "You've hit your weekly limit · resets Oct 4, 3:30pm (Europe/Madrid)",
              now: date(2026, 10, 4, 15, 31), expected: date(2026, 10, 4, 15, 30)),
        // Claude, month/day with minutes, other zone.
        .init(text: "You've hit your weekly limit · resets Oct 4, 3:30pm (America/New_York)",
              now: date(2026, 10, 3, 10, 0), expected: date(2026, 10, 4, 15, 30, tz: "America/New_York")),
        // No zone: falls back to the calendar's zone.
        .init(text: "You've hit your limit · resets 11am",
              now: date(2026, 10, 3, 10, 0), expected: date(2026, 10, 3, 11, 0)),
        // No reset time at all.
        .init(text: "You've hit your usage limit.", now: date(2026, 10, 3, 10, 0), expected: nil),
        .init(text: "Your limit resets in 2h", now: date(2026, 10, 3, 10, 0), expected: nil),
    ]

    @Test("reset time is read from provider limit text", arguments: resetCases)
    func parsesResetTime(_ c: ResetCase) {
        #expect(ACPUsageLimitResetParser.resetDate(in: c.text, now: c.now, calendar: Self.madrid) == c.expected)
    }

    @Test("provider dates are Gregorian whatever the user's calendar",
          arguments: [Calendar.Identifier.buddhist, .japanese, .islamicUmmAlQura])
    func parsesResetTimeWithNonGregorianCalendar(_ identifier: Calendar.Identifier) {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = Self.madrid.timeZone
        let text = "You've hit your usage limit. Try again at Sep 21st, 2026 4:35 PM."
        #expect(ACPUsageLimitResetParser.resetDate(in: text, now: Self.date(2026, 9, 20, 10, 0), calendar: calendar)
            == Self.date(2026, 9, 21, 16, 35))
    }

    struct DetectCase: Sendable, CustomTestStringConvertible {
        let name: String
        let error: JSONRPCError
        let turnAgentText: String?
        let rateLimit: ACPClaudeRateLimit?
        /// nil = not a usage limit.
        let expected: (resetsAt: Date?, source: ACPUsageLimit.ResetSource, resettable: Bool)?
        var now: Date = ACPUsageLimitTests.now
        /// Pass the error as a bare `JSONRPCError` instead of wrapped in `ACPClientError`.
        var bare = false
        var testDescription: String { name }
    }

    static let now = date(2026, 10, 3, 10, 0)

    static func codexError(_ message: String) -> JSONRPCError {
        JSONRPCError(code: -32603, message: "Internal error", data: AnyCodable([
            "message": AnyCodable(message),
            "codexErrorInfo": AnyCodable("usageLimitExceeded"),
        ]))
    }

    static let detectCases: [DetectCase] = [
        .init(name: "codex flag with reset in text",
              error: codexError("You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Oct 4th, 2026 4:35 PM."),
              turnAgentText: nil, rateLimit: nil,
              expected: (date(2026, 10, 4, 16, 35), .parsed, true)),
        .init(name: "codex flag without reset",
              error: codexError("You've hit your usage limit."),
              turnAgentText: nil, rateLimit: nil,
              expected: (nil, .unknown, true)),
        .init(name: "codex flag with a reset already past",
              error: codexError("You've hit your usage limit. Try again at Sep 21st, 2026 4:35 PM."),
              turnAgentText: nil, rateLimit: nil,
              expected: (nil, .unknown, true)),
        .init(name: "claude prefix in error message",
              error: JSONRPCError(code: -32603, message: "Internal error: You've hit your limit · resets 3pm (Europe/Madrid)", data: nil),
              turnAgentText: nil, rateLimit: nil,
              expected: (date(2026, 10, 3, 15, 0), .parsed, true)),
        .init(name: "claude structured reset wins over text",
              error: JSONRPCError(code: -32603, message: "Internal error: You've hit your limit · resets 3pm (Europe/Madrid)", data: nil),
              turnAgentText: nil,
              rateLimit: ACPClaudeRateLimit(status: "rejected", resetsAt: date(2026, 10, 3, 14, 59)),
              expected: (date(2026, 10, 3, 14, 59), .structured, true)),
        .init(name: "claude stale structured reset is ignored",
              error: JSONRPCError(code: -32603, message: "Internal error: You've hit your limit", data: nil),
              turnAgentText: nil,
              rateLimit: ACPClaudeRateLimit(status: "rejected", resetsAt: date(2026, 10, 2, 9, 0)),
              expected: (nil, .unknown, true)),
        .init(name: "claude prefix only in this turn's agent text",
              error: JSONRPCError(code: -32603, message: "Internal error", data: nil),
              turnAgentText: "You've reached your weekly limit · resets Oct 4, 3:30pm (Europe/Madrid)",
              rateLimit: nil,
              expected: (date(2026, 10, 4, 15, 30), .parsed, true)),
        .init(name: "claude reset that just passed is unknown",
              error: JSONRPCError(code: -32603, message: "Internal error: You've hit your limit · resets 3pm (Europe/Madrid)", data: nil),
              turnAgentText: nil, rateLimit: nil,
              expected: (nil, .unknown, true), now: date(2026, 10, 3, 15, 2)),
        .init(name: "claude month/day reset that just passed is unknown",
              error: JSONRPCError(code: -32603, message: "Internal error: You've hit your weekly limit · resets Oct 4, 3:30pm (Europe/Madrid)", data: nil),
              turnAgentText: nil, rateLimit: nil,
              expected: (nil, .unknown, true), now: date(2026, 10, 4, 15, 31)),
        .init(name: "parsed reset more than 8 days out is unknown",
              error: codexError("You've hit your usage limit. Try again at Oct 12th, 2026 10:01 AM."),
              turnAgentText: nil, rateLimit: nil,
              expected: (nil, .unknown, true)),
        .init(name: "bare JSONRPCError",
              error: JSONRPCError(code: -32603, message: "Internal error: You've hit your limit", data: nil),
              turnAgentText: nil, rateLimit: nil,
              expected: (nil, .unknown, true), bare: true),
        .init(name: "claude org block is not resettable",
              error: JSONRPCError(code: -32603, message: "Internal error: Your org is out of usage · contact your admin", data: nil),
              turnAgentText: nil, rateLimit: nil,
              expected: (nil, .unknown, false)),
        .init(name: "unrelated error",
              error: JSONRPCError(code: -32603, message: "Internal error: connection reset", data: nil),
              turnAgentText: "I hit a limit in the parser, retrying.", rateLimit: nil,
              expected: nil),
        .init(name: "codex other error info",
              error: JSONRPCError(code: -32603, message: "Internal error", data: AnyCodable(["codexErrorInfo": AnyCodable("contextWindowExceeded")])),
              turnAgentText: nil, rateLimit: nil,
              expected: nil),
    ]

    @Test("a failed prompt is classified as a usage limit only on provider signals", arguments: detectCases)
    func detectsUsageLimit(_ c: DetectCase) {
        let limit = ACPUsageLimitDetector.detect(
            error: c.bare ? c.error as Error : ACPClientError.jsonrpc(c.error), turnAgentText: c.turnAgentText,
            claudeRateLimit: c.rateLimit, now: c.now, calendar: Self.madrid
        )
        guard let expected = c.expected else {
            #expect(limit == nil)
            return
        }
        #expect(limit == ACPUsageLimit(
            detectedAt: c.now, resetsAt: expected.resetsAt, resetSource: expected.source,
            probeAttempt: 0, resettable: expected.resettable
        ))
    }

    static func quotaRecord(title: String, details: String? = nil) throws -> ACPSessionFailureRecord {
        var json: [String: Any] = [
            "version": 1, "id": "t:quota", "revision": 1, "severity": "error",
            "kind": ACPSessionFailureRecord.quotaExhaustedKind, "title": title,
        ]
        json["details"] = details
        return try JSONDecoder().decode(ACPSessionFailureRecord.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test("a quota record's resettability comes from its prefix, then its adapter", arguments: [
        ("codex", "You've hit your usage limit. Try again at 5pm.", true, ACPUsageLimit.ResetSource.parsed),
        ("codex", "Usage limit exceeded", true, .unknown),
        ("claude", "You've hit your limit · resets 5pm", true, .parsed),
        ("claude", "Fable 5 requires usage credits", false, .unknown),
        ("claude", "Your credit balance is too low", false, .unknown),
    ] as [(String, String, Bool, ACPUsageLimit.ResetSource)])
    func quotaRecordResettable(agentID: String, title: String, resettable: Bool, source: ACPUsageLimit.ResetSource) throws {
        let limit = try #require(ACPUsageLimitDetector.detect(
            failure: Self.quotaRecord(title: title), turnAgentText: nil, claudeRateLimit: nil,
            now: Self.now, calendar: Self.madrid,
            resettableUnlessClaude: agentID != ACPManagedAdapterDescriptor.claude.agentID
        ))
        #expect(limit.resettable == resettable)
        #expect(limit.resetSource == source)
    }

    @Test("a quota record prefers the structured reset over its text")
    func quotaRecordPrefersStructuredReset() throws {
        let resetsAt = Self.date(2026, 10, 3, 14, 59)
        let limit = ACPUsageLimitDetector.detect(
            failure: try Self.quotaRecord(title: "You've hit your limit · resets 5pm"), turnAgentText: nil,
            claudeRateLimit: ACPClaudeRateLimit(status: "rejected", resetsAt: resetsAt),
            now: Self.now, calendar: Self.madrid, resettableUnlessClaude: false
        )
        #expect(limit?.resetsAt == resetsAt)
        #expect(limit?.resetSource == .structured)
    }

    @Test("a quota record reads its reset from details, then title, then the turn's text", arguments: [
        ("Limit · resets 3pm", "Try again at 5pm.", "resets 7pm", 17),
        ("Limit · resets 3pm", nil, "resets 7pm", 15),
        ("Limit", nil, "resets 7pm", 19),
    ] as [(String, String?, String, Int)])
    func quotaRecordResetCandidates(title: String, details: String?, agentText: String, hour: Int) throws {
        let limit = ACPUsageLimitDetector.detect(
            failure: try Self.quotaRecord(title: title, details: details), turnAgentText: agentText,
            claudeRateLimit: nil, now: Self.now, calendar: Self.madrid, resettableUnlessClaude: true
        )
        #expect(limit?.resetsAt == Self.date(2026, 10, 3, hour, 0))
        #expect(limit?.resetSource == .parsed)
    }

    struct ResumeCase: Sendable, CustomTestStringConvertible {
        let name: String
        let limit: ACPUsageLimit
        let now: Date
        let expected: Date?
        var testDescription: String { name }
    }

    static func limit(detectedAt: Date = now, resetsAt: Date? = nil, attempt: Int = 0, resettable: Bool = true) -> ACPUsageLimit {
        ACPUsageLimit(detectedAt: detectedAt, resetsAt: resetsAt, resetSource: resetsAt == nil ? .unknown : .parsed,
                      probeAttempt: attempt, resettable: resettable)
    }

    static let resumeCases: [ResumeCase] = [
        .init(name: "known reset: reset plus grace",
              limit: limit(resetsAt: now + 3600), now: now, expected: now + 3600 + 60),
        .init(name: "known reset already past falls back to backoff",
              limit: limit(resetsAt: now - 60, attempt: 1), now: now, expected: now + 30 * 60),
        .init(name: "unknown, first probe", limit: limit(), now: now, expected: now + 15 * 60),
        .init(name: "unknown, second probe", limit: limit(attempt: 1), now: now, expected: now + 30 * 60),
        .init(name: "unknown, later probes hourly", limit: limit(attempt: 5), now: now, expected: now + 60 * 60),
        .init(name: "gives up 24h after detection",
              limit: limit(detectedAt: now - 24 * 3600, attempt: 9), now: now, expected: nil),
        .init(name: "a far known reset is still scheduled",
              limit: limit(resetsAt: now + 5 * 24 * 3600), now: now, expected: now + 5 * 24 * 3600 + 60),
        .init(name: "not resettable never resumes", limit: limit(resettable: false), now: now, expected: nil),
    ]

    @Test("resume time follows the reset or the probe backoff", arguments: resumeCases)
    func nextResumeAt(_ c: ResumeCase) {
        #expect(ACPUsageLimitResumePolicy.nextResumeAt(c.limit, now: c.now) == c.expected)
    }

    @Test("a repeated limit keeps the first detection, counts the attempt, and holds prompts queued before the latest hit")
    func mergeRepeatedLimit() {
        let first = Self.limit(detectedAt: Self.now - 900)
        let again = Self.limit(detectedAt: Self.now, resetsAt: Self.now + 600)
        let merged = ACPUsageLimitResumePolicy.merge(previous: first, detected: again)
        #expect(merged.detectedAt == Self.now - 900)
        #expect(merged.probeAttempt == 1)
        #expect(merged.resetsAt == Self.now + 600)
        #expect(ACPUsageLimitResumePolicy.merge(previous: nil, detected: again) == again)
        // Queued while a message sent during the episode was in flight.
        let queuedBetweenHits = QueuedPrompt(blocks: [.text("b")], enqueuedAt: Self.now - 300)
        #expect(queuedBetweenHits.isHeld(by: merged))
        #expect(!QueuedPrompt(blocks: [.text("c")], enqueuedAt: Self.now + 1).isHeld(by: merged))
    }
}
