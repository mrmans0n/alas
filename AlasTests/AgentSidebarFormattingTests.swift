import Foundation
import Testing
@testable import Alas

@Suite("Agent sidebar formatting")
struct AgentSidebarFormattingTests {
    @Test
    func shortensAnthropicModelIdsByDroppingTheClaudePrefixDateStampAndJoiningTheVersion() {
        #expect(AgentSidebarModelDisplay.shortName(for: "claude-sonnet-4-5-20250929") == "Sonnet 4.5")
        #expect(AgentSidebarModelDisplay.shortName(for: "claude-opus-4-1-20250805") == "Opus 4.1")
    }

    @Test
    func uppercasesTheKnownGptAcronym() {
        #expect(AgentSidebarModelDisplay.shortName(for: "gpt-5") == "GPT 5")
    }

    @Test
    func capitalizesALetterAndDigitModelIdWithoutTreatingItAsAVersion() {
        #expect(AgentSidebarModelDisplay.shortName(for: "o3") == "O3")
    }

    @Test
    func leavesAMultiWordModelIdWithAnEmbeddedVersionIntact() {
        #expect(AgentSidebarModelDisplay.shortName(for: "gemini-2.5-pro") == "Gemini 2.5 Pro")
    }

    @Test
    func fallsBackToTheRawIdWhenThereIsNothingToShorten() {
        #expect(AgentSidebarModelDisplay.shortName(for: "") == "")
    }

    @Test
    func stripsACursorVariantSuffixBeforeShorteningTheBaseModelId() {
        let variantID = "claude-opus-4-6[thinking=true,context=200k,effort=high,fast=false]"
        #expect(AgentSidebarModelDisplay.shortName(for: variantID) == "Opus 4.6")
    }

    @Test
    func rendersUnderAMinuteAsNow() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(AgentSidebarRelativeTime.compact(from: Date(timeIntervalSince1970: 970), to: now) == "now")
    }

    @Test
    func rendersMinutesHoursAndDaysInAbbreviatedForm() {
        let now = Date(timeIntervalSince1970: 100_000)
        #expect(AgentSidebarRelativeTime.compact(from: now.addingTimeInterval(-5 * 60), to: now) == "5m")
        #expect(AgentSidebarRelativeTime.compact(from: now.addingTimeInterval(-3 * 3600), to: now) == "3h")
        #expect(AgentSidebarRelativeTime.compact(from: now.addingTimeInterval(-2 * 86_400), to: now) == "2d")
    }

    @Test
    func rendersAShortDateBeyondAMonth() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = utc.date(from: DateComponents(year: 2026, month: 3, day: 15))!
        let then = utc.date(from: DateComponents(year: 2026, month: 1, day: 4))!
        #expect(AgentSidebarRelativeTime.compact(from: then, to: now, timeZone: utc.timeZone) == "Jan 4")
    }

    @Test
    func dropsATrailingDotLocalSuffixFromAHostname() {
        #expect(AgentSidebarHostDisplay.shortName(for: "mac-mini.local") == "mac-mini")
        #expect(AgentSidebarHostDisplay.shortName(for: "builder.example.com") == "builder.example.com")
    }
}
