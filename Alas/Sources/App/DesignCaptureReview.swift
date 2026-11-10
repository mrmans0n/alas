import SwiftUI

/// Design-capture targets for the Review Changes tab: draft comments, a
/// provider review thread and a CI annotation over the demo worktree's diff.
/// Drafts go through the review draft store of the capture profile; the thread
/// and annotation are in-memory, fed to the surface through the same
/// parameters a pull request review uses. Debug builds only; release builds
/// get the empty values below.
@MainActor
@Observable
final class DesignCaptureReview {
    static let shared = DesignCaptureReview()
    /// review-comments: draft cards and the rail; review-states: the deferred large diff;
    /// review-thread: provider thread beside a draft; review-annotation: CI annotation;
    /// review-image: top of the stream, with the image that fails to decode.
    static let targets: Set<String> = ["review-comments", "review-states", "review-thread", "review-annotation", "review-image"]

    /// Provider threads and check annotations for the surface; empty unless a target seeded them.
    private(set) var threads: [ReviewThread] = []
    private(set) var annotations: [CheckAnnotation] = []
#if DEBUG
    /// The draft comment the review tab scrolls to once it has loaded.
    private(set) var scrollTargetID: String?

    private static let invoicePath = "src/billing/Invoice.swift"
    private static let taxPath = "src/billing/TaxRules.swift"
    private static let routesPath = "src/web/routes.ts"
    private static let ratesPath = "src/generated/rates.csv"
    private static let discountCommentID = "design-draft-discount"
    private static let ratesCommentID = "design-draft-rates"

    /// Only an instance capture.sh launched on a demo profile may write drafts; another Debug
    /// instance also receives the distributed capture notification and must ignore it.
    private static var isCaptureInstance: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["ALAS_DESIGN_CAPTURE"] == "1" && env["ALAS_APP_SUPPORT_DIR"] != nil
    }

    func open(_ target: String, state: AppState) {
        guard Self.isCaptureInstance else { return }
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(30)
            while state.projects.isEmpty || state.selectedWorktreeId.flatMap({ state.worktree(withId: $0) }) == nil {
                guard Date() < deadline else { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let worktree = state.selectedWorktreeId.flatMap({ state.worktree(withId: $0) }) else { return }
            let sessionID = ReviewChangesTabView.reviewDraftSessionID(worktree: worktree)
            let store = ReviewDraftCommentStore()
            for comment in Self.draftComments(sessionID: sessionID) { try? store.save(comment) }
            threads = [Self.thread]
            annotations = [Self.annotation]
            switch target {
            case "review-states": scrollTargetID = Self.ratesCommentID
            case "review-thread": scrollTargetID = "design-draft-rounding"
            case "review-annotation": scrollTargetID = "design-draft-limit"
            case "review-image": scrollTargetID = nil
            default: scrollTargetID = Self.discountCommentID
            }
            NotificationCenter.default.post(name: .alasReviewDraftCommentsDidChangeExternally, object: nil)
        }
    }

    private static func draftComments(sessionID: ReviewDraftSessionID) -> [ReviewDraftComment] {
        let now = Date()
        func comment(
            _ id: String, _ path: String, line: Int?, _ body: String, state: ReviewDraftCommentState = .active,
            author: ReviewDraftCommentAuthor? = nil, replies: [ReviewCommentReply]? = nil
        ) -> ReviewDraftComment {
            ReviewDraftComment(
                id: id, sessionID: sessionID,
                fileID: DiffReviewFileID(source: .unstaged, path: path), path: path,
                anchor: line.map { .line(side: .new, startLine: $0, endLine: nil, selectedText: nil) } ?? .file,
                bodyMarkdown: body, state: state, createdAt: now, updatedAt: now, author: author, replies: replies
            )
        }
        return [
            comment(discountCommentID, invoicePath, line: 18,
                    "Should `discount` be capped at the subtotal? A negative total is clamped in `total(applying:)`, but the invoice would still show the full credit."),
            comment("design-draft-total", invoicePath, line: 27,
                    "`max(0, ...)` hides bad data. I would rather surface it than clamp it.",
                    author: .agent(name: "Claude"),
                    replies: [ReviewCommentReply(
                        id: "design-reply-1", author: .user,
                        bodyMarkdown: "Fine to clamp for now, but log when it happens.", createdAt: now)]),
            comment("design-draft-rounding", taxPath, line: 14,
                    "Banker's rounding differs from what the accountants export. Check with finance before merging."),
            comment("design-draft-limit", routesPath, line: 7,
                    "Parse `limit` once and reject `NaN`; `Number(\"abc\")` currently falls through to 200."),
            comment(ratesCommentID, ratesPath, line: nil,
                    "Generated by the tax export job; do not edit by hand."),
        ]
    }

    private static var thread: ReviewThread {
        let comments = [
            ReviewComment(
                id: "design-thread-1", author: "marta-r", body: "Customers on a reverse-charge VAT scheme are exempt, so this early return is right. Can we add a test for it?",
                url: nil, createdAt: nil, viewerCanUpdate: false, viewerCanDelete: false, isPending: false),
            ReviewComment(
                id: "design-thread-2", author: "demo-author", body: "Added `testExemptCustomerPaysNoTax` in `InvoiceTests`.",
                url: nil, createdAt: nil, viewerCanUpdate: true, viewerCanDelete: true, isPending: false, viewerDidAuthor: true),
            ReviewComment(
                id: "design-thread-3", author: "marta-r", body: "Thanks. Should the exempt list live in config instead of on `TaxRules`?",
                url: nil, createdAt: nil, viewerCanUpdate: false, viewerCanDelete: false, isPending: false),
        ]
        return ReviewThread(
            id: "design-thread", path: taxPath, line: 10, startLine: nil, originalLine: nil, diffHunk: nil, diffSide: "RIGHT",
            isResolved: false, isOutdated: false, isFileLevel: false, comments: comments,
            viewerCanResolve: true, viewerCanReply: true, url: nil)
    }

    private static var annotation: CheckAnnotation {
        CheckAnnotation(
            checkRunID: "design-lint", checkName: "eslint", path: routesPath, startLine: 7, endLine: 7,
            level: .warning, message: "Unexpected unvalidated `req.query.limit`; coerce it with `z.coerce.number()`.",
            rawDetails: nil)
    }
#endif
}

/// Scrolls the review tab to the seeded draft comment a capture target asks for.
private struct DesignCaptureReviewScroll: ViewModifier {
    let comments: [ReviewDraftComment]
    let select: (ReviewDraftComment) -> Void

    func body(content: Content) -> some View {
#if DEBUG
        content.task(id: comments.count) {
            guard let id = DesignCaptureReview.shared.scrollTargetID,
                  let comment = comments.first(where: { $0.id == id }) else { return }
            // Lets the diff rows lay out before the scroll lands.
            try? await Task.sleep(for: .seconds(1))
            select(comment)
        }
#else
        content
#endif
    }
}

extension View {
    func designCaptureReviewScroll(comments: [ReviewDraftComment], select: @escaping (ReviewDraftComment) -> Void) -> some View {
        modifier(DesignCaptureReviewScroll(comments: comments, select: select))
    }
}
