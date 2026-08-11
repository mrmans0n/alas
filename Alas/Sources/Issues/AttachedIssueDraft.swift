import Foundation

struct AttachedIssueDraft: Equatable, Sendable {
    var source: IssueSnapshot
    var projectID: String?
    var branchSeed: String
    var prompt: String

    var attachment: IssueAttachment {
        IssueAttachment(
            canonicalURL: source.canonicalURL,
            providerLabel: source.providerLabel,
            displayReference: source.displayReference,
            title: source.title
        )
    }
}
