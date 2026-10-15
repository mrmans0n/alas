import Foundation

struct ReviewFeedbackTarget: Equatable, Sendable {
    var title: String
    var repositoryPath: String?
    var providerDescription: String?
    var sourceDescription: String
    var sessionDescription: String? = nil
    var revisionDescription: String? = nil
    var priorHandoffDescription: String? = nil
    /// Reopens the review surface the comments came from, from the card.
    var reopenAction: ACPPromptCard.Action? = nil
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
                    // Indented under the bullet so blank lines and fences
                    // stay inside the list item.
                    lines.append(contentsOf: bodyLines.map(Self.listItemContinuation))
                }

                if let selectedText = Self.displayedSelectedText(comment) {
                    for selectedLine in selectedText.components(separatedBy: .newlines) {
                        lines.append(Self.listItemContinuation("> \(selectedLine)"))
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

    func card() -> ACPPromptCard {
        let comments = sortedActiveComments()
        let commentsByFile = Dictionary(grouping: comments, by: ReviewFeedbackFileContext.init(comment:))
        let files = commentsByFile.keys.sorted()
        var facts: [ACPPromptCard.Fact] = []
        if let repositoryPath = target.repositoryPath, !repositoryPath.isEmpty {
            facts.append(.init(kind: .repository, text: (repositoryPath as NSString).lastPathComponent))
        }
        if let revision = target.revisionDescription, !revision.isEmpty {
            facts.append(.init(kind: .revision, text: Self.shortRevision(revision)))
        }
        if let provider = target.providerDescription, !provider.isEmpty {
            facts.append(.init(kind: .provider, text: provider))
        }
        facts.append(.init(kind: .other, text: Self.countText(comments: comments.count, files: files.count)))
        let sections = files.map { file in
            ACPPromptCard.Section(title: file.heading, items: (commentsByFile[file] ?? []).map(Self.cardItem))
        }
        return ACPPromptCard(origin: .review, title: target.title, facts: facts, sections: sections, action: target.reopenAction)
    }

    private static func cardItem(_ comment: ReviewDraftComment) -> ACPPromptCard.Item {
        let range = comment.normalizedLineRange
        // Inner whitespace kept: a leading indent can make an indented code block.
        let body = comment.bodyMarkdown.trimmingCharacters(in: .newlines)
        let language = (comment.path as NSString).pathExtension.lowercased()
        return ACPPromptCard.Item(
            location: .init(
                path: comment.path,
                startLine: range?.lowerBound,
                endLine: range?.upperBound,
                side: comment.side == .unknown ? nil : comment.side.rawValue),
            bodyMarkdown: body.trimmingCharacters(in: .whitespaces).isEmpty ? nil : body,
            excerpt: displayedSelectedText(comment).map {
                .init(text: $0, style: .code, language: language.isEmpty ? nil : language)
            },
            reviewCommentID: comment.id)
    }

    private static func displayedSelectedText(_ comment: ReviewDraftComment) -> String? {
        guard let selectedText = comment.selectedText?.trimmingCharacters(in: .newlines),
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return selectedText
    }

    private static func listItemContinuation(_ line: String) -> String {
        line.isEmpty ? "" : "  " + line
    }

    private static func shortRevision(_ revision: String) -> String {
        let isFullSHA = revision.count == 40 && revision.allSatisfy(\.isHexDigit)
        return isFullSHA ? String(revision.prefix(7)) : revision
    }

    private static func countText(comments: Int, files: Int) -> String {
        "\(comments) comment\(comments == 1 ? "" : "s") · \(files) file\(files == 1 ? "" : "s")"
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
