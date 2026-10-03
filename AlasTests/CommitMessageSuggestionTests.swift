import Foundation
import Testing
@testable import Alas

struct CommitMessageSuggestionTests {
    // MARK: Input shaping

    @Test(arguments: [
        ("Alas/Sources/App/AppState.swift", CommitMessageSuggestionPolicy.FilePriority.source),
        ("scripts/build.sh", .source),
        ("README.md", .docsOrConfig),
        ("project.yml", .docsOrConfig),
        (".gitignore", .docsOrConfig),
        ("Package.resolved", .noisy),
        ("web/yarn.lock", .noisy),
        ("Alas.xcodeproj/project.pbxproj", .noisy),
        ("Tests/__Snapshots__/view.png", .noisy),
        ("vendor/lib/thing.go", .noisy),
    ])
    func filesArePrioritizedSourceFirstAndNoiseLast(
        path: String, expected: CommitMessageSuggestionPolicy.FilePriority
    ) {
        #expect(CommitMessageSuggestionPolicy.priority(forPath: path) == expected)
    }

    @Test func budgetedDiffKeepsWholeHunksFromTheHighestPriorityFiles() {
        let firstHunk = Self.hunk("@@ -1,2 +1,2 @@", lines: 4)
        let secondHunk = Self.hunk("@@ -40,2 +40,2 @@", lines: 40)
        let diff = [
            Self.fileHeader("Package.resolved"), Self.hunk("@@ -1 +1 @@", lines: 2),
            Self.fileHeader("Sources/Sync.swift"), firstHunk, secondHunk,
        ].joined(separator: "\n") + "\n"
        let sourceHeader = Self.fileHeader("Sources/Sync.swift")
        // Room for the source file and its first hunk, not the second or the lockfile.
        let budget = sourceHeader.count + firstHunk.count + 2 + 10

        let shaped = CommitMessageSuggestionPolicy.budgetedDiff(diff, characterBudget: budget)

        #expect(shaped == sourceHeader + "\n" + firstHunk)
    }

    @Test func candidateLadderDegradesFromFullDiffToStatOnly() {
        let small = Self.fileHeader("Sources/Sync.swift") + "\n" + Self.hunk("@@ -1 +1 @@", lines: 20)
        let large = Self.fileHeader("Sources/Merge.swift") + "\n" + Self.hunk("@@ -1 +1 @@", lines: 1_000)
        let input = CommitMessageSuggestionInput(
            stat: " 2 files changed",
            diff: small + "\n" + large,
            branch: "nacho/42-offline-sync",
            ticketTitle: "Offline edits conflict",
            recentSubjects: []
        )

        let payloads = CommitMessageSuggestionPolicy.messageCandidates(for: input).map { $0.last?.content ?? "" }

        #expect(payloads.count == 3)
        #expect(payloads.allSatisfy { $0.contains("2 files changed") && $0.contains("Ticket: Offline edits conflict") })
        #expect(payloads[0].contains("Sources/Merge.swift") && payloads[0].contains("Sources/Sync.swift"))
        #expect(payloads[1].contains("Sources/Sync.swift") && !payloads[1].contains("Sources/Merge.swift"))
        #expect(!payloads[2].contains("Staged diff:"))
    }

    @Test(arguments: [
        (["feat(ui): add picker", "fix: crash", "docs: readme"], true),
        (["Add picker", "Fix crash", "feat: one-off"], false),
        (["feat: only one"], false),
    ])
    func conventionalCommitsAreDetectedFromRecentHistory(subjects: [String], expected: Bool) {
        #expect(CommitMessageSuggestionPolicy.usesConventionalCommits(subjects) == expected)
    }

    // MARK: Output contract

