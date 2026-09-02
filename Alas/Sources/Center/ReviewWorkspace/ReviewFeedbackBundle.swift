import Foundation

struct ReviewFeedbackTarget: Equatable, Sendable {
    var title: String
    var repositoryPath: String?
    var providerDescription: String?
    var sourceDescription: String
    var sessionDescription: String? = nil
    var revisionDescription: String? = nil
    var priorHandoffDescription: String? = nil
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

        if let sessionDescription = target.sessionDescription, !sessionDescription.isEmpty {
            lines.append(sessionDescription)
        }

        if let revisionDescription = target.revisionDescription, !revisionDescription.isEmpty {
            lines.append("Revision: \(revisionDescription)")
        }

        if let priorHandoffDescription = target.priorHandoffDescription, !priorHandoffDescription.isEmpty {
            lines.append(priorHandoffDescription)
        }

        if let providerDescription = target.providerDescription, !providerDescription.isEmpty {
            lines.append("Provider: \(providerDescription)")
        }

        let commentsByFile = Dictionary(grouping: sortedActiveComments(), by: ReviewFeedbackFileContext.init(comment:))
        let sortedFiles = commentsByFile.keys.sorted()
        for fileContext in sortedFiles {
            guard let comments = commentsByFile[fileContext] else { continue }
            lines.append("")
            lines.append("## \(fileContext.heading)")

            for comment in comments {
                let reference = fileContext.reference(for: comment)
                let bodyLines = markdownBodyLines(comment.bodyMarkdown)
                if bodyLines.count <= 1 {
                    let suffix = bodyLines.first.map { " — \($0)" } ?? ""
                    lines.append("- `\(reference)` [comment-id: \(comment.id)]\(suffix)")
                } else {
                    lines.append("- `\(reference)` [comment-id: \(comment.id)]")
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

        lines.append("")
        lines.append(
            "When you have addressed a comment, call the alas MCP tool `review_resolve` with its comment-id and a short `reply` summarizing the change. Use `review_reply` to discuss a comment without resolving it. If the alas review tools are unavailable, report what you changed instead."
        )

        return lines.joined(separator: "\n")
    }

    private func sortedActiveComments() -> [ReviewDraftComment] {
        activeComments.sorted { lhs, rhs in
            if lhs.path != rhs.path {
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            if let lhsRange = lhs.normalizedLineRange, let rhsRange = rhs.normalizedLineRange {
                if lhsRange.lowerBound != rhsRange.lowerBound {
                    return lhsRange.lowerBound < rhsRange.lowerBound
                }
                if lhsRange.upperBound != rhsRange.upperBound {
                    return lhsRange.upperBound < rhsRange.upperBound
                }
            } else if lhs.normalizedLineRange != nil {
                return false
            } else if rhs.normalizedLineRange != nil {
                return true
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
        let suffix = shouldDisplayNamespace ? ", \(namespace)" : ""
        switch comment.anchor {
        case .file:
            return "\(path) (whole file\(suffix))"
        case .line(let side, _, _, _):
            let line = ReviewFeedbackFileContext.lineDescription(for: comment)
            return "\(path):\(line) (\(side.rawValue)\(suffix))"
        case .image(let side, let x, let y):
            return String(
                format: "%@ (%@ image, %.1f%% from left, %.1f%% from top%@)",
                path, side.rawValue, x * 100, y * 100, suffix
            )
        }
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
        guard let range = comment.normalizedLineRange else { return "" }
        if range.lowerBound == range.upperBound {
            return "\(range.lowerBound)"
        }
        return "\(range.lowerBound)-\(range.upperBound)"
    }
}
