import Foundation
import Testing
@testable import Alas

@MainActor
struct ReviewEvidenceModelTests {
    @Test func defaultLoadSelectsFilesAndLoadsEvidenceWithoutDetailCalls() async {
        let recorder = EvidenceProviderRecorder()
        let model = ReviewEvidenceModel(
            snapshot: Self.snapshot(),
            provider: FakeCodeHostProvider(recorder: recorder),
            cwd: URL(fileURLWithPath: "/tmp/alas"),
            initialSection: nil
        )

        await model.load()

        #expect(model.selectedSection == .files)
        #expect(model.selectedItem == nil)
        #expect(model.fileSession?.files.map(\.summary.path) == ["Sources/App.swift"])
        #expect(model.ciItems.count == 1)
        #expect(model.feedbackItems.count == 1)
        let counts = await recorder.detailCounts()
        #expect(counts.ci == 0)
        #expect(counts.feedback == 0)
    }

    @Test func fileLoaderFailureLeavesEvidenceLoadedAndSetsFileError() async {
        let model = ReviewEvidenceModel(
            snapshot: Self.snapshot(),
            provider: FakeCodeHostProvider(diffError: TestError(message: "diff unavailable")),
            cwd: URL(fileURLWithPath: "/tmp/alas"),
            initialSection: nil
        )

        await model.load()

        #expect(model.fileSession == nil)
        #expect(model.fileErrorMessage == "diff unavailable")
        #expect(model.errorMessage == nil)
        #expect(model.ciItems.map(\.id) == ["ci:test"])
        #expect(model.feedbackItems.map(\.id) == ["feedback:thread-1"])
    }

    @Test func evidenceFailureLeavesLoadedFileSessionAndSetsError() async {
        let model = ReviewEvidenceModel(
            snapshot: Self.snapshot(),
            provider: FakeCodeHostProvider(ciError: TestError(message: "checks unavailable")),
            cwd: URL(fileURLWithPath: "/tmp/alas"),
            initialSection: nil
        )

        await model.load()

        #expect(model.fileSession?.files.map(\.summary.path) == ["Sources/App.swift"])
        #expect(model.fileErrorMessage == nil)
        #expect(model.errorMessage == "checks unavailable")
        #expect(model.ciItems.isEmpty)
        #expect(model.feedbackItems.isEmpty)
    }

    @Test func loadedFilesKeepBrowserAvailableWhenEvidenceFails() async {
        let model = ReviewEvidenceModel(
            snapshot: Self.snapshot(),
            provider: FakeCodeHostProvider(ciError: TestError(message: "checks unavailable")),
            cwd: URL(fileURLWithPath: "/tmp/alas"),
            initialSection: nil
        )

        await model.load()

        #expect(model.fileSession != nil)
        #expect(model.errorMessage == "checks unavailable")
        #expect(!ReviewEvidenceTabView.shouldShowModelUnavailable(model))
    }

    @Test func missingReviewRequestKeepsBrowserUnavailable() async {
        let model = ReviewEvidenceModel(
            snapshot: Self.snapshot(reviewRequest: nil),
            provider: FakeCodeHostProvider(),
            cwd: URL(fileURLWithPath: "/tmp/alas"),
            initialSection: nil
        )

        await model.load()

        #expect(model.errorMessage == "Review request not found.")
        #expect(ReviewEvidenceTabView.shouldShowModelUnavailable(model))
    }

    @Test func evidencePublishesWhileFileLoadIsSuspended() async {
        let provider = SuspendedLoadProvider(suspendDiff: true)
        let model = ReviewEvidenceModel(
            snapshot: Self.snapshot(),
            provider: provider,
            cwd: URL(fileURLWithPath: "/tmp/alas"),
            initialSection: nil
        )

        let task = Task { await model.load() }
        await provider.waitForDiffCall()
        await provider.waitForEvidenceCalls()

        #expect(await Self.waitUntil { !model.ciItems.isEmpty && !model.feedbackItems.isEmpty })
        #expect(model.ciItems.map(\.id) == ["ci:test"])
        #expect(model.feedbackItems.map(\.id) == ["feedback:thread-1"])
        #expect(!model.isLoadingList)
        #expect(model.fileSession == nil)
        #expect(model.isLoadingFiles)

        await provider.completeDiff()
        await task.value
    }

