import Foundation
import AlasACP

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

extension ACPPlanDocument {
    /// What a plan document row shows.
    public struct Display: Equatable, Sendable {
        /// The Markdown body; nil for a file plan.
        public let markdown: String?
        /// Whether the row has a "Plan file" line.
        public let showsFile: Bool
        /// The file's path on the session's host, and the open action's
        /// target; nil when unknown (a peer's copy carries no path).
        public let filePath: String?
        /// The plan's review is parked: the row collapses to
        /// `underReviewLabel` and the review card shows the plan.
        public let isUnderReview: Bool

        public init(markdown: String?, showsFile: Bool, filePath: String?, isUnderReview: Bool = false) {
            self.markdown = markdown
            self.showsFile = showsFile
            self.filePath = filePath
            self.isUnderReview = isUnderReview
        }

        /// `filePath` when "Open plan file" may open it: the agent names the
        /// path, so only one the plan file reader would read.
        public var openableFilePath: String? {
            filePath.flatMap { ACPPlanFileReader.isPlanPath($0) ? $0 : nil }
        }

        public static let underReviewLabel = "Plan · under review below"
        static let underReview = Display(markdown: nil, showsFile: false, filePath: nil, isUnderReview: true)
    }

    /// Nil when the row shows nothing: removed by `plan_removed`, or with
    /// neither text nor a file.
    public var display: Display? { display(underReview: nil) }

    /// The row's display while the review of `reviewedPlanId` is parked. That
    /// review shows the plan in full, so this row collapses to one line
    /// rather than showing it twice.
    public func display(underReview reviewedPlanId: String?) -> Display? {
        guard !hidden else { return nil }
        let text = kind == .markdown ? markdown.flatMap { $0.isEmpty ? nil : $0 } : nil
        let showsFile = kind == .file || file != nil
        guard text != nil || showsFile else { return nil }
        if let reviewedPlanId, reviewedPlanId == planId { return .underReview }
        return Display(markdown: text, showsFile: showsFile, filePath: file?.path)
    }
}

/// Where a Markdown or file `plan_update` lands in a transcript.
public enum ACPPlanDocumentPlacement: Equatable, Sendable {
    case replace(Int)
    case append

    /// Claude's shared id for clients without planFile: turn-scoped, never cross-turn.
    public static let sharedClaudePlanId = "plan-mode"

    /// `existing`: index of the newest .planDocument with this planId; `latestUserIndex`: the turn boundary.
    public static func decide(planId: String, existing: Int?, latestUserIndex: Int?) -> ACPPlanDocumentPlacement {
        guard let existing else { return .append }
        if planId == sharedClaudePlanId, existing <= (latestUserIndex ?? -1) { return .append }
        return .replace(existing)
    }
}

/// Plan-row lookups shared by the parent transcript and child runs.
extension Array where Element == ACPMessage {
    /// The `.plan` row a `plan_update` checklist id owns, by the row's id.
    func checklistIndex(rowId: UUID?) -> Int? {
        guard let rowId else { return nil }
        return lastIndex {
            if case .plan(let id, _) = $0 { return id == rowId }
            return false
        }
    }

    /// The rows of the turn being replayed: after the last user row before
    /// `cursor`, up to the next user row. Nil before the first user row.
    func replayedTurnRange(before cursor: Int) -> Range<Int>? {
        func isUser(_ message: ACPMessage) -> Bool {
            if case .user = message { return true }
            return false
        }
        let start = Swift.min(Swift.max(cursor, 0), count)
        guard let turnStart = self[..<start].lastIndex(where: isUser) else { return nil }
        let turnEnd = self[(turnStart + 1)...].firstIndex(where: isUser) ?? count
        return (turnStart + 1)..<turnEnd
    }
}

extension ACPPlanDocument {
    /// The document a Markdown or file plan update produces, or nil for a
    /// checklist or an unknown plan type, which have no document row.
    ///
    /// Updating `existing` shows it again and keeps what this update does not
    /// carry: a Markdown snapshot keeps an attached `file` and its digest. A
    /// `file:` URI becomes a path without a digest; any other URI has no
    /// local path, so it is kept as Markdown text.
    public static func updated(
        _ existing: ACPPlanDocument?, planId: String, content: ACPPlanContent
    ) -> ACPPlanDocument? {
        switch content {
        case .markdown(let text):
            return ACPPlanDocument(planId: planId, kind: .markdown, markdown: text, file: existing?.file)
        case .file(let uri):
            guard let url = URL(string: uri), url.isFileURL else {
                return ACPPlanDocument(planId: planId, kind: .markdown, markdown: "Plan file: \(uri)", file: nil)
            }
            return ACPPlanDocument(
                planId: planId, kind: .file, markdown: nil, file: ACPPlanFileReference(path: url.path, sha256: nil))
        case .items, .unknown:
            return nil
        }
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
