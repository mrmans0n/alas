import AlasRemoteKit
import SwiftUI

/// Submits a pull or merge request review: a verdict, an optional summary and the open line drafts,
/// after a last confirmation naming the verdict.
struct SubmitReviewSheet: View {
    let review: RemoteProviderReview
    let submission: RemoteReviewSubmission
    /// Open drafts that stay on the Mac: file comments, and line ones the provider can't anchor.
    let unpostedCount: Int
    let poster: String
    /// Returns why it failed, or nil once it's submitted.
    let submit: (RemoteReviewDecision, String) async -> String?
    @State private var decision: RemoteReviewDecision
    @State private var text = ""
    @State private var confirming = false
    @State private var submitting = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(review: RemoteProviderReview, drafts: [RemoteReviewComment], poster: String,
         submit: @escaping (RemoteReviewDecision, String) async -> String?) {
        self.review = review
        submission = RemoteReviewSubmission(review, drafts: drafts)
        unpostedCount = drafts.count { $0.isOpen && !$0.isPublished && !$0.isPublishable }
        self.poster = poster
        self.submit = submit
        _decision = State(initialValue: submission.decisions.first ?? .comment)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Decision", selection: $decision) {
                        ForEach(submission.decisions, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    if !submission.decisions.contains(.approve) {
                        Text("Approving and requesting changes aren't available on this \(review.displayName).")
                    }
                }
                Section {
                    TextField(decision == .requestChanges ? "What needs to change" : "Optional", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                } header: {
                    Text("Summary")
                }
                Section {
                    Text(Self.comments(submission.draftCount) + " posted with it")
                    if unpostedCount > 0 {
                        Text(Self.comments(unpostedCount) + " stay on the Mac: only open line comments are posted.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Posts as \(poster) on \(review.providerName).")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Submit Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(submitting) }
                ToolbarItem(placement: .confirmationAction) {
                    if submitting {
                        ProgressView()
                    } else {
                        Button("Submit") { confirming = true }
                            .disabled(!submission.canSubmit(decision, body: text))
                            .confirmationDialog(question, isPresented: $confirming, titleVisibility: .visible) {
                                Button(decision.title) { Task { await send() } }
                            } message: {
                                Text("Others on \(review.providerName) see it at once.")
                            }
                    }
                }
            }
        }
        .interactiveDismissDisabled(submitting)
    }

    private var question: String {
        switch decision {
        case .comment: "Comment on \(review.displayName) as \(poster)?"
        case .requestChanges: "Request changes on \(review.displayName) as \(poster)?"
        case .approve: "Approve \(review.displayName) as \(poster)?"
        }
    }

    private static func comments(_ count: Int) -> String { count == 1 ? "1 comment" : "\(count) comments" }

    private func send() async {
        submitting = true
        error = await submit(decision, text.trimmingCharacters(in: .whitespacesAndNewlines))
        submitting = false
        if error == nil { dismiss() }
    }
}

private extension RemoteReviewDecision {
    var title: String {
        switch self {
        case .comment: "Comment"
        case .requestChanges: "Request Changes"
        case .approve: "Approve"
        }
    }
}

extension RemoteProviderReview {
    /// Who the provider posts as, for the confirmations.
    var poster: String { account.map { "@\($0)" } ?? "the account signed in on the Mac" }
}
