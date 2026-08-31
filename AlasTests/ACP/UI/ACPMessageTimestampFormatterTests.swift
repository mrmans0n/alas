import Foundation
import Testing
@testable import Alas

@Suite("ACP message timestamp formatting")
struct ACPMessageTimestampFormatterTests {
    @Test("uses time today, month and day this year, and year for older dates")
    func adaptiveTimestamp() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_GB")
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(
                year: year, month: month, day: day, hour: hour, minute: minute
            ))!
        }
        let now = date(2026, 8, 29, 15, 30)

        #expect(ACPMessageTimestampFormatter.string(
            for: date(2026, 8, 29, 14, 42),
            relativeTo: now, calendar: calendar, locale: locale
        ) == "14:42")
        #expect(ACPMessageTimestampFormatter.string(
            for: date(2026, 8, 26, 15, 42),
            relativeTo: now, calendar: calendar, locale: locale
        ) == "26 Aug, 15:42")
        #expect(ACPMessageTimestampFormatter.string(
            for: date(2025, 8, 26, 15, 42),
            relativeTo: now, calendar: calendar, locale: locale
        ) == "26 Aug 2025, 15:42")
    }

    @Test("tool duration keeps sub-ten-second precision")
    func toolDuration() {
        let locale = Locale(identifier: "en_US")
        #expect(ACPToolCallDurationFormatter.string(for: 2.4, locale: locale) == "2.4s")
        #expect(ACPToolCallDurationFormatter.string(for: 42, locale: locale) == "42s")
    }

    @Test("places the hover timestamp below the message actions button")
    func hoverTimestampPlacement() {
        #expect(ACPMessageGutterLayout.timestampVerticalSpacing == 4)
    }

    @Test("reserves enough width for a timestamp below the message actions button")
    func hoverTimestampWidth() {
        #expect(ACPMessageGutterLayout.timestampWidth == 128)
    }
}
