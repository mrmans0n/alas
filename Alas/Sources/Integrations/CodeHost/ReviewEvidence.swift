import Foundation

enum ReviewEvidenceSection: String, Codable, Equatable, Sendable, CaseIterable {
    case ci
    case feedback

    var displayName: String {
        switch self {
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
