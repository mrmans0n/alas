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
        // Claude, time only, already past today: next day.
        .init(text: "You've hit your limit · resets 3pm (Europe/Madrid)",
              now: date(2026, 10, 3, 16, 0), expected: date(2026, 10, 4, 15, 0)),
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

    struct DetectCase: Sendable, CustomTestStringConvertible {
        let name: String
        let error: JSONRPCError
        let turnAgentText: String?
        let rateLimit: ACPClaudeRateLimit?
        /// nil = not a usage limit.
        let expected: (resetsAt: Date?, source: ACPUsageLimit.ResetSource, resettable: Bool)?
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
            error: ACPClientError.jsonrpc(c.error), turnAgentText: c.turnAgentText,
            claudeRateLimit: c.rateLimit, now: Self.now, calendar: Self.madrid
        )
        guard let expected = c.expected else {
            #expect(limit == nil)
            return
        }
        #expect(limit == ACPUsageLimit(
            detectedAt: Self.now, resetsAt: expected.resetsAt, resetSource: expected.source,
            probeAttempt: 0, resettable: expected.resettable
        ))
    }

    @Test("a bare JSONRPCError is accepted too")
    func acceptsBareJSONRPCError() {
        let limit = ACPUsageLimitDetector.detect(
            error: JSONRPCError(code: -32603, message: "Internal error: You've hit your limit", data: nil),
            turnAgentText: nil, claudeRateLimit: nil, now: Self.now, calendar: Self.madrid
        )
        #expect(limit != nil)
    }
}
