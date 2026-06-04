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
    private(set) var selectedSection: ReviewEvidenceSection
    private(set) var selectedItemID: String?
    private(set) var selectedDetail: ReviewEvidenceDetail?
    private(set) var isLoadingList = false
    private(set) var isLoadingDetail = false
    private(set) var errorMessage: String?

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
        self.selectedSection = initialSection ?? .ci
        self.selectedItemID = initialItemID
    }

    func load() async {
        guard let remote = snapshot.remote, let request = snapshot.reviewRequest else {
            errorMessage = "Review request not found."
            return
        }

        isLoadingList = true
        errorMessage = nil

        do {
            async let ci = provider.failedCheckEvidence(remote: remote, request: request, cwd: cwd)
            async let feedback = provider.feedbackEvidence(remote: remote, request: request, cwd: cwd)
            let (loadedCI, loadedFeedback) = try await (ci, feedback)
            ciItems = loadedCI
            feedbackItems = loadedFeedback
            chooseInitialSelection()
            isLoadingList = false
        } catch {
            isLoadingList = false
            errorMessage = error.localizedDescription
        }
    }

    func select(itemID: String, section: ReviewEvidenceSection) {
        detailRequestID += 1
        selectedSection = section
        selectedItemID = itemID
        selectedDetail = nil
        isLoadingDetail = false
    }

    func loadSelectedDetail() async {
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

        if initialSection == .feedback, let item = feedbackItems.first {
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
}
