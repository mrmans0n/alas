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

        let commentsByFile = Dictionary(grouping: sortedActiveComments(), by: ReviewFeedbackFileContext.init(comment:))
        let sortedFiles = commentsByFile.keys.sorted()
        for fileContext in sortedFiles {
            guard let comments = commentsByFile[fileContext] else { continue }
            let path = fileContext.path
            lines.append("")
            lines.append("## \(fileContext.heading)")

            for comment in comments {
                let reference = fileContext.reference(for: comment)
                let bodyLines = markdownBodyLines(comment.bodyMarkdown)
                if bodyLines.count <= 1 {
                    let suffix = bodyLines.first.map { " — \($0)" } ?? ""
                    lines.append("- `\(reference)`\(suffix)")
                } else {
                    lines.append("- `\(reference)`")
                    lines.append(contentsOf: bodyLines)
                }

                if let selectedText = comment.selectedText {
                    let selectedTextForDisplay = selectedText.trimmingCharacters(in: .newlines)
                    if !selectedTextForDisplay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        for selectedLine in selectedTextForDisplay.components(separatedBy: .newlines) {
                            lines.append("> \(selectedLine)")
                        }
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

    private func markdownBodyLines(_ body: String) -> [String] {
        let trimmedBody = body.trimmingCharacters(in: .newlines)
        guard !trimmedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let lines = trimmedBody.components(separatedBy: .newlines)
        if lines.count == 1 {
            return [lines[0].trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        return lines
    }
}

private struct ReviewFeedbackFileContext: Hashable, Comparable {
    var path: String
    var namespace: String

    init(comment: ReviewDraftComment) {
        self.path = comment.path
        self.namespace = comment.fileID.namespace
    }

    var heading: String {
        guard shouldDisplayNamespace else { return path }
        return "\(path) [\(namespace)]"
    }

    func reference(for comment: ReviewDraftComment) -> String {
        let line = ReviewFeedbackFileContext.lineDescription(for: comment)
        guard shouldDisplayNamespace else {
            return "\(path):\(line) (\(comment.side.rawValue))"
        }
        return "\(path):\(line) (\(comment.side.rawValue), \(namespace))"
    }

    static func < (lhs: ReviewFeedbackFileContext, rhs: ReviewFeedbackFileContext) -> Bool {
        let pathOrder = lhs.path.localizedStandardCompare(rhs.path)
        if pathOrder != .orderedSame {
            return pathOrder == .orderedAscending
        }
        return lhs.namespace.localizedStandardCompare(rhs.namespace) == .orderedAscending
    }

    private var shouldDisplayNamespace: Bool {
        !namespace.isEmpty && namespace != "review"
    }

    private static func lineDescription(for comment: ReviewDraftComment) -> String {
        let range = comment.normalizedLineRange
        if range.lowerBound == range.upperBound {
            return "\(range.lowerBound)"
        }
        return "\(range.lowerBound)-\(range.upperBound)"
    }
}
