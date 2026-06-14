import Foundation

struct ReviewFeedbackTarget: Equatable, Sendable {
    var title: String
    var repositoryPath: String?
    var providerDescription: String?
    var sourceDescription: String
}

struct ReviewFeedbackBundle: Equatable, Sendable {
    var target: ReviewFeedbackTarget
    var comments: [ReviewDraftComment]

    var activeComments: [ReviewDraftComment] {
        comments.filter(\.isActive)
    }

    func promptMarkdown() -> String {
        var lines: [String] = [
            "Please address each review comment below.",
            "",
            "Inspect the referenced files and make the smallest safe changes. Explain what changed. Do not publish remote review comments unless explicitly asked.",
            "",
            "Review target: \(target.title)",
        ]

        if let repositoryPath = target.repositoryPath, !repositoryPath.isEmpty {
            lines.append("Repository: \(repositoryPath)")
        }

        lines.append("Source: \(target.sourceDescription)")

        if let providerDescription = target.providerDescription, !providerDescription.isEmpty {
            lines.append("Provider: \(providerDescription)")
        }

        let commentsByPath = Dictionary(grouping: sortedActiveComments(), by: \.path)
        for path in commentsByPath.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            guard let comments = commentsByPath[path] else { continue }
            lines.append("")
            lines.append("## \(path)")

            for comment in comments {
                lines.append("- `\(path):\(lineDescription(for: comment)) (\(comment.side.rawValue))` — \(singleLineBody(comment.bodyMarkdown))")

                if let selectedText = comment.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !selectedText.isEmpty {
                    for selectedLine in selectedText.components(separatedBy: .newlines) {
                        lines.append("> \(selectedLine)")
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func sortedActiveComments() -> [ReviewDraftComment] {
        activeComments.sorted { lhs, rhs in
            if lhs.path != rhs.path {
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            if lhs.normalizedLineRange.lowerBound != rhs.normalizedLineRange.lowerBound {
                return lhs.normalizedLineRange.lowerBound < rhs.normalizedLineRange.lowerBound
            }
            if lhs.normalizedLineRange.upperBound != rhs.normalizedLineRange.upperBound {
                return lhs.normalizedLineRange.upperBound < rhs.normalizedLineRange.upperBound
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    private func lineDescription(for comment: ReviewDraftComment) -> String {
        let range = comment.normalizedLineRange
        if range.lowerBound == range.upperBound {
            return "\(range.lowerBound)"
        }
        return "\(range.lowerBound)-\(range.upperBound)"
    }

    private func singleLineBody(_ body: String) -> String {
        body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
