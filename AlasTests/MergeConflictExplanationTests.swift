import Foundation
import Testing
@testable import Alas

struct MergeConflictExplanationTests {
    @Test
    func parseAcceptsAnExplanationCitingTheRequestedConflict() {
        let output = #"{"conflict": 2, "cause": " Both sides edit the retry limit. ", "local": "Raise it to 5.", "remote": "Make it configurable."}"#

        let explanation = MergeConflictExplanationPolicy.parse(output, conflictNumber: 2)

        #expect(explanation == MergeConflictExplanation(
            cause: "Both sides edit the retry limit.",
            localIntent: "Raise it to 5.",
            remoteIntent: "Make it configurable."
        ))
    }

    @Test(arguments: [
        #"{"conflict": 3, "cause": "c", "local": "l", "remote": "r"}"#,
        #"{"conflict": "2", "cause": "c", "local": "l", "remote": "r"}"#,
        #"{"cause": "c", "local": "l", "remote": "r"}"#,
        #"{"conflict": 2, "cause": "c", "local": "l", "remote": "r", "resolution": "take local"}"#,
        #"{"conflict": 2, "cause": " ", "local": "l", "remote": "r"}"#,
        #"{"conflict": 2, "cause": "c", "local": "first\nsecond", "remote": "r"}"#,
        #"{"conflict": 2, "cause": "c", "local": "password = hunter22", "remote": "r"}"#,
        "Both sides edit the retry limit.",
        "",
    ])
    func parseRejectsOutputThatIsNotAStrictSingleHunkExplanation(output: String) {
        #expect(MergeConflictExplanationPolicy.parse(output, conflictNumber: 2) == nil)
    }

    @Test
    func parseRejectsOverlongFields() {
        let long = String(repeating: "a", count: MergeConflictExplanationPolicy.maximumFieldLength + 1)
        let output = #"{"conflict": 2, "cause": "\#(long)", "local": "l", "remote": "r"}"#

        #expect(MergeConflictExplanationPolicy.parse(output, conflictNumber: 2) == nil)
    }

    @Test
    func requestCarriesOnlyTheSelectedHunkAndFileMetadata() throws {
        let input = Self.input(local: "let retries = 5\n", base: "let retries = 3\n", remote: "let retries = config.retries\n")

        let candidates = MergeConflictExplanationPolicy.messageCandidates(for: input)
        let payload = try Self.payload(candidates[0])

        #expect(Set(payload.keys) == ["path", "language", "conflict", "conflictCount", "lines", "local", "base", "remote"])
        #expect(payload["path"] as? String == "Sources/Net/Client.swift")
        #expect(payload["language"] as? String == "swift")
        #expect(payload["conflict"] as? Int == 2)
        #expect(payload["conflictCount"] as? Int == 5)
        #expect(payload["lines"] as? String == "40-52")
        let local = try #require(payload["local"] as? [String: Any])
        #expect(local["label"] as? String == "HEAD")
        #expect(local["text"] as? String == "let retries = 5\n")
        #expect(local["truncated"] as? Bool == false)
        #expect((payload["base"] as? [String: Any])?["text"] as? String == "let retries = 3\n")
        #expect((payload["remote"] as? [String: Any])?["label"] as? String == "feature")
    }

    @Test
    func oversizedHunksDegradeToACandidateWithinTheInputBudget() throws {
        let huge = String(repeating: "x", count: 50_000)
        let input = Self.input(local: huge, base: huge, remote: huge)

        let candidates = MergeConflictExplanationPolicy.messageCandidates(for: input)
        let smallest = try #require(candidates.last)
        let bytes = smallest.reduce(0) { $0 + $1.content.utf8.count }
        let local = try #require(try Self.payload(smallest)["local"] as? [String: Any])

        #expect(bytes <= MergeConflictExplanationPolicy.inputTokenLimit)
        #expect(local["truncated"] as? Bool == true)
    }

    @Test @MainActor
    func invalidAppleOutputFallsBackToAUserInitiatedMLXExplanation() async {
        let engine = RecordingExplanationEngine(
            text: #"{"conflict": 2, "cause": "Both edit retries.", "local": "Raise it.", "remote": "Configure it."}"#
        )
        let explainer = MergeConflictExplainer(
            engine: engine,
            isAppleIntelligenceAvailable: { true },
            generateWithAppleIntelligence: { _ in "LOCAL raises it; REMOTE configures it." },
            isMLXAvailable: { true }
        )

        let explanation = await explainer.explain(Self.input(local: "a\n", base: nil, remote: "b\n"))

        #expect(explanation?.cause == "Both edit retries.")
        #expect(await engine.requests == [.init(caller: .mergeConflictExplanation, priority: .userInitiated)])
    }

    static func input(local: String, base: String?, remote: String) -> MergeConflictExplanationInput {
        MergeConflictExplanationInput(
            path: "Sources/Net/Client.swift",
            conflictNumber: 2,
            conflictCount: 5,
            block: ConflictBlock(
                local: local,
                base: base,
                remote: remote,
                localLabel: "HEAD",
                remoteLabel: "feature",
                lineRangeInMerged: 39...51
            )
        )
    }

    private static func payload(_ messages: [LocalTextMessage]) throws -> [String: Any] {
        let user = try #require(messages.first { $0.role == .user })
        return try #require(try JSONSerialization.jsonObject(with: Data(user.content.utf8)) as? [String: Any])
    }
}

actor RecordingExplanationEngine: LocalTextGenerating {
    struct Request: Equatable {
        let caller: LocalTextCaller
        let priority: LocalTextJobPriority
    }

    let text: String
    private(set) var requests: [Request] = []

    init(text: String) {
        self.text = text
    }

    func generate(_ request: LocalTextGenerationRequest, caller: LocalTextCaller,
                  priority: LocalTextJobPriority) async throws -> LocalTextGenerationResult {
        requests.append(.init(caller: caller, priority: priority))
        return .init(text: text, selectedCandidateIndex: 0)
    }

    func cancel(caller: LocalTextCaller) async {}
    func cancelAndUnload() async {}
}
