import Foundation
import Testing
@testable import Alas

struct RunFailureBriefPolicyTests {
    private static let valid = #"{"summary": " The Net test run failed to compile. ", "cause": "Bar.swift calls baz, which is not defined.", "checks": ["Whether baz was renamed in Sources/Baz.swift."]}"#

    @Test(arguments: [valid, "```json\n\(valid)\n```"])
    func parseAcceptsAStrictBriefOptionallyInsideAJSONFence(output: String) {
        #expect(RunFailureBriefPolicy.parse(output) == RunFailureBrief(
            summary: "The Net test run failed to compile.",
            cause: "Bar.swift calls baz, which is not defined.",
            checks: ["Whether baz was renamed in Sources/Baz.swift."]
        ))
    }

    @Test(arguments: [
        #"{"summary": "s", "cause": "c"}"#,
        #"{"summary": "s", "cause": "c", "checks": ["k"], "fix": "edit Bar.swift"}"#,
        #"{"summary": "s", "cause": "c", "checks": []}"#,
        #"{"summary": "s", "cause": "c", "checks": ["a", "b", "c", "d"]}"#,
        #"{"summary": "s", "cause": "c", "checks": [3]}"#,
        #"{"summary": "first\nsecond", "cause": "c", "checks": ["k"]}"#,
        #"{"summary": "s", "cause": "password = hunter22", "checks": ["k"]}"#,
        #"{"summary": "s", "cause": "c", "checks": ["Run swift build again."]}"#,
        #"{"summary": "s", "cause": "c", "checks": ["Look at it, then rerun the script."]}"#,
        #"{"summary": "s", "cause": "c", "checks": ["Whether git reset --hard helps."]}"#,
        #"{"summary": "s", "cause": "You should install Xcode.", "checks": ["k"]}"#,
        #"{"summary": "s", "cause": "c", "checks": ["Try running swift test."]}"#,
        #"{"summary": "s", "cause": "c", "checks": ["To verify, run swift test."]}"#,
        #"{"summary": "s", "cause": "Next, install Xcode.", "checks": ["k"]}"#,
        #"{"summary": "s", "cause": "c", "checks": ["First run swift test."]}"#,
        #"{"summary": "s", "cause": "c", "checks": ["Remove logs containing secrets."]}"#,
        #"{"summary": "s", "cause": "c", "checks": ["Kill job 123."]}"#,
        #"{"summary": "s", "cause": "c", "checks": ["Run scripts with verbose logging."]}"#,
        #"{"summary": "s", "cause": "c", "checks": ["You can check by running swift test."]}"#,
        #"{"summary": "s", "cause": "c", "checks": ["Verify by running swift test."]}"#,
        #"{"summary": "s", "cause": "The fix is to reinstall the SDK.", "checks": ["k"]}"#,
        "The Net tests failed to compile.",
        "",
    ])
    func parseRejectsOutputThatIsNotAStrictAdvisoryBrief(output: String) {
        #expect(RunFailureBriefPolicy.parse(output) == nil)
    }

    @Test(arguments: [
        "Running the tests failed because the SDK is missing.",
        "Installing dependencies failed with a checksum mismatch.",
        "The parser hit Unexpected token: punc in app.js.",
        "Run script failed because the SDK is missing.",
        "Commit failed because the hook rejected it.",
        "The first run failed after the SDK update.",
        "The tests could not run because the simulator is missing.",
    ])
    func parseKeepsDescriptiveTextThatOnlyResemblesActionsOrSecrets(cause: String) {
        let output = #"{"summary": "s", "cause": "\#(cause)", "checks": ["k"]}"#

        #expect(RunFailureBriefPolicy.parse(output)?.cause == cause)
    }

    @Test
    func parseRejectsOverlongFields() {
        let long = String(repeating: "a", count: RunFailureBriefPolicy.maximumFieldLength + 1)
        #expect(RunFailureBriefPolicy.parse(#"{"summary": "\#(long)", "cause": "c", "checks": ["k"]}"#) == nil)
    }

    @Test
    func requestCarriesOnlyScriptExitCodeAndNumberedExcerpt() throws {
        let input = Self.input(lines: [(3, "error: cannot find 'baz'"), (4, "    baz()")])

        let payload = try Self.payload(RunFailureBriefPolicy.messageCandidates(for: input)[0])

        #expect(Set(payload.keys) == ["script", "exitCode", "excerpt", "truncated"])
        #expect(payload["script"] as? String == "Test")
        #expect(payload["exitCode"] as? Int == 65)
        #expect(payload["excerpt"] as? String == "3: error: cannot find 'baz'\n4:     baz()")
        #expect(payload["truncated"] as? Bool == false)
    }

    @Test
    func largeExcerptsDegradeToACandidateThatKeepsTheFinalLinesWithinBudget() throws {
        let lines = (1...40).map { ($0, "error: " + String(repeating: "x", count: 390)) }
        let input = Self.input(lines: lines)

        let smallest = try #require(RunFailureBriefPolicy.messageCandidates(for: input).last)
        let payload = try Self.payload(smallest)

        #expect(smallest.reduce(0) { $0 + $1.content.utf8.count } <= RunFailureBriefPolicy.inputTokenLimit)
        #expect((payload["excerpt"] as? String)?.hasPrefix("40: ") == true)
        #expect(payload["truncated"] as? Bool == true)
    }

    private static func input(lines: [(Int, String)]) -> RunFailureBriefInput {
        RunFailureBriefInput(
            scriptName: "Test",
            exitCode: 65,
            excerpt: FailureLogExcerpt(
                lines: lines.map { .init(number: $0.0, text: $0.1) },
                matchedErrors: true,
                truncated: false
            )
        )
    }

    private static func payload(_ messages: [LocalTextMessage]) throws -> [String: Any] {
        let user = try #require(messages.first { $0.role == .user })
        return try #require(try JSONSerialization.jsonObject(with: Data(user.content.utf8)) as? [String: Any])
    }
}
