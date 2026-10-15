import Foundation
import Observation

/// Live state of local review comments, keyed by id, for review cards in
/// chat transcripts. Reloads whenever a review pane, the CLI, or MCP
/// changes the draft comments.
@MainActor
@Observable
final class ReviewCommentStatusModel {
    struct Status: Equatable {
        var state: ReviewDraftCommentState
        var agentReply: String?
    }

    static let shared = ReviewCommentStatusModel()

    private(set) var statuses: [String: Status] = [:]
    @ObservationIgnored private let load: () -> [ReviewDraftComment]
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(
        load: @escaping () -> [ReviewDraftComment] = { (try? ReviewDraftCommentStore().loadAll()) ?? [] },
        center: NotificationCenter = .default
    ) {
        self.load = load
        reload()
        observer = center.addObserver(
            forName: .alasReviewDraftCommentsDidChangeExternally, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func status(for commentID: String) -> Status? { statuses[commentID] }

    func reload() {
        var next: [String: Status] = [:]
        for comment in load() {
            let reply = comment.allReplies.last { reply in
                if case .agent = reply.author { return true }
                return false
            }
            next[comment.id] = Status(state: comment.state, agentReply: reply?.bodyMarkdown)
        }
        if next != statuses { statuses = next }
    }
}
