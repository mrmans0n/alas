import Foundation
import Observation

@Observable
@MainActor
final class ReviewEvidenceModel {
    let snapshot: ReviewLoopSnapshot
    private let provider: any CodeHostProvider
    private let cwd: URL
    private let initialSection: ReviewEvidenceSection?
    private var detailRequestID = 0

    private(set) var ciItems: [ReviewEvidenceItem] = []
    private(set) var feedbackItems: [ReviewEvidenceItem] = []
    private(set) var fileSession: DiffReviewLoadedSession?
    private(set) var selectedSection: ReviewEvidenceSection
    private(set) var selectedItemID: String?
    private(set) var selectedDetail: ReviewEvidenceDetail?
    private(set) var isLoadingList = false
    private(set) var isLoadingFiles = false
    private(set) var isLoadingDetail = false
    private(set) var errorMessage: String?
    private(set) var fileErrorMessage: String?

    var selectedItem: ReviewEvidenceItem? {
        guard let selectedItemID else { return nil }
        return items(for: selectedSection).first { $0.id == selectedItemID }
    }

    init(
        snapshot: ReviewLoopSnapshot,
        provider: any CodeHostProvider,
        cwd: URL,
        initialSection: ReviewEvidenceSection?,
        initialItemID: String? = nil
    ) {
        self.snapshot = snapshot
        self.provider = provider
        self.cwd = cwd
        self.initialSection = initialSection
        self.selectedSection = initialSection ?? .files
        self.selectedItemID = initialItemID
    }

    func load() async {
        guard let remote = snapshot.remote, let request = snapshot.reviewRequest else {
            isLoadingList = false
            isLoadingFiles = false
            errorMessage = "Review request not found."
            return
        }

        isLoadingList = true
        isLoadingFiles = true
        errorMessage = nil
        fileErrorMessage = nil

        async let files: Void = loadAndPublishFiles(remote: remote, request: request)
        async let evidence: Void = loadAndPublishEvidence(remote: remote, request: request)
        _ = await (files, evidence)
    }

    func select(itemID: String, section: ReviewEvidenceSection) {
        detailRequestID += 1
        selectedSection = section
        selectedItemID = itemID
        selectedDetail = nil
        isLoadingDetail = false
    }

    func select(section: ReviewEvidenceSection) {
        detailRequestID += 1
        selectedSection = section
        selectedItemID = nil
        selectedDetail = nil
        isLoadingDetail = false
    }

    func loadSelectedDetail() async {
        guard selectedSection != .files else {
            selectedDetail = nil
            isLoadingDetail = false
            return
        }

        guard let remote = snapshot.remote, let request = snapshot.reviewRequest else {
            errorMessage = "Review request not found."
            return
        }
        guard let item = selectedItem else {
            selectedDetail = nil
            return
        }

        detailRequestID += 1
        let requestID = detailRequestID
        let requestedItemID = item.id
        let requestedSection = item.section
        isLoadingDetail = true
        errorMessage = nil

        do {
            let detail: ReviewEvidenceDetail
            switch item.section {
            case .files:
                selectedDetail = nil
                isLoadingDetail = false
                return
            case .ci:
                detail = try await provider.checkEvidenceDetail(
                    remote: remote,
                    request: request,
                    item: item,
                    cwd: cwd
                )
            case .feedback:
                detail = try await provider.feedbackEvidenceDetail(
                    remote: remote,
                    request: request,
                    item: item,
                    cwd: cwd
                )
            }
            guard requestID == detailRequestID,
                  selectedItemID == requestedItemID,
                  selectedSection == requestedSection
            else { return }
            selectedDetail = detail
        } catch {
            guard requestID == detailRequestID,
                  selectedItemID == requestedItemID,
                  selectedSection == requestedSection
            else { return }
            errorMessage = error.localizedDescription
            selectedDetail = ReviewEvidenceDetail(
                item: item,
                body: error.localizedDescription,
                filePath: nil,
                line: nil,
                isTruncated: false
            )
        }
        isLoadingDetail = false
    }

