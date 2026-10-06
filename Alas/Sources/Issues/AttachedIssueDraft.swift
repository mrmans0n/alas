import Foundation

struct AttachedIssueDraft: Equatable, Sendable {
    var source: IssueSnapshot
    var projectID: String?
    var branchSeed: String
    var prompt: String
    var kind: IssueKind? = nil
    var kindOrigin: IssueKindOrigin? = nil

    var attachment: IssueAttachment {
        IssueAttachment(
            canonicalURL: source.canonicalURL,
            providerLabel: source.providerLabel,
            displayReference: source.displayReference,
            title: source.title
        )
    }
}
