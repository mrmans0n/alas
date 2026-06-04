import Foundation
import Testing
@testable import Alas

@MainActor
struct ReviewEvidenceModelTests {
    @Test func genericInspectSelectsFailedCIBeforeFeedback() async {
        let recorder = EvidenceProviderRecorder()
        let model = ReviewEvidenceModel(
            snapshot: Self.snapshot(),
            provider: FakeCodeHostProvider(recorder: recorder),
            cwd: URL(fileURLWithPath: "/tmp/alas"),
            initialSection: nil
        )

        await model.load()

        #expect(model.selectedSection == .ci)
        #expect(model.selectedItem?.id == "ci:test")
        #expect(model.ciItems.count == 1)
        #expect(model.feedbackItems.count == 1)
        let counts = await recorder.detailCounts()
        #expect(counts.ci == 0)
        #expect(counts.feedback == 0)
    }

    @Test func loadingDetailPreservesSelectionAndStoresDetail() async {
        let model = ReviewEvidenceModel(
            snapshot: Self.snapshot(),
            provider: FakeCodeHostProvider(),
            cwd: URL(fileURLWithPath: "/tmp/alas"),
            initialSection: .feedback
        )

        await model.load()
        #expect(model.selectedSection == .feedback)
        #expect(model.selectedItem?.id == "feedback:thread-1")
        await model.loadSelectedDetail()

        #expect(model.selectedSection == .feedback)
        #expect(model.selectedDetail?.body == "Please simplify this.")
    }

    @Test func staleDetailResponseDoesNotOverwriteCurrentSelection() async {
        let provider = SuspendedDetailProvider()
        let model = ReviewEvidenceModel(
            snapshot: Self.snapshot(),
            provider: provider,
            cwd: URL(fileURLWithPath: "/tmp/alas"),
            initialSection: nil
        )

        await model.load()
        let task = Task { await model.loadSelectedDetail() }
        await provider.waitForCIDetailCall()

        model.select(itemID: "feedback:thread-1", section: .feedback)
        await provider.completeCIDetail()
        await task.value

        #expect(model.selectedSection == .feedback)
        #expect(model.selectedDetail == nil)
        #expect(!model.isLoadingDetail)
    }

    private static func snapshot() -> ReviewLoopSnapshot {
        let remote = CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "mrmans0n",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/mrmans0n/alas")!
        )
        let request = ReviewRequest(
            remote: remote,
            number: 428,
            title: "Review loop",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/428")!,
            state: .open,
            isDraft: false,
            headRefName: "feature/review-loop",
            baseRefName: "main",
            reviewDecision: .changesRequested,
            mergeState: .blocked,
            checks: [],
            threads: []
        )

        return ReviewLoopSnapshot(
            local: ReviewLoopLocalState(
                branchName: "feature/review-loop",
                headSHA: "abc",
                baseBranch: "main",
                hasWorkingTreeChanges: false,
                hasStagedChanges: false,
                aheadCommitCount: 2,
                hasUpstream: true,
                needsPush: false
            ),
            remote: remote,
            reviewRequest: request,
            providerAvailable: true,
            providerAuthenticated: true,
            providerCapabilities: .githubCLI,
            errorMessage: nil
        )
    }
}

private actor EvidenceProviderRecorder {
    private var ciDetailCalls = 0
    private var feedbackDetailCalls = 0

    func recordCIDetail() {
        ciDetailCalls += 1
    }

    func recordFeedbackDetail() {
        feedbackDetailCalls += 1
    }

    func detailCounts() -> (ci: Int, feedback: Int) {
        (ciDetailCalls, feedbackDetailCalls)
    }
}

private struct FakeCodeHostProvider: CodeHostProvider {
    let recorder: EvidenceProviderRecorder?

    init(recorder: EvidenceProviderRecorder? = nil) {
        self.recorder = recorder
    }

    var kind: CodeHostKind { .github }
    var capabilities: CodeHostProviderCapabilities { .githubCLI }

    func isAvailable() async -> Bool { true }

    func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool { true }

    func currentReviewRequest(
        remote: CodeHostRemote,
        branch: String,
        headOwner: String?,
        baseBranch: String,
        cwd: URL
    ) async throws -> ReviewRequest? {
        nil
    }

    func createReviewRequest(
        remote: CodeHostRemote,
        branch: String,
        headOwner: String?,
        baseBranch: String,
        title: String,
        body: String,
        isDraft: Bool,
        cwd: URL
    ) async throws -> URL {
        URL(string: "https://github.com/mrmans0n/alas/pull/428")!
    }

