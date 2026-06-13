import Foundation

enum ReviewEvidenceSection: String, Codable, Equatable, Sendable, CaseIterable {
    case files
    case ci
    case feedback

    var displayName: String {
        switch self {
        case .files: "Files"
        case .ci: "CI"
        case .feedback: "Feedback"
        }
    }
}

enum ReviewEvidenceStatus: String, Codable, Equatable, Sendable {
    case failed
    case pending
    case passed
    case cancelled
    case actionable
    case resolved
    case unknown

    var isBlocking: Bool {
        switch self {
        case .failed, .actionable:
            true
        case .pending, .passed, .cancelled, .resolved, .unknown:
            false
        }
    }
}

struct ReviewEvidenceItem: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let section: ReviewEvidenceSection
    let title: String
    let subtitle: String?
    let status: ReviewEvidenceStatus
    let providerURL: URL?
}

struct ReviewEvidenceDetail: Codable, Equatable, Sendable {
    let item: ReviewEvidenceItem
    let body: String
    let filePath: String?
    let line: Int?
    let isTruncated: Bool

    static func truncated(
        item: ReviewEvidenceItem,
        body: String,
        filePath: String?,
        line: Int?,
        maxLength: Int = 8_000
    ) -> ReviewEvidenceDetail {
        guard body.count > maxLength else {
            return ReviewEvidenceDetail(item: item, body: body, filePath: filePath, line: line, isTruncated: false)
        }

        let marker = "\n\n[Log truncated by Alas.]"
        guard maxLength > marker.count else {
            return ReviewEvidenceDetail(
                item: item,
                body: String(marker.prefix(max(0, maxLength))),
                filePath: filePath,
                line: line,
                isTruncated: true
            )
        }

        let prefixLength = max(0, maxLength - marker.count)
        return ReviewEvidenceDetail(
            item: item,
            body: String(body.prefix(prefixLength)) + marker,
            filePath: filePath,
            line: line,
            isTruncated: true
        )
    }
}

enum ReviewEvidenceFallbacks {
    static let changesRequestedID = "review-decision:changes-requested"

    static func changesRequestedItem(request: ReviewRequest) -> ReviewEvidenceItem {
        ReviewEvidenceItem(
            id: changesRequestedID,
            section: .feedback,
            title: "Changes requested",
            subtitle: "No unresolved review thread summaries were loaded.",
            status: .actionable,
            providerURL: request.url
        )
    }

    static func changesRequestedDetail(item: ReviewEvidenceItem, request: ReviewRequest) -> ReviewEvidenceDetail {
        ReviewEvidenceDetail(
            item: item,
            body: """
            The \(request.provider.reviewRequestLabel) review decision is changes requested, but Alas did not load any unresolved review thread summaries for this request.

            Open the \(request.provider.reviewRequestLabel) in \(request.provider.displayName) to inspect the full review, or send this context to an agent with the review request URL.
            """,
            filePath: nil,
            line: nil,
            isTruncated: false
        )
    }
}

enum ReviewEvidenceInlineFeedbackMapper {
    static func feedbackByFileID(
        threads: [ReviewThreadSummary],
        files: [DiffReviewFileSummary],
        providerName: String
    ) -> [DiffReviewFileID: [DiffReviewInlineFeedback]] {
        var grouped: [DiffReviewFileID: [DiffReviewInlineFeedback]] = [:]
        let fileMatcher = InlineFeedbackFileMatcher(files: files)

        for thread in threads where !thread.isResolved && thread.isActionable {
            guard let location = thread.location,
                  let file = fileMatcher.file(for: location)
            else { continue }

            let side = DiffReviewInlineFeedbackSide(location.side)
            let anchorPath = anchorPath(for: location, matchedFile: file)
            let feedback = DiffReviewInlineFeedback(
                id: thread.id,
                providerName: providerName,
                author: thread.author,
                bodyPreview: String(thread.body.prefix(240)),
                status: .actionable,
                providerURL: thread.url,
                anchor: DiffReviewInlineFeedbackAnchor(
                    path: anchorPath,
                    line: location.line,
                    side: side
                ),
                evidenceItemID: thread.id
            )
            grouped[file.id, default: []].append(feedback)
        }

        return grouped.mapValues { feedback in
            feedback.sorted { lhs, rhs in
                switch (lhs.anchor.line, rhs.anchor.line) {
                case (nil, nil):
                    return lhs.id < rhs.id
                case (nil, _?):
                    return true
                case (_?, nil):
                    return false
                case (let lhsLine?, let rhsLine?):
                    if lhsLine != rhsLine {
                        return lhsLine < rhsLine
                    }
                    return lhs.id < rhs.id
                }
            }
        }
    }

