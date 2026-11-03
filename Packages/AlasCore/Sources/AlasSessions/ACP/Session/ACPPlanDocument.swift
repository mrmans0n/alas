import Foundation

/// A plan file on the session's host.
public struct ACPPlanFileReference: Codable, Equatable, Hashable, Sendable {
    /// Absolute, on the session's host.
    public let path: String
    /// Adapter-reported (`planFile`), or nil for standard `file` plans.
    public let sha256: String?

    public init(path: String, sha256: String?) {
        self.path = path
        self.sha256 = sha256
    }
}

/// A Markdown or file-backed plan, keyed by the agent's `planId`. Unlike a
/// checklist (`ACPMessage.plan`), it never feeds the plan pill, `currentPlan`
/// or session summaries.
public struct ACPPlanDocument: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case markdown
        case file
    }

    public let planId: String
    public var kind: Kind
    /// The last snapshot; nil for a file plan.
    public var markdown: String?
    public var file: ACPPlanFileReference?
    /// Set by `plan_removed`.
    public var hidden: Bool

    public init(planId: String, kind: Kind, markdown: String?, file: ACPPlanFileReference?, hidden: Bool = false) {
        self.planId = planId
        self.kind = kind
        self.markdown = markdown
        self.file = file
        self.hidden = hidden
    }

    private enum CodingKeys: String, CodingKey {
        case planId, kind, markdown, file, hidden
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        planId = try c.decode(String.self, forKey: .planId)
        kind = try c.decode(Kind.self, forKey: .kind)
        markdown = try c.decodeIfPresent(String.self, forKey: .markdown)
        file = try c.decodeIfPresent(ACPPlanFileReference.self, forKey: .file)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(planId, forKey: .planId)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(markdown, forKey: .markdown)
        try c.encodeIfPresent(file, forKey: .file)
        if hidden { try c.encode(true, forKey: .hidden) }
    }
}

/// The persisted payload of a `"plan"` row, shared by `ACPMessageCodec` and
/// `ACPMessageWire`. Checklists write exactly `{items}`. Documents keep the
/// `"plan"` kind and add a `kind` discriminator with an always-present empty
/// `items`, so an older build decodes them as an empty checklist.
struct ACPPlanRowPayload: Codable {
    let items: [ACPMessage.PlanItem]
    let planId: String?
    let kind: String?
    let markdown: String?
    let file: ACPPlanFileReference?
    /// Encoded only when true.
    let hidden: Bool?

    init(items: [ACPMessage.PlanItem]) {
        self.items = items
        planId = nil
        kind = nil
        markdown = nil
        file = nil
        hidden = nil
    }

    init(document: ACPPlanDocument) {
        items = []
        planId = document.planId
        kind = document.kind.rawValue
        markdown = document.markdown
        file = document.file
        hidden = document.hidden ? true : nil
    }

    /// The document this payload describes, or nil for a checklist: a known
    /// document `kind` without a `planId` (or any other `kind`) stays a checklist.
    var document: ACPPlanDocument? {
        guard let planId, let kind = kind.flatMap(ACPPlanDocument.Kind.init(rawValue:)) else { return nil }
        return ACPPlanDocument(planId: planId, kind: kind, markdown: markdown, file: file, hidden: hidden ?? false)
    }
}