    @Test(arguments: [
        (#"{"subject": "Resolve offline sync conflicts on reconnect", "body": null}"#, false,
         CommitMessageSuggestion(subject: "Resolve offline sync conflicts on reconnect", body: nil)),
        (#"{"subject": "Fix crash", "body": "The cache was read before load. Version 1.2 is affected."}"#, false,
         CommitMessageSuggestion(subject: "Fix crash", body: "The cache was read before load. Version 1.2 is affected.")),
        (#"{"subject": "feat(sync): resolve conflicts on reconnect"}"#, true,
         CommitMessageSuggestion(subject: "feat(sync): resolve conflicts on reconnect", body: nil)),
        (#"{"subject": "Fix crash", "body": ""}"#, false, CommitMessageSuggestion(subject: "Fix crash", body: nil)),
    ])
    func acceptsAnImperativeSubjectAndShortBody(
        output: String, conventional: Bool, expected: CommitMessageSuggestion
    ) {
        #expect(CommitMessageSuggestionPolicy.parse(output, conventionalCommits: conventional) == expected)
    }

    @Test(arguments: [
        "Fix crash on reconnect",
        #"```json {"subject": "Fix crash on reconnect"} ```"#,
        #"{"subject": "feat: fix crash on reconnect"}"#,
        #"{"subject": "Fix crash on reconnect."}"#,
        #"{"subject": "Fix crash on reconnect (#42)"}"#,
        #"{"subject": "Fix ALAS-12 crash"}"#,
        #"{"subject": "Fixed crash on reconnect"}"#,
        #"{"subject": "Fix"}"#,
        #"{"subject": ""}"#,
        #"{"subject": "Fix crash\nand more"}"#,
        "{\"subject\": \"Fix \(String(repeating: "crash ", count: 15))\"}",
        #"{"subject": "Fix crash", "why": "because"}"#,
        #"{"subject": "Fix crash", "body": "One. Two. Three. Four."}"#,
        #"{"subject": "Fix crash", "body": "- first\n- second"}"#,
        #"{"subject": "Fix crash", "body": 3}"#,
        #"{"body": "Only a body."}"#,
    ])
    func rejectsAnythingElse(output: String) {
        #expect(CommitMessageSuggestionPolicy.parse(output, conventionalCommits: false) == nil)
    }

    @Test func conventionalRepositoriesRequireAPrefix() {
        let output = #"{"subject": "Fix crash on reconnect"}"#
        #expect(CommitMessageSuggestionPolicy.parse(output, conventionalCommits: true) == nil)
    }

    @Test func stagedPathsAreReadInPriorityTiers() {
        let nameStatus = [
            "M", "Package.resolved",
            "R087", "docs/old.md", "docs/new.md",
            "M", "Sources/Sync.swift",
            "A", "Sources/Merge.sw",
        ].joined(separator: "\0")

        let tiers = CommitMessageSuggestionPolicy.pathTiers(nameStatus: nameStatus, truncated: true)

        #expect(tiers == [["Sources/Sync.swift"], ["docs/old.md", "docs/new.md"], ["Package.resolved"]])
    }

    @Test func cappedDiffIsCutBackToTheLastCompleteHunk() {
        let complete = Self.fileHeader("Sources/Sync.swift") + "\n" + Self.hunk("@@ -1 +1 @@", lines: 3)
        let cut = complete + "\n" + Self.hunk("@@ -9 +9 @@", lines: 3).dropLast(4)

        #expect(CommitMessageSuggestionPolicy.droppingPartialTail(cut) == complete)
    }

    // MARK: Suggester

    @Test(arguments: [
        // Apple unavailable, Apple returned an invalid payload.
        (false, #"{"subject": "Apple subject wins"}"#, 0),
        (true, "not json", 1),
    ])
    @MainActor
    func invalidOrUnavailableAppleFallsThroughToMLX(
        appleAvailable: Bool, appleOutput: String, expectedAppleCalls: Int
    ) async {
        let apple = CannedAppleGenerator(output: appleOutput)
        let engine = CannedEngine(outcome: .success(#"{"subject": "Resolve sync conflicts"}"#))
        let suggester = CommitMessageSuggester(
            engine: engine,
            isAppleIntelligenceAvailable: { appleAvailable },
            generateWithAppleIntelligence: { request in await apple.generate(request) },
            isMLXAvailable: { true }
        )

        let suggestion = await suggester.suggest(for: Self.input)

        #expect(suggestion == .init(subject: "Resolve sync conflicts", body: nil))
        #expect(await apple.calls == expectedAppleCalls)
        #expect(await engine.calls == 1)
    }

    @Test(arguments: [true, false])
    @MainActor
    func revokedOrMissingAvailabilityYieldsNothing(revokedMidFlight: Bool) async {
        let availability = Availability()
        availability.isMLXAvailable = revokedMidFlight
        let engine = CannedEngine(outcome: .success(#"{"subject": "Resolve sync conflicts"}"#)) {
            await MainActor.run { availability.isMLXAvailable = false }
        }
        let suggester = CommitMessageSuggester(engine: engine) { availability.isMLXAvailable }

        #expect(await suggester.suggest(for: Self.input) == nil)
        #expect(await engine.calls == (revokedMidFlight ? 1 : 0))
    }

    // MARK: Field ownership

    @Test func userTextWinsOverALateSuggestion() throws {
        var state = CommitMessageSuggestionState()
        let idRequest = state.begin(indexKey: "a", subject: "", body: "")
        let id = try #require(idRequest)

        state.recordEdit(subject: "My own subject", body: "")
        let late = state.complete(id, suggestion: Self.suggestion, indexKey: "a", subject: "My own subject", body: "")
        let next = state.begin(indexKey: "b", subject: "My own subject", body: "")

        #expect(late == nil)
        #expect(next == nil)
        #expect(!state.isSuggesting)
    }

    @Test func suggestionForAStaleIndexIsDropped() throws {
        var state = CommitMessageSuggestionState()
        let idRequest = state.begin(indexKey: "a", subject: "", body: "")
        let id = try #require(idRequest)

        let result = state.complete(id, suggestion: Self.suggestion, indexKey: "b", subject: "", body: "")

        #expect(result == nil)
    }

    /// A refresh after restaging replaces the untouched draft, and a failed
    /// refresh withdraws it rather than leaving a message for other changes.
    @Test(arguments: [
        (CommitMessageSuggestion(subject: "Resolve conflicts and retry", body: nil) as CommitMessageSuggestion?,
         CommitMessageSuggestionState.Update.fill(.init(subject: "Resolve conflicts and retry", body: nil))),
        (nil, .clear),
    ])
    func untouchedSuggestionFollowsTheStagedIndex(
        refreshed: CommitMessageSuggestion?, expected: CommitMessageSuggestionState.Update
    ) throws {
        var state = CommitMessageSuggestionState()
        let firstRequest = state.begin(indexKey: "a", subject: "", body: "")
        let first = try #require(firstRequest)
        let completed = state.complete(first, suggestion: Self.suggestion, indexKey: "a", subject: "", body: "")
        #expect(completed == .fill(Self.suggestion))
        let (subject, body) = (Self.suggestion.subject, Self.suggestion.body ?? "")
        // Applying the suggestion echoes back through the field observers.
        state.recordEdit(subject: subject, body: body)

        let secondRequest = state.begin(indexKey: "b", subject: subject, body: body)
        let second = try #require(secondRequest)
        let result = state.complete(second, suggestion: refreshed, indexKey: "b", subject: subject, body: body)

        #expect(result == expected)
    }

    @Test func supersededRequestCannotApply() throws {
        var state = CommitMessageSuggestionState()
        let oldRequest = state.begin(indexKey: "a", subject: "", body: "")
        let old = try #require(oldRequest)
        _ = state.begin(indexKey: "a", subject: "", body: "")

        let result = state.complete(old, suggestion: Self.suggestion, indexKey: "a", subject: "", body: "")

        #expect(result == nil)
    }

    private static let suggestion = CommitMessageSuggestion(subject: "Resolve sync conflicts", body: "Retries now merge.")

    private static let input = CommitMessageSuggestionInput(
        stat: " Sources/Sync.swift | 2 +-", diff: "", branch: "main", ticketTitle: nil, recentSubjects: []
    )

    private static func fileHeader(_ path: String) -> String {
        "diff --git a/\(path) b/\(path)\nindex 111..222 100644\n--- a/\(path)\n+++ b/\(path)"
    }

    private static func hunk(_ header: String, lines: Int) -> String {
        ([header] + (0..<lines).map { "+line \($0)" }).joined(separator: "\n")
    }
}