    private static func anchorPath(for location: ReviewThreadLocation, matchedFile file: DiffReviewFileSummary) -> String {
        switch location.side {
        case .old:
            location.originalPath ?? file.originalPath ?? location.path
        case .new, .unknown:
            location.path
        }
    }
}

private struct InlineFeedbackFileMatcher {
    private let filesByPath: [String: DiffReviewFileSummary]
    private let filesByOriginalPath: [String: DiffReviewFileSummary]

    init(files: [DiffReviewFileSummary]) {
        self.filesByPath = Self.uniqueFiles(files, keyedBy: \.path)
        self.filesByOriginalPath = Self.uniqueFiles(files.compactMap { file in
            file.originalPath == nil ? nil : file
        }, keyedBy: \.originalPath)
    }

    func file(for location: ReviewThreadLocation) -> DiffReviewFileSummary? {
        switch location.side {
        case .new:
            filesByPath[location.path] ?? location.originalPath.flatMap { filesByOriginalPath[$0] } ?? filesByOriginalPath[location.path]
        case .unknown:
            filesByPath[location.path] ?? location.originalPath.flatMap { filesByOriginalPath[$0] } ?? filesByOriginalPath[location.path]
        case .old:
            fileForOldSide(location)
        }
    }

    private func fileForOldSide(_ location: ReviewThreadLocation) -> DiffReviewFileSummary? {
        if let originalPath = location.originalPath,
           let file = filesByOriginalPath[originalPath] {
            return file
        }
        if let exactCurrentPathMatch = filesByPath[location.path] {
            return exactCurrentPathMatch
        }
        return filesByOriginalPath[location.path]
    }

    private static func uniqueFiles(
        _ files: [DiffReviewFileSummary],
        keyedBy keyPath: KeyPath<DiffReviewFileSummary, String>
    ) -> [String: DiffReviewFileSummary] {
        uniqueFiles(files) { $0[keyPath: keyPath] }
    }

    private static func uniqueFiles(
        _ files: [DiffReviewFileSummary],
        keyedBy keyPath: KeyPath<DiffReviewFileSummary, String?>
    ) -> [String: DiffReviewFileSummary] {
        uniqueFiles(files) { $0[keyPath: keyPath] }
    }

    private static func uniqueFiles(
        _ files: [DiffReviewFileSummary],
        key: (DiffReviewFileSummary) -> String?
    ) -> [String: DiffReviewFileSummary] {
        var result: [String: DiffReviewFileSummary] = [:]
        var duplicateKeys: Set<String> = []

        for file in files {
            guard let key = key(file), !key.isEmpty else { continue }
            if result[key] != nil {
                result[key] = nil
                duplicateKeys.insert(key)
            } else if !duplicateKeys.contains(key) {
                result[key] = file
            }
        }

        return result
    }
}

private extension DiffReviewInlineFeedbackSide {
    init(_ side: ReviewThreadSide) {
        switch side {
        case .old:
            self = .old
        case .new:
            self = .new
        case .unknown:
            self = .unknown
        }
    }
}

enum ReviewEvidenceContextFormatter {
    static func format(_ detail: ReviewEvidenceDetail) -> String {
        var lines: [String] = [
            "Section: \(detail.item.section.displayName)",
            "Title: \(detail.item.title)",
            "Status: \(detail.item.status.rawValue)",
        ]

        if let subtitle = detail.item.subtitle, !subtitle.isEmpty {
            lines.append("Source: \(subtitle)")
        }
        if let url = detail.item.providerURL {
            lines.append("URL: \(url.absoluteString)")
        }
        if let filePath = detail.filePath {
            if let line = detail.line {
                lines.append("Location: \(filePath):\(line)")
            } else {
                lines.append("Location: \(filePath)")
            }
        }
        if detail.isTruncated {
            lines.append("Truncated: true")
        }

        lines.append("")
        lines.append(detail.body)
        return lines.joined(separator: "\n")
    }
}
