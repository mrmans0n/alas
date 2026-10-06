import Foundation
import Testing
@testable import Alas

struct ChangeSummaryTests {
    @Test
    func smallBranchIsSentWholeWithoutDiffContents() throws {
        let facts = Self.facts(commits: 2, files: ["Sources/App.swift", "README.md"])

        let request = ChangeSummaryPolicy.request(for: facts)
        let payload = try Self.payload(request)

        #expect(request.coverage.isComplete)
        #expect(request.coverage.disclosure == nil)
        #expect(Set(payload.keys) == ["branch", "base", "commitCount", "fileCount", "commitSubjects", "files"])
        #expect((payload["commitSubjects"] as? [String])?.count == 2)
    }

    @Test
    func largeBranchFitsTheBudgetAndDisclosesWhatWasOmitted() throws {
        let paths = (0 ..< 400).map { "Sources/Module\($0)/File\($0).swift" } + ["package-lock.json"]
        let facts = Self.facts(commits: 150, files: ["yarn.lock"] + paths)

        let request = ChangeSummaryPolicy.request(for: facts)
        let user = try #require(request.messages.last?.content)
        let payload = try Self.payload(request)
        let files = try #require(payload["files"] as? [[String: Any]])
        let coverage = request.coverage

        #expect(user.utf8.count <= ChangeSummaryPolicy.payloadByteBudget)
        #expect(request.messages.reduce(0) { $0 + $1.content.utf8.count } <= ChangeSummaryPolicy.inputTokenLimit)
        #expect(payload["commitCount"] as? Int == 150)
        #expect(payload["fileCount"] as? Int == 402)
        #expect(coverage.commitsShown > 0 && coverage.commitsShown < 150)
        #expect(coverage.filesShown > 0 && coverage.filesShown < 402)
        #expect(files.count == coverage.filesShown)
        #expect(files.first?["path"] as? String == "Sources/Module0/File0.swift")
        #expect(coverage.disclosure == "Drafted from \(coverage.commitsShown) of 150 commits and \(coverage.filesShown) of 402 changed files; the rest were omitted.")
    }

    @Test
    func oversizedDescriptionsAndRefsStayWithinTheInputBudget() throws {
        let facts = Self.facts(
            branch: String(repeating: "🚀", count: 400),
            issueTitle: String(repeating: "\u{1}", count: 1_000),
            commitBody: String(repeating: "\u{1}", count: 1_000)
        )

        let request = ChangeSummaryPolicy.request(for: facts)
        let payload = try Self.payload(request)

        #expect(request.messages.reduce(0) { $0 + $1.content.utf8.count } <= ChangeSummaryPolicy.inputTokenLimit)
        #expect(payload["commitBody"] == nil)
        #expect(payload["issueTitle"] != nil)
        #expect(request.coverage.isComplete)
    }

    @Test
    func parseAcceptsOneBoundedParagraph() {
        let output = #" {"summary": " Adds a branch picker to the remote sheet and remembers the last choice. "} "#

        #expect(ChangeSummaryPolicy.parse(output, facts: Self.facts()) == "Adds a branch picker to the remote sheet and remembers the last choice.")
    }

    @Test(arguments: [
        #"{"summary": "Adds a picker.", "title": "Picker"}"#,
        #"{"summary": ""}"#,
        #"{"summary": "Adds a picker.\nIt remembers choices."}"#,
        #"{"summary": "- Adds a picker."}"#,
        #"{"summary": "One. Two. Three. Four."}"#,
        #"{"summary": "Adds a picker introduced in a1b2c3d."}"#,
        #"{"summary": "Adds a picker across 12 files."}"#,
        #"{"summary": "Adds a picker; the change was verified locally."}"#,
        #"{"summary": "Adds a picker and the build passes."}"#,
        #"{"summary": "Adds token ghp_abcdefghijklmnopqrstuvwxyz0123456789."}"#,
        "Adds a picker.",
    ])
    func parseRejectsOutputOutsideTheContract(output: String) {
        #expect(ChangeSummaryPolicy.parse(output, facts: Self.facts()) == nil)
    }