    @Test func filesPublishWhileEvidenceLoadIsSuspended() async {
        let provider = SuspendedLoadProvider(suspendEvidence: true)
        let model = ReviewEvidenceModel(
            snapshot: Self.snapshot(),
            provider: provider,
            cwd: URL(fileURLWithPath: "/tmp/alas"),
            initialSection: nil
        )

        let task = Task { await model.load() }
        await provider.waitForEvidenceCalls()
        await provider.waitForDiffCall()

        #expect(await Self.waitUntil { model.fileSession != nil })
        #expect(model.fileSession?.files.map(\.summary.path) == ["Sources/App.swift"])
        #expect(!model.isLoadingFiles)
        #expect(model.ciItems.isEmpty)
        #expect(model.feedbackItems.isEmpty)
        #expect(model.isLoadingList)

        await provider.completeEvidence()
        await task.value
    }

    @Test func loadingSelectedDetailForFilesClearsDetailWithoutProviderCalls() async {
        let recorder = EvidenceProviderRecorder()
        let model = ReviewEvidenceModel(
            snapshot: Self.snapshot(),
            provider: FakeCodeHostProvider(recorder: recorder),
            cwd: URL(fileURLWithPath: "/tmp/alas"),
            initialSection: nil
        )

        await model.load()
        await model.loadSelectedDetail()

        #expect(model.selectedSection == .files)
        #expect(model.selectedDetail == nil)
        #expect(!model.isLoadingDetail)
        let counts = await recorder.detailCounts()
        #expect(counts.ci == 0)
        #expect(counts.feedback == 0)
    }

