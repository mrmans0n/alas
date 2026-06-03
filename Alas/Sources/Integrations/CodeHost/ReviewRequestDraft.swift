import Foundation

enum ReviewRequestDraft {
    struct GeneratedMessage: Equatable {
        let title: String
        let body: String
    }

    struct ValidationInput {
        let title: String
        let body: String
        let snapshot: ReviewLoopSnapshot?
    }

    static func parseGeneratedMessage(_ raw: String) throws -> GeneratedMessage {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstLineEnd = normalized.firstIndex(of: "\n") else {
            return GeneratedMessage(title: normalized, body: "")
        }
        let title = String(normalized[..<firstLineEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyStart = normalized.index(after: firstLineEnd)
        let body = String(normalized[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return GeneratedMessage(title: title, body: body)
    }

    static func validationMessage(for input: ValidationInput) -> String? {
        if input.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Title is required."
        }
        if input.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Description is required."
        }
        guard let snapshot = input.snapshot else { return "Review state is still loading." }
        guard snapshot.remote != nil else { return "No supported review host." }
        guard snapshot.providerAvailable else { return "Review host CLI is not available." }
        guard snapshot.providerAuthenticated else { return "Review host authentication is required." }
        guard snapshot.providerCapabilities.canCreateReviewRequest else { return "This review host cannot create review requests yet." }
        guard snapshot.reviewRequest == nil else { return "A PR already exists for this branch." }
        guard !isLocalBranchSelectedBase(snapshot) else { return "Switch to a feature branch before creating a PR." }
        guard snapshot.local.aheadCommitCount > 0 else { return "This branch has no committed changes to publish." }
        guard !snapshot.local.needsPush else { return "Push this branch before creating a PR." }
        return nil
    }

    private static func isLocalBranchSelectedBase(_ snapshot: ReviewLoopSnapshot) -> Bool {
        snapshot.local.branchName == normalizedBranchName(
            snapshot.local.baseBranch,
            remoteName: snapshot.remote?.remoteName
        )
    }

    private static func normalizedBranchName(_ branchName: String, remoteName: String?) -> String {
        guard let remoteName else { return branchName }
        let prefix = "\(remoteName)/"
        guard branchName.hasPrefix(prefix) else { return branchName }
        return String(branchName.dropFirst(prefix.count))
    }
}
