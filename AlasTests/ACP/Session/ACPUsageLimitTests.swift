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
}
