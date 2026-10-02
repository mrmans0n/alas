import Foundation
import Testing
@testable import Alas

struct WorktreeRowStatusTests {
    @Test func commitFallbackOnlyAppearsForCleanIdleBranches() {
        #expect(WorktreeRowView.showsCommitCount(harnessState: nil, worktreeStatus: .clean, isMain: false))
        #expect(!WorktreeRowView.showsCommitCount(harnessState: .running, worktreeStatus: .clean, isMain: false))
        #expect(!WorktreeRowView.showsCommitCount(harnessState: .awaiting, worktreeStatus: .clean, isMain: false))
        #expect(!WorktreeRowView.showsCommitCount(harnessState: nil, worktreeStatus: .unknown, isMain: false))
        #expect(!WorktreeRowView.showsCommitCount(harnessState: nil, worktreeStatus: .dirty(fileCount: 1, conflictCount: 0), isMain: false))
        #expect(!WorktreeRowView.showsCommitCount(harnessState: nil, worktreeStatus: .clean, isMain: true))
    }

    @Test func diffBarsHandleOneSidedAndEmptyChanges() {
        #expect(WorktreeRowView.diffBarAdditionCount(added: 0, deleted: 0) == nil)
        #expect(WorktreeRowView.diffBarAdditionCount(added: 0, deleted: 12) == 0)
        #expect(WorktreeRowView.diffBarAdditionCount(added: 12, deleted: 0) == 5)
        #expect(WorktreeRowView.diffBarAdditionCount(added: 86, deleted: 12) == 4)
        #expect(WorktreeRowView.diffBarAdditionCount(added: 1, deleted: 1000) == 1)
        #expect(WorktreeRowView.diffBarAdditionCount(added: 1000, deleted: 1) == 4)
    }

