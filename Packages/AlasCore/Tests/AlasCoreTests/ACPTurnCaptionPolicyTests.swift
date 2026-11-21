import AlasCore
import Testing

struct ACPTurnCaptionPolicyTests {
    @Test(arguments: [
        ("Added retry to the upload client", "Added retry to the upload client"),
        ("  \"rendered alerts in the transcript.\"\n", "Rendered alerts in the transcript"),
        ("Fixed", nil),
        ("Updated `Foo.swift`", nil),
        ("Added one thing\nAnd another", nil),
        ("- Added a list", nil),
        ("See https://example.com for details", nil),
        (String(repeating: "word ", count: 20), nil),
    ] as [(String, String?)])
    func captionsAreOnePlainLineOfAFewWords(output: String, expected: String?) {
        #expect(ACPTurnCaptionPolicy.parse(output) == expected)
    }

    @Test func laterCandidatesKeepLessOfThePatches() {
        let input = ACPTurnCaptionPolicy.Input(
            request: "Make uploads retry",
            files: [.init(path: "Upload.swift", added: 3, removed: 1)],
            patches: [String(repeating: "+line\n", count: 2_000)])
        let prompts = ACPTurnCaptionPolicy.messageCandidates(for: input).map { $0[1].content }
        #expect(prompts.count == ACPTurnCaptionPolicy.patchCharacterBudgets.count)
        #expect(prompts.allSatisfy { $0.contains("Request:\nMake uploads retry") && $0.contains("Upload.swift +3 -1") })
        #expect(zip(prompts, prompts.dropFirst()).allSatisfy { $0.count > $1.count })
        #expect(!prompts[prompts.count - 1].contains("Patches:"))
    }

    @Test func aFileWriteBecomesOnlyItsChangedHunks() {
        let old = (1...500).map { "line \($0)" }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "line 250\n", with: "line 250 edited\n")
        let patch = ACPTurnCaptionPolicy.patch(path: "Big.swift", old: old, new: new)
        #expect(patch.hasPrefix("--- Big.swift\n@@"))
        #expect(patch.contains("\n-line 250\n+line 250 edited"))
        #expect(!patch.contains("line 1\n") && patch.count < 300)
    }
}