    @Test func selectingFilesCancelsSuspendedDetailLoad() async {
        let provider = SuspendedDetailProvider()
        let model = ReviewEvidenceModel(
            snapshot: Self.snapshot(),
            provider: provider,
            cwd: URL(fileURLWithPath: "/tmp/alas"),
            initialSection: .ci
        )

        await model.load()
        let task = Task { await model.loadSelectedDetail() }
        await provider.waitForCIDetailCall()

        model.select(section: .files)
        await provider.completeCIDetail()
        await task.value

        #expect(model.selectedSection == .files)
        #expect(model.selectedItemID == nil)
        #expect(model.selectedDetail == nil)
        #expect(!model.isLoadingDetail)
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

    @Test func loadRestoresPersistedSelectedItemWhenStillPresent() async {
        let model = ReviewEvidenceModel(
            snapshot: Self.snapshot(),
            provider: FakeCodeHostProvider(feedbackItems: [
                Self.feedbackItem(id: "feedback:thread-1", title: "reviewer", body: "First comment."),
                Self.feedbackItem(id: "feedback:thread-2", title: "maintainer", body: "Second comment."),
            ]),
            cwd: URL(fileURLWithPath: "/tmp/alas"),
            initialSection: .feedback,
            initialItemID: "feedback:thread-2"
        )

        await model.load()

        #expect(model.selectedSection == .feedback)
        #expect(model.selectedItem?.id == "feedback:thread-2")
    }

    @Test func selectedDetailErrorPreservesSelectedItem() async {
        let model = ReviewEvidenceModel(
            snapshot: Self.snapshot(),
            provider: FakeCodeHostProvider(),
            cwd: URL(fileURLWithPath: "/tmp/alas"),
            initialSection: .ci
        )

        await model.load()
        await model.loadSelectedDetail()
        model.showSelectedDetailError("Rerun failed: permission denied")

        #expect(model.selectedSection == .ci)
        #expect(model.selectedItem?.id == "ci:test")
        #expect(model.selectedDetail?.item.id == "ci:test")
        #expect(model.selectedDetail?.body.contains("Rerun failed: permission denied") == true)
        #expect(model.selectedDetail?.body.contains("Assertion failed in Tests.swift") == true)
    }

    @Test func staleDetailResponseDoesNotOverwriteCurrentSelection() async {
        let provider = SuspendedDetailProvider()
        let model = ReviewEvidenceModel(
            snapshot: Self.snapshot(),
            provider: provider,
            cwd: URL(fileURLWithPath: "/tmp/alas"),
            initialSection: .ci
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

    @Test func modelReportsMissingReviewRequest() async {
        let model = ReviewEvidenceModel(
            snapshot: Self.snapshot(reviewRequest: nil),
            provider: FakeCodeHostProvider(),
            cwd: URL(fileURLWithPath: "/tmp/alas"),
            initialSection: nil
        )

        await model.load()

        #expect(model.errorMessage == "Review request not found.")
        #expect(model.fileSession == nil)
        #expect(model.ciItems.isEmpty)
        #expect(model.feedbackItems.isEmpty)
    }

    private static func snapshot() -> ReviewLoopSnapshot {
        snapshot(reviewRequest: Self.reviewRequest())
    }

    private static func snapshot(reviewRequest: ReviewRequest?) -> ReviewLoopSnapshot {
        let remote = Self.remote()

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
            reviewRequest: reviewRequest,
            providerAvailable: true,
            providerAuthenticated: true,
            providerCapabilities: .githubCLI,
            errorMessage: nil
        )
    }

    private static func remote() -> CodeHostRemote {
        CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "mrmans0n",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/mrmans0n/alas")!
        )
    }

    private static func reviewRequest() -> ReviewRequest {
        let remote = Self.remote()
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
        return request
    }

    private static func feedbackItem(id: String, title: String, body: String) -> ReviewEvidenceItem {
        ReviewEvidenceItem(
            id: id,
            section: .feedback,
            title: title,
            subtitle: body,
            status: .actionable,
            providerURL: URL(string: "https://github.com/discussion/\(id)")
        )
    }

    private static func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<50 {
            if predicate() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
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

private struct TestError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private struct FakeCodeHostProvider: CodeHostProvider {
    let recorder: EvidenceProviderRecorder?
    let ciItems: [ReviewEvidenceItem]
    let feedbackItems: [ReviewEvidenceItem]
    let diff: String
    let diffError: TestError?
    let ciError: TestError?
    let feedbackError: TestError?

    init(
        recorder: EvidenceProviderRecorder? = nil,
        ciItems: [ReviewEvidenceItem] = [
            ReviewEvidenceItem(
                id: "ci:test",
                section: .ci,
                title: "Tests",
                subtitle: "CI",
                status: .failed,
                providerURL: URL(string: "https://github.com/run")
            ),
        ],
        feedbackItems: [ReviewEvidenceItem] = [
            ReviewEvidenceItem(
                id: "feedback:thread-1",
                section: .feedback,
                title: "reviewer",
                subtitle: "Please simplify this.",
                status: .actionable,
                providerURL: URL(string: "https://github.com/discussion")
            ),
        ],
        diff: String = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 111..222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1 +1 @@
        -let old = true
        +let new = true
        """,
        diffError: TestError? = nil,
        ciError: TestError? = nil,
        feedbackError: TestError? = nil
    ) {
        self.recorder = recorder
        self.ciItems = ciItems
        self.feedbackItems = feedbackItems
        self.diff = diff
        self.diffError = diffError
        self.ciError = ciError
        self.feedbackError = feedbackError
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

    func reviewDiff(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> String {
        if let diffError {
            throw diffError
        }
        return diff
    }

    func failedCheckEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem] {
        if let ciError {
            throw ciError
        }
        return ciItems
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
        if let feedbackError {
            throw feedbackError
        }
        return feedbackItems
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

private actor SuspendedLoadProvider: CodeHostProvider {
    nonisolated let kind: CodeHostKind = .github
    nonisolated let capabilities: CodeHostProviderCapabilities = .githubCLI

    private let suspendDiff: Bool
    private let suspendEvidence: Bool
    private var diffContinuation: CheckedContinuation<String, Never>?
    private var ciContinuation: CheckedContinuation<[ReviewEvidenceItem], Never>?
    private var feedbackContinuation: CheckedContinuation<[ReviewEvidenceItem], Never>?
    private var diffWaiters: [CheckedContinuation<Void, Never>] = []
    private var evidenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var didCallDiff = false
    private var didCallCI = false
    private var didCallFeedback = false

    init(suspendDiff: Bool = false, suspendEvidence: Bool = false) {
        self.suspendDiff = suspendDiff
        self.suspendEvidence = suspendEvidence
    }

    func waitForDiffCall() async {
        if didCallDiff { return }
        await withCheckedContinuation { continuation in
            diffWaiters.append(continuation)
        }
    }

    func waitForEvidenceCalls() async {
        if didCallCI && didCallFeedback { return }
        await withCheckedContinuation { continuation in
            evidenceWaiters.append(continuation)
        }
    }

    func completeDiff() {
        diffContinuation?.resume(returning: Self.diff)
        diffContinuation = nil
    }

    func completeEvidence() {
        ciContinuation?.resume(returning: [Self.makeCIItem()])
        ciContinuation = nil
        feedbackContinuation?.resume(returning: [Self.makeFeedbackItem()])
        feedbackContinuation = nil
    }

    func isAvailable() async -> Bool { true }
    func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool { true }
    func currentReviewRequest(remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String, cwd: URL) async throws -> ReviewRequest? { nil }
    func createReviewRequest(remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String, title: String, body: String, isDraft: Bool, cwd: URL) async throws -> URL { remote.webURL }
    func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] { [] }

    func reviewDiff(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> String {
        didCallDiff = true
        resumeDiffWaiters()
        guard suspendDiff else { return Self.diff }
        return await withCheckedContinuation { continuation in
            diffContinuation = continuation
        }
    }

    func failedCheckEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem] {
        didCallCI = true
        resumeEvidenceWaitersIfReady()
        guard suspendEvidence else { return [Self.makeCIItem()] }
        return await withCheckedContinuation { continuation in
            ciContinuation = continuation
        }
    }

    func feedbackEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem] {
        didCallFeedback = true
        resumeEvidenceWaitersIfReady()
        guard suspendEvidence else { return [Self.makeFeedbackItem()] }
        return await withCheckedContinuation { continuation in
            feedbackContinuation = continuation
        }
    }

    func checkEvidenceDetail(remote: CodeHostRemote, request: ReviewRequest, item: ReviewEvidenceItem, cwd: URL) async throws -> ReviewEvidenceDetail {
        ReviewEvidenceDetail(item: item, body: "CI detail", filePath: nil, line: nil, isTruncated: false)
    }

    func feedbackEvidenceDetail(remote: CodeHostRemote, request: ReviewRequest, item: ReviewEvidenceItem, cwd: URL) async throws -> ReviewEvidenceDetail {
        ReviewEvidenceDetail(item: item, body: "Feedback detail", filePath: nil, line: nil, isTruncated: false)
    }

    func rerunFailedChecks(remote: CodeHostRemote, branch: String, headSHA: String, request: ReviewRequest?, cwd: URL) async throws {}

    private func resumeDiffWaiters() {
        for waiter in diffWaiters {
            waiter.resume()
        }
        diffWaiters.removeAll()
    }

    private func resumeEvidenceWaitersIfReady() {
        guard didCallCI && didCallFeedback else { return }
        for waiter in evidenceWaiters {
            waiter.resume()
        }
        evidenceWaiters.removeAll()
    }

    private nonisolated static let diff = """
    diff --git a/Sources/App.swift b/Sources/App.swift
    index 111..222 100644
    --- a/Sources/App.swift
    +++ b/Sources/App.swift
    @@ -1 +1 @@
    -let old = true
    +let new = true
    """

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

    func reviewDiff(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> String {
        """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 111..222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1 +1 @@
        -let old = true
        +let new = true
        """
    }

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