    /// Evidence is a test file plus an issue title; without it the branch
    /// only touches `Latest.swift`, whose name merely contains "test".
    @Test(arguments: [
        (#"{"summary": "Adds a picker and covers it with tests."}"#, false, false),
        (#"{"summary": "Adds a picker and covers it with tests."}"#, true, true),
        (#"{"summary": "Adds a picker because users lose their place."}"#, false, false),
        (#"{"summary": "Adds a picker because users lose their place."}"#, true, true),
        (#"{"summary": "Adds a picker, and the tests are passing."}"#, true, false),
        (#"{"summary": "Adds a picker; CI is green."}"#, true, false),
        (#"{"summary": "Adds a picker and the checks have passed."}"#, true, false),
    ])
    func testsAndMotivationNeedSupportingEvidence(output: String, withEvidence: Bool, accepted: Bool) {
        let facts = Self.facts(
            files: ["Sources/Latest.swift"] + (withEvidence ? ["Tests/PickerTests.swift"] : []),
            issueTitle: withEvidence ? "Users lose their place when switching branches" : nil
        )

        #expect((ChangeSummaryPolicy.parse(output, facts: facts) != nil) == accepted)
    }

    @Test(arguments: [
        ("Tests/Picker.swift", true),
        ("AlasTests/PickerTests.swift", true),
        ("pkg/picker_test.go", true),
        ("tests_helpers/test_picker.py", true),
        ("web/picker.spec.ts", true),
        ("Sources/Latest.swift", false),
        ("Sources/Contest/Attestation.swift", false),
    ])
    func testPathsFollowNamingConventions(path: String, isTest: Bool) {
        #expect(ChangeSummaryPolicy.isTestPath(path) == isTest)
    }

    @Test(arguments: [
        ("same", false),
        ("head", true),
        ("base", true),
        ("files", true),
        ("run", true),
        ("unloaded", true),
    ])
    func summaryGoesStaleWhenTheRepositoryStateChanges(change: String, stale: Bool) {
        let facts = Self.facts(runResults: [Self.run(.succeeded)])
        let draft = ChangeSummaryDraft(narrative: "Adds a picker.", facts: facts, coverage: ChangeSummaryPolicy.request(for: facts).coverage)
        let current: ChangeSummaryFacts? = switch change {
        case "head": Self.facts(headSHA: "ffffffffffffffffffffffffffffffffffffffff", runResults: [Self.run(.succeeded)])
        case "base": Self.facts(mergeBaseSHA: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", runResults: [Self.run(.succeeded)])
        case "files": Self.facts(files: ["Sources/App.swift"], runResults: [Self.run(.succeeded)])
        case "run": Self.facts(runResults: [Self.run(.failed(exitCode: 1))])
        case "unloaded": nil
        default: Self.facts(runResults: [Self.run(.succeeded)])
        }

        let phase = ChangeSummaryPhase.resolve(isSummarizing: false, draft: draft, currentFacts: current)

        #expect(phase == (stale ? .stale : .current(draft)))
    }

    @Test(arguments: [
        (Self.head, Self.mergeBase, true),
        (Self.head, "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", false),
        ("ffffffffffffffffffffffffffffffffffffffff", Self.mergeBase, false),
        (nil, Self.mergeBase, false),
    ] as [(String?, String?, Bool)])
    func copyRequiresTheRepositoryToStillMatchTheSummary(head: String?, mergeBase: String?, matches: Bool) {
        let facts = Self.facts()
        let draft = ChangeSummaryDraft(narrative: "Adds a picker.", facts: facts, coverage: ChangeSummaryPolicy.request(for: facts).coverage)

        #expect(draft.describes(headSHA: head, mergeBaseSHA: mergeBase) == matches)
    }

    @Test
    func copiedMarkdownKeepsFactsDeterministicAndDisclosesOmissions() {
        let facts = Self.facts(commits: 22, files: ["Sources/App.swift"], runResults: [Self.run(.failed(exitCode: 2))], uncommitted: true)
        let coverage = ChangeSummaryCoverage(commitsShown: 10, commitCount: 22, filesShown: 1, fileCount: 1)
        let draft = ChangeSummaryDraft(narrative: "Adds a picker.", facts: facts, coverage: coverage)

        let markdown = ChangeSummaryPolicy.markdown(for: draft, dateFormatter: { _ in "Oct 6, 14:02" })

        #expect(markdown == """
        ## Summary

        Adds a picker.

        _Drafted from 10 of 22 commits; the rest were omitted._

        ## Change facts

        - Range: `main...feature/picker` at `0123456` (merge base `abcdef0`)
        - Commits: 22
        - Files changed: 1 (+10 −2)
        - Latest run results in this worktree (not tied to a commit): `test` failed (exit 2) at Oct 6, 14:02
        - Uncommitted changes were present and are not included

        ### Commits

        \((0 ..< 20).map { "- `sha\($0)` Commit \($0)" }.joined(separator: "\n"))
        - …and 2 more commits not listed
        """)
    }

    // MARK: Fixtures

    static let head = "0123456789abcdef0123456789abcdef01234567"
    static let mergeBase = "abcdef0123456789abcdef0123456789abcdef01"

    static func facts(
        branch: String = "feature/picker",
        headSHA: String = head,
        mergeBaseSHA: String = mergeBase,
        commits: Int = 1,
        files: [String] = ["Sources/App.swift", "Sources/Picker.swift"],
        runResults: [ChangeSummaryFacts.RunResult] = [],
        issueTitle: String? = nil,
        commitBody: String? = nil,
        uncommitted: Bool = false
    ) -> ChangeSummaryFacts {
        ChangeSummaryFacts(
            base: "main",
            branch: branch,
            headSHA: headSHA,
            mergeBaseSHA: mergeBaseSHA,
            commits: (0 ..< commits).map { .init(sha: "sha\($0)full", shortSHA: "sha\($0)", subject: "Commit \($0)") },
            files: files.map { .init(path: $0, status: "M", additions: 10, deletions: 2) },
            runResults: runResults,
            issueTitle: issueTitle,
            commitBody: commitBody,
            hasUncommittedChanges: uncommitted
        )
    }

    static func run(_ outcome: RunOutcome) -> ChangeSummaryFacts.RunResult {
        .init(scriptName: "test", outcome: outcome, finishedAt: Date(timeIntervalSince1970: 1_000))
    }

    private static func payload(_ request: ChangeSummaryRequest) throws -> [String: Any] {
        let user = try #require(request.messages.first { $0.role == .user })
        return try #require(try JSONSerialization.jsonObject(with: Data(user.content.utf8)) as? [String: Any])
    }
}
