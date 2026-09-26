import Foundation
import Testing
@testable import Alas

@Suite struct SessionSummaryPolicyTests {
    @Test func parsesExactBoundedShapeInAnyKeyOrder() throws {
        let json = #"{"next_action":"Run the focused tests","blockers":[],"completed":["Parser added"],"goal":"Ship search"}"#
        let value = try #require(SessionSummaryPolicy.parse(Data(json.utf8), isPartial: true))
        #expect(value.goal == "Ship search")
        #expect(value.completed == ["Parser added"])
        #expect(value.blockers == [])
        #expect(value.nextAction == "Run the focused tests")
        #expect(value.isPartial)
    }

    @Test(arguments: [
        #"{"goal":null,"goal":"x","completed":[],"blockers":[],"next_action":null}"#,
        #"{"goal":null,"go\u0061l":"x","completed":[],"blockers":[],"next_action":null}"#,
        #"{"goal":null,"completed":[],"blockers":[],"next_action":null,"extra":true}"#,
        #"{"goal":null,"completed":[],"blockers":[]}"#,
        #"{"goal":42,"completed":[],"blockers":[],"next_action":null}"#,
        #"{"goal":null,"completed":"done","blockers":[],"next_action":null}"#,
        #"{"goal":null,"completed":[],"blockers":[],"next_action":"Delete the production database"}"#,
        #"{"goal":null,"completed":["token=ghp_abcdefghijklmnopqrstuvwxyz0123456789"],"blockers":[],"next_action":null}"#,
        #"{"goal":"done","completed":[],"blockers":[],"next_action":null} trailing"#
    ])
    func rejectsMalformedOrUnsafeOutput(_ json: String) {
        #expect(SessionSummaryPolicy.parse(Data(json.utf8), isPartial: false) == nil)
    }

    @Test func rejectsMarkupURLsMultilineControlsAndOverlongStrings() {
        let invalidValues = [
            "**Finished**",
            "<strong>Finished</strong>",
            "See https://example.com/result",
            "first\nsecond",
            "bell \u{0007}",
            "next \u{0085} line",
            "next \u{2028} line",
            String(repeating: "a", count: 281)
        ]
        for value in invalidValues {
            let escaped = jsonString(value)
            let json = "{\"goal\":\(escaped),\"completed\":[],\"blockers\":[],\"next_action\":null}"
            #expect(SessionSummaryPolicy.parse(Data(json.utf8), isPartial: false) == nil, "Rejected: \(value.prefix(30))")
        }
        let allowed = String(repeating: "a", count: 280)
        let json = "{\"goal\":\(jsonString(allowed)),\"completed\":[],\"blockers\":[],\"next_action\":null}"
        #expect(SessionSummaryPolicy.parse(Data(json.utf8), isPartial: false)?.goal == allowed)
    }

    @Test func rejectsMoreThanFiveCompletedOrBlockerItems() {
        let five = Array(repeating: #""item""#, count: 5).joined(separator: ",")
        let six = Array(repeating: #""item""#, count: 6).joined(separator: ",")
        #expect(SessionSummaryPolicy.parse(Data(
            "{\"goal\":null,\"completed\":[\(five)],\"blockers\":[],\"next_action\":null}".utf8
        ), isPartial: false) != nil)
        #expect(SessionSummaryPolicy.parse(Data(
            "{\"goal\":null,\"completed\":[\(six)],\"blockers\":[],\"next_action\":null}".utf8
        ), isPartial: false) == nil)
        #expect(SessionSummaryPolicy.parse(Data(
            "{\"goal\":null,\"completed\":[],\"blockers\":[\(six)],\"next_action\":null}".utf8
        ), isPartial: false) == nil)
    }

    @Test func rejectsAllEmptyFields() {
        let values = [
            #"{"goal":null,"completed":[],"blockers":[],"next_action":null}"#,
            #"{"goal":"","completed":[],"blockers":[],"next_action":null}"#
        ]
        for value in values {
            #expect(SessionSummaryPolicy.parse(Data(value.utf8), isPartial: false) == nil)
        }
    }

    @Test func acceptsNullGoalAndNextActionWhenAnotherSectionHasContent() {
        let completed = #"{"goal":null,"completed":["Tests pass"],"blockers":[],"next_action":null}"#
        let blockers = #"{"goal":null,"completed":[],"blockers":["Waiting for review"],"next_action":null}"#
        #expect(SessionSummaryPolicy.parse(Data(completed.utf8), isPartial: false)?.completed == ["Tests pass"])
        #expect(SessionSummaryPolicy.parse(Data(blockers.utf8), isPartial: false)?.blockers == ["Waiting for review"])
    }

    @Test func outputByteLimitIsEnforced() {
        #expect(SessionSummaryPolicy.parse(Data(repeating: 0x20, count: 16 * 1024 + 1), isPartial: false) == nil)
    }

    @Test func negatedDestructiveDiscussionIsAllowed() {
        let json = #"{"goal":null,"completed":["Explained why deleting backups is unsafe"],"blockers":[],"next_action":"Do not delete the production database"}"#
        #expect(SessionSummaryPolicy.parse(Data(json.utf8), isPartial: false) != nil)
    }

    private func jsonString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x0A: result += "\\n"
            case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029:
                result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