    @Test func runningSessionShowsPulsingGreenChip() throws {
        let status = try #require(WorktreeRowView.statusPresentation(
            harnessState: .running, worktreeStatus: .clean))
        #expect(status.note == "running")
        #expect(status.colorToken == "add")
        #expect(status.pulses)
    }

    @Test func awaitingSessionShowsAmberChipWithoutPulse() throws {
        let status = try #require(WorktreeRowView.statusPresentation(
            harnessState: .awaiting, worktreeStatus: .clean))
        #expect(status.note == "waiting")
        #expect(status.colorToken == "mod")
        #expect(!status.pulses)
    }

    @Test func cleanAndUnknownBothRenderNothing() {
        // Identical output, different meaning: `unknown` exists so the first
        // paint after launch does not assert every worktree is clean.
        #expect(WorktreeRowView.statusPresentation(
            harnessState: nil, worktreeStatus: .clean) == nil)
        #expect(WorktreeRowView.statusPresentation(
            harnessState: nil, worktreeStatus: .unknown) == nil)
    }

    @Test func dirtyWorktreeReportsItsFileCount() throws {
        let status = try #require(WorktreeRowView.statusPresentation(
            harnessState: nil, worktreeStatus: .dirty(fileCount: 3, conflictCount: 0)))
        #expect(status.note == "3 files")
        #expect(status.colorToken == "mod")
        #expect(!status.pulses)
    }

    @Test func singleDirtyFileIsSingular() throws {
        let status = try #require(WorktreeRowView.statusPresentation(
            harnessState: nil, worktreeStatus: .dirty(fileCount: 1, conflictCount: 0)))
        #expect(status.note == "1 file")
    }

    @Test func conflictsOutrankPlainDirt() throws {
        // A conflicted worktree is blocked, not merely modified.
        let status = try #require(WorktreeRowView.statusPresentation(
            harnessState: nil, worktreeStatus: .dirty(fileCount: 5, conflictCount: 2)))
        #expect(status.note == "2 conflicts")
        #expect(status.colorToken == "del")
    }

    @Test func singleConflictIsSingular() throws {
        let status = try #require(WorktreeRowView.statusPresentation(
            harnessState: nil, worktreeStatus: .dirty(fileCount: 1, conflictCount: 1)))
        #expect(status.note == "1 conflict")
    }

    @Test func harnessActivityOutranksDirt() throws {
        // One chip slot; an agent mid-flight is the more urgent fact.
        let status = try #require(WorktreeRowView.statusPresentation(
            harnessState: .running, worktreeStatus: .dirty(fileCount: 9, conflictCount: 3)))
        #expect(status.note == "running")
    }

    @Test func aChipAlwaysCarriesALabel() {
        let harnessStates: [HarnessService.AggregatedState?] = [.running, .awaiting, nil]
        let worktreeStates: [WorktreeDirtyState] = [
            .unknown, .clean,
            .dirty(fileCount: 1, conflictCount: 0),
            .dirty(fileCount: 4, conflictCount: 2)
        ]
        for harness in harnessStates {
            for worktree in worktreeStates {
                guard let status = WorktreeRowView.statusPresentation(
                    harnessState: harness, worktreeStatus: worktree) else { continue }
                #expect(!status.note.isEmpty)
            }
        }
    }

    @Test func commitQueryIdentityIgnoresRevision() {
        let base = WorktreeRowView.CommitQuery(
            path: URL(fileURLWithPath: "/repo/worktree"),
            branch: "feature",
            baseBranch: "main",
            preferLocal: false,
            revision: 1
        )
        let bumped = WorktreeRowView.CommitQuery(
            path: base.path,
            branch: base.branch,
            baseBranch: base.baseBranch,
            preferLocal: base.preferLocal,
            revision: 2
        )
        // A revision bump alone — e.g. an unrelated ref change elsewhere in
        // the project — must not read as a different subject, or an
        // already-loaded commit count would blink out while it refetches.
        #expect(base.identity == bumped.identity)

        let differentBranch = WorktreeRowView.CommitQuery(
            path: base.path,
            branch: "other",
            baseBranch: base.baseBranch,
            preferLocal: base.preferLocal,
            revision: 1
        )
        #expect(base.identity != differentBranch.identity)
    }

    @Test func zeroCommitsAreNotVisible() {
        #expect(!WorktreeRowView.hasVisibleCommits(nil))
        #expect(!WorktreeRowView.hasVisibleCommits(GitService.BranchCommitCount(count: 0, baseRef: "main")))
        #expect(WorktreeRowView.hasVisibleCommits(GitService.BranchCommitCount(count: 1, baseRef: "main")))
    }

    @Test func noStateEverProducesTheWordClean() {
        let harnessStates: [HarnessService.AggregatedState?] = [.running, .awaiting, nil]
        let worktreeStates: [WorktreeDirtyState] = [
            .unknown, .clean,
            .dirty(fileCount: 2, conflictCount: 0),
            .dirty(fileCount: 2, conflictCount: 1)
        ]
        for harness in harnessStates {
            for worktree in worktreeStates {
                let note = WorktreeRowView.statusPresentation(
                    harnessState: harness, worktreeStatus: worktree)?.note
                #expect(note?.localizedCaseInsensitiveContains("clean") != true)
            }
        }
    }
    @Test(arguments: [
        (#"{"explanation":"Fix sidebar shadow text"}"#, "Fix sidebar shadow text"),
        ("""
        ```json
        {"explanation":"Generate short worktree explanations"}
        ```
        """, "Generate short worktree explanations"),
    ])
    func acceptsBoundedWorktreeExplanation(output: String, expected: String) {
        #expect(WorktreeExplainerPolicy.parse(output) == expected)
    }

    @Test(arguments: [
        "null",
        #"{"explanation":null}"#,
        #"{"explanation":"null"}"#,
        #"{"explanation":"..."}"#,
        #"{"explanation":"Worktree for development"}"#,
        #"{"explanation":"one two"}"#,
        #"{"explanation":"one two three four five six seven eight nine"}"#,
        #"{"explanation":"This explanation is deliberately made much longer than sixty characters"}"#,
        #"{"explanation":"Fix sidebar text","extra":true}"#,
    ])
    func rejectsWorktreeExplanationAbstentionsPlaceholdersAndInvalidOutput(output: String) {
        #expect(WorktreeExplainerPolicy.parse(output) == nil)
    }

    @Test @MainActor
    func worktreeExplanationsAreDeduplicatedAndGeneratedSerially() async {
        let probe = WorktreeExplainerGenerationProbe()
        let store = WorktreeExplainerStore { await probe.generate($0) }
        let firstEvidence = WorktreeExplainerEvidence(branch: "fix-sidebar", issueTitle: nil)
        let secondEvidence = WorktreeExplainerEvidence(branch: "fix-shadow", issueTitle: "Shadow text is unreadable")

        let first = Task { await store.prepare(worktreeID: "first", evidence: firstEvidence) }
        let duplicate = Task { await store.prepare(worktreeID: "first", evidence: firstEvidence) }
        let second = Task { await store.prepare(worktreeID: "second", evidence: secondEvidence) }

        await probe.waitForCallCount(1)
        #expect(await probe.maximumConcurrentCalls == 1)
        await probe.finishNext(with: "Explain first worktree")
        await probe.waitForCallCount(2)
        #expect(await probe.maximumConcurrentCalls == 1)
        await probe.finishNext(with: "Explain second worktree")
        await first.value
        await duplicate.value
        await second.value

        #expect(await probe.receivedEvidence == [firstEvidence, secondEvidence])
        #expect(store.explanation(for: "first", evidence: firstEvidence) == "Explain first worktree")
        #expect(store.explanation(for: "first", evidence: secondEvidence) == nil)
        #expect(store.explanation(for: "second", evidence: secondEvidence) == "Explain second worktree")
    }

    @Test @MainActor
    func failedWorktreeExplanationCanRetry() async {
        let probe = WorktreeExplainerGenerationProbe()
        let store = WorktreeExplainerStore { await probe.generate($0) }
        let evidence = WorktreeExplainerEvidence(branch: "fix-sidebar", issueTitle: nil)

        let first = Task { await store.prepare(worktreeID: "worktree", evidence: evidence) }
        await probe.waitForCallCount(1)
        await probe.finishNext(with: nil)
        await first.value

        let retry = Task { await store.prepare(worktreeID: "worktree", evidence: evidence) }
        await probe.waitForCallCount(2)
        await probe.finishNext(with: "Explain retried worktree")
        await retry.value

        #expect(await probe.receivedEvidence == [evidence, evidence])
        #expect(store.explanation(for: "worktree", evidence: evidence) == "Explain retried worktree")
    }

    @Test @MainActor
    func cancellingPreparationCancelsActiveGeneration() async {
        let probe = WorktreeExplainerGenerationProbe()
        let store = WorktreeExplainerStore { await probe.generate($0) }
        let evidence = WorktreeExplainerEvidence(branch: "fix-sidebar", issueTitle: nil)

        let preparation = Task {
            await store.prepare(worktreeID: "worktree", evidence: evidence)
        }
        await probe.waitForCallCount(1)
        preparation.cancel()
        await probe.finishNext(with: nil)
        _ = await preparation.value

        #expect(await probe.cancelledCallCount == 1)
    }

    @Test func explanationUsesOnlyAResolvedEmptyMetadataSlot() {
        let available = WorktreeRowView.showsExplanation(
            isMain: false,
            hasOperation: false,
            hasWorkspaceCheckout: false,
            worktreeStatus: .clean,
            hasStatus: false,
            hasVisibleCommits: false,
            commitQueryResolved: true,
            hasDiff: false,
            hasStackStatus: false
        )
        #expect(available)
        #expect(!WorktreeRowView.showsExplanation(
            isMain: false,
            hasOperation: false,
            hasWorkspaceCheckout: false,
            worktreeStatus: .unknown,
            hasStatus: false,
            hasVisibleCommits: false,
            commitQueryResolved: true,
            hasDiff: false,
            hasStackStatus: false
        ))

        let blockers: [(Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool)] = [
            (true, false, false, false, false, true, false, false),
            (false, true, false, false, false, true, false, false),
            (false, false, true, false, false, true, false, false),
            (false, false, false, true, false, true, false, false),
            (false, false, false, false, true, true, false, false),
            (false, false, false, false, false, false, false, false),
            (false, false, false, false, false, true, true, false),
            (false, false, false, false, false, true, false, true),
        ]
        for blocker in blockers {
            #expect(!WorktreeRowView.showsExplanation(
                isMain: blocker.0,
                hasOperation: blocker.1,
                hasWorkspaceCheckout: blocker.2,
                worktreeStatus: .clean,
                hasStatus: blocker.3,
                hasVisibleCommits: blocker.4,
                commitQueryResolved: blocker.5,
                hasDiff: blocker.6,
                hasStackStatus: blocker.7
            ))
        }
    }

}

private actor WorktreeExplainerGenerationProbe {
    private(set) var receivedEvidence: [WorktreeExplainerEvidence] = []
    private(set) var cancelledCallCount = 0
    private(set) var maximumConcurrentCalls = 0
    private var activeCalls = 0
    private var completions: [CheckedContinuation<String?, Never>] = []
    private var callCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func generate(_ evidence: WorktreeExplainerEvidence) async -> String? {
        receivedEvidence.append(evidence)
        activeCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
        resumeCallCountWaiters()
        let result = await withCheckedContinuation { completions.append($0) }
        activeCalls -= 1
        if Task.isCancelled { cancelledCallCount += 1 }
        return result
    }

    func waitForCallCount(_ count: Int) async {
        if receivedEvidence.count >= count { return }
        await withCheckedContinuation { callCountWaiters.append((count, $0)) }
    }

    func finishNext(with result: String?) {
        completions.removeFirst().resume(returning: result)
    }

    private func resumeCallCountWaiters() {
        let ready = callCountWaiters.filter { receivedEvidence.count >= $0.0 }
        callCountWaiters.removeAll { receivedEvidence.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}
