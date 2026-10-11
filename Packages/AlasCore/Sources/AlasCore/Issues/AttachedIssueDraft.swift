import Foundation

public struct AttachedIssueDraft: Equatable, Sendable {
    public var source: IssueSnapshot
    public var projectID: String?
    public var branchSeed: String
    public var prompt: String
    public var kind: IssueKind? = nil
    public var kindOrigin: IssueKindOrigin? = nil

    public var attachment: IssueAttachment {
        IssueAttachment(
            canonicalURL: source.canonicalURL,
            providerLabel: source.providerLabel,
            displayReference: source.displayReference,
            title: source.title
        )
    }

    public init(source: IssueSnapshot, projectID: String? = nil, branchSeed: String, prompt: String, kind: IssueKind? = nil, kindOrigin: IssueKindOrigin? = nil) {
        self.source = source
        self.projectID = projectID
        self.branchSeed = branchSeed
        self.prompt = prompt
        self.kind = kind
        self.kindOrigin = kindOrigin
    }
}
