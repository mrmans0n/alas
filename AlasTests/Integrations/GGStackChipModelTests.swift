import Testing
@testable import Alas

struct GGStackChipModelTests {
    private func entry(
        prNumber: Int? = 840,
        prState: GGPRState? = .open,
        approved: Bool = false
    ) -> GGStackEntry {
        GGStackEntry(
            position: 1, sha: "abc1234", title: "t",
            prNumber: prNumber, prState: prState, approved: approved
        )
    }

    @Test func noChipWithoutPRNumber() {
        #expect(GGStackChipModel.model(for: entry(prNumber: nil), kind: .github) == nil)
    }

    @Test func githubUsesHashPrefixGitlabUsesBang() {
        #expect(GGStackChipModel.model(for: entry(), kind: .github)?.label == "#840")
        #expect(GGStackChipModel.model(for: entry(), kind: .gitlab)?.label == "!840")
        #expect(GGStackChipModel.model(for: entry(), kind: nil)?.label == "#840")
    }

    @Test func approvedAddsCheckmark() {
        #expect(GGStackChipModel.model(for: entry(approved: true), kind: .github)?.label == "#840 ✓")
    }

    @Test func stateMapsToColorToken() {
        #expect(GGStackChipModel.model(for: entry(prState: .open), kind: .github)?.colorToken == "add")
        #expect(GGStackChipModel.model(for: entry(prState: .merged), kind: .github)?.colorToken == "accent")
        #expect(GGStackChipModel.model(for: entry(prState: .draft), kind: .github)?.colorToken == "fg-muted")
        #expect(GGStackChipModel.model(for: entry(prState: .closed), kind: .github)?.colorToken == "del")
        #expect(GGStackChipModel.model(for: entry(prState: nil), kind: .github)?.colorToken == "fg-faint")
    }
}
