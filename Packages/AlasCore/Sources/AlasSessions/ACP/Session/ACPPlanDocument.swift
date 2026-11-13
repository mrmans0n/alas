import Foundation
import AlasFoundation
import AlasACP

extension ACPPlanDocument.Display {
    /// `filePath` when "Open plan file" may open it: the agent names the
    /// path, so only one the plan file reader would read.
    public var openableFilePath: String? {
        filePath.flatMap { ACPPlanFileReader.isPlanPath($0) ? $0 : nil }
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