    func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] {
        []
    }

    func failedCheckEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem] {
        [
            ReviewEvidenceItem(
                id: "ci:test",
                section: .ci,
                title: "Tests",
                subtitle: "CI",
                status: .failed,
                providerURL: URL(string: "https://github.com/run")
            ),
        ]
    }

    func checkEvidenceDetail(
        remote: CodeHostRemote,
        request: ReviewRequest,
        item: ReviewEvidenceItem,
        cwd: URL
    ) async throws -> ReviewEvidenceDetail {
        await recorder?.recordCIDetail()
        return ReviewEvidenceDetail(
            item: item,
            body: "Assertion failed in Tests.swift",
            filePath: nil,
            line: nil,
            isTruncated: false
        )
    }

    func feedbackEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem] {
        [
            ReviewEvidenceItem(
                id: "feedback:thread-1",
                section: .feedback,
                title: "reviewer",
                subtitle: "Please simplify this.",
                status: .actionable,
                providerURL: URL(string: "https://github.com/discussion")
            ),
        ]
    }

    func feedbackEvidenceDetail(
        remote: CodeHostRemote,
        request: ReviewRequest,
        item: ReviewEvidenceItem,
        cwd: URL
    ) async throws -> ReviewEvidenceDetail {
        await recorder?.recordFeedbackDetail()
        return ReviewEvidenceDetail(
            item: item,
            body: "Please simplify this.",
            filePath: nil,
            line: nil,
            isTruncated: false
        )
    }

    func rerunFailedChecks(
        remote: CodeHostRemote,
        branch: String,
        headSHA: String,
        request: ReviewRequest?,
        cwd: URL
    ) async throws {}
}

private actor SuspendedDetailProvider: CodeHostProvider {
    nonisolated let kind: CodeHostKind = .github
    nonisolated let capabilities: CodeHostProviderCapabilities = .githubCLI

    private var ciDetailContinuation: CheckedContinuation<ReviewEvidenceDetail, Never>?
    private var ciDetailWaiters: [CheckedContinuation<Void, Never>] = []
    private var didCallCIDetail = false

    func waitForCIDetailCall() async {
        if didCallCIDetail { return }
        await withCheckedContinuation { continuation in
            ciDetailWaiters.append(continuation)
        }
    }

    func completeCIDetail() {
        ciDetailContinuation?.resume(returning: ReviewEvidenceDetail(
            item: Self.makeCIItem(),
            body: "Late CI detail",
            filePath: nil,
            line: nil,
            isTruncated: false
        ))
        ciDetailContinuation = nil
    }

    func isAvailable() async -> Bool { true }
    func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool { true }
    func currentReviewRequest(remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String, cwd: URL) async throws -> ReviewRequest? { nil }
    func createReviewRequest(remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String, title: String, body: String, isDraft: Bool, cwd: URL) async throws -> URL { remote.webURL }
    func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] { [] }

    func failedCheckEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem] {
        [Self.makeCIItem()]
    }

    func checkEvidenceDetail(remote: CodeHostRemote, request: ReviewRequest, item: ReviewEvidenceItem, cwd: URL) async throws -> ReviewEvidenceDetail {
        didCallCIDetail = true
        for waiter in ciDetailWaiters {
            waiter.resume()
        }
        ciDetailWaiters.removeAll()
        return await withCheckedContinuation { continuation in
            ciDetailContinuation = continuation
        }
    }

    func feedbackEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem] {
        [Self.makeFeedbackItem()]
    }

    func feedbackEvidenceDetail(remote: CodeHostRemote, request: ReviewRequest, item: ReviewEvidenceItem, cwd: URL) async throws -> ReviewEvidenceDetail {
        ReviewEvidenceDetail(item: item, body: "Feedback detail", filePath: nil, line: nil, isTruncated: false)
    }

    func rerunFailedChecks(remote: CodeHostRemote, branch: String, headSHA: String, request: ReviewRequest?, cwd: URL) async throws {}

    private nonisolated static func makeCIItem() -> ReviewEvidenceItem {
        ReviewEvidenceItem(
            id: "ci:test",
            section: .ci,
            title: "Tests",
            subtitle: "CI",
            status: .failed,
            providerURL: URL(string: "https://github.com/run")
        )
    }

    private nonisolated static func makeFeedbackItem() -> ReviewEvidenceItem {
        ReviewEvidenceItem(
            id: "feedback:thread-1",
            section: .feedback,
            title: "reviewer",
            subtitle: "Please simplify this.",
            status: .actionable,
            providerURL: URL(string: "https://github.com/discussion")
        )
    }
}
