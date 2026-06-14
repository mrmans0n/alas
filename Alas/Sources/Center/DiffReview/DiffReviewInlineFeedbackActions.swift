import Foundation

struct DiffReviewInlineFeedbackScrollCommand: Equatable {
    let feedbackID: String
    let fileID: DiffReviewFileID
    let generation: Int

    var targetID: DiffReviewInlineFeedbackTargetID {
        DiffReviewInlineFeedbackTargetID.targetID(feedbackID: feedbackID, fileID: fileID)
    }
}

struct DiffReviewInlineFeedbackScrollController: Equatable {
    private(set) var generation = 0

    mutating func command(feedbackID: String, fileID: DiffReviewFileID) -> DiffReviewInlineFeedbackScrollCommand {
        generation += 1
        return DiffReviewInlineFeedbackScrollCommand(
            feedbackID: feedbackID,
            fileID: fileID,
            generation: generation
        )
    }
}

struct DiffReviewInlineFeedbackTargetID: Hashable, Equatable {
    let fileID: DiffReviewFileID
    let feedbackID: String

    static func targetID(feedbackID: String, fileID: DiffReviewFileID) -> DiffReviewInlineFeedbackTargetID {
        DiffReviewInlineFeedbackTargetID(fileID: fileID, feedbackID: feedbackID)
    }
}

struct DiffReviewInlineFeedbackActionAvailability: Equatable {
    var canOpenProvider: Bool
    var canCopyContext: Bool
    var canSendToAgent: Bool

    static let none = DiffReviewInlineFeedbackActionAvailability(
        canOpenProvider: false,
        canCopyContext: false,
        canSendToAgent: false
    )
}

struct DiffReviewInlineFeedbackActions {
    var availability: (DiffReviewInlineFeedback, DiffReviewFileSummary) -> DiffReviewInlineFeedbackActionAvailability = { _, _ in .none }
    var openProvider: (DiffReviewInlineFeedback, DiffReviewFileSummary) -> Void = { _, _ in }
    var copyContext: (DiffReviewInlineFeedback, DiffReviewFileSummary) -> Void = { _, _ in }
    var sendToAgent: (DiffReviewInlineFeedback, DiffReviewFileSummary) -> Void = { _, _ in }
}

enum DiffReviewInlineFeedbackContextFormatter {
    static func format(item: DiffReviewInlineFeedback, file: DiffReviewFileSummary) -> String {
        var lines: [String] = []
        lines.append("# \(item.providerName) feedback")
        if let author = item.author, !author.isEmpty {
            lines.append("Author: \(author)")
        }
        lines.append("File: \(file.path)")
        if item.anchor.path != file.path {
            lines.append("Anchor file: \(item.anchor.path)")
        }
        if let line = item.anchor.line {
            lines.append("Line: \(line)")
        }
        lines.append("Side: \(item.anchor.side.rawValue)")
        lines.append("Status: \(item.status.rawValue)")
        if let providerURL = item.providerURL {
            lines.append("URL: \(providerURL.absoluteString)")
        }
        lines.append("")
        lines.append(item.bodyPreview)
        return lines.joined(separator: "\n")
    }
}