    func items(for section: ReviewEvidenceSection) -> [ReviewEvidenceItem] {
        switch section {
        case .files:
            []
        case .ci:
            ciItems
        case .feedback:
            feedbackItems
        }
    }

    func showSelectedDetailError(_ message: String) {
        guard let item = selectedItem else {
            errorMessage = message
            return
        }
        errorMessage = message
        let existingBody = selectedDetail?.body
        let body: String
        if let existingBody, !existingBody.isEmpty {
            body = "\(message)\n\n\(existingBody)"
        } else {
            body = message
        }
        selectedDetail = ReviewEvidenceDetail(
            item: item,
            body: body,
            filePath: selectedDetail?.filePath,
            line: selectedDetail?.line,
            isTruncated: selectedDetail?.isTruncated ?? false
        )
    }

    private func chooseInitialSelection() {
        if let selectedItemID, items(for: selectedSection).contains(where: { $0.id == selectedItemID }) {
            return
        }

        if initialSection == nil || initialSection == .files {
            selectedSection = .files
            selectedItemID = nil
            selectedDetail = nil
        } else if initialSection == .feedback, let item = feedbackItems.first {
            select(itemID: item.id, section: .feedback)
        } else if let item = ciItems.first {
            select(itemID: item.id, section: .ci)
        } else if let item = feedbackItems.first {
            select(itemID: item.id, section: .feedback)
        } else {
            selectedItemID = nil
            selectedDetail = nil
        }
    }

    private func publishFiles(_ result: LoadResult<DiffReviewLoadedSession>) {
        switch result {
        case .success(let loadedFiles):
            fileSession = loadedFiles
        case .failure(let error):
            fileSession = nil
            fileErrorMessage = error.localizedDescription
        }
        isLoadingFiles = false
    }

    private func loadAndPublishFiles(remote: CodeHostRemote, request: ReviewRequest) async {
        let result = await Self.loadFiles(provider: provider, remote: remote, request: request, cwd: cwd)
        publishFiles(result)
    }

    private func publishEvidence(_ result: LoadResult<([ReviewEvidenceItem], [ReviewEvidenceItem])>) {
        switch result {
        case .success(let loadedEvidence):
            let (loadedCI, loadedFeedback) = loadedEvidence
            ciItems = loadedCI
            feedbackItems = loadedFeedback
            chooseInitialSelection()
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
        isLoadingList = false
    }

    private func loadAndPublishEvidence(remote: CodeHostRemote, request: ReviewRequest) async {
        let result = await Self.loadEvidence(provider: provider, remote: remote, request: request, cwd: cwd)
        publishEvidence(result)
    }

    private nonisolated static func loadFiles(
        provider: any CodeHostProvider,
        remote: CodeHostRemote,
        request: ReviewRequest,
        cwd: URL
    ) async -> LoadResult<DiffReviewLoadedSession> {
        do {
            let session = try await ReviewRequestDiffLoader(provider: provider).load(
                remote: remote,
                request: request,
                cwd: cwd
            )
            return .success(session)
        } catch {
            return .failure(error)
        }
    }

    private nonisolated static func loadEvidence(
        provider: any CodeHostProvider,
        remote: CodeHostRemote,
        request: ReviewRequest,
        cwd: URL
    ) async -> LoadResult<([ReviewEvidenceItem], [ReviewEvidenceItem])> {
        do {
            async let ci = provider.failedCheckEvidence(remote: remote, request: request, cwd: cwd)
            async let feedback = provider.feedbackEvidence(remote: remote, request: request, cwd: cwd)
            let loadedEvidence = try await (ci, feedback)
            return .success(loadedEvidence)
        } catch {
            return .failure(error)
        }
    }
}

private enum LoadResult<Value> {
    case success(Value)
    case failure(any Error)
}
