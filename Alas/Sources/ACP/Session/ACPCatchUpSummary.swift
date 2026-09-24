import CryptoKit
import Foundation

struct ACPCatchUpSourceSnapshot: Equatable, Sendable {
    enum Scope: Equatable, Sendable {
        case fullSession
        case recentActivity(omittedEntryCount: Int)
    }

    struct Entry: Equatable, Sendable {
        enum Kind: String, Equatable, Sendable {
            case user
            case agent
            case result
        }

        let reference: Int
        let stableID: String
        let kind: Kind
        let text: String
    }

    struct ResultEvidence: Equatable, Sendable {
        let completedCount: Int
        let failedCount: Int
        let cancelledCount: Int
    }

    let sessionID: String
    let entries: [Entry]
    let scope: Scope
    let resultEvidence: ResultEvidence
    let fingerprint: String

    var prompt: String {
        entries.map { entry in
            "[\(entry.reference)] \(entry.kind.rawValue.uppercased()):\n\(entry.text)"
        }.joined(separator: "\n\n")
    }
}

@MainActor
enum ACPCatchUpSourceBuilder {
    struct Limits: Equatable, Sendable {
        let maxEntries: Int
        let maxCharacters: Int
        let maxEntryCharacters: Int

        init(maxEntries: Int = 24, maxCharacters: Int = 12_000, maxEntryCharacters: Int = 2_000) {
            self.maxEntries = max(1, maxEntries)
            self.maxCharacters = max(1, maxCharacters)
            self.maxEntryCharacters = max(1, maxEntryCharacters)
        }
    }

    static func make(
        sessionID: String,
        messages: [ACPMessage],
        activeMessageIndex: Int? = nil,
        activeTurnUserIndex: Int? = nil,
        knownEarlierMessageCount: Int = 0,
        limits: Limits = Limits()
    ) -> ACPCatchUpSourceSnapshot? {
        typealias Candidate = (
            stableID: String,
            kind: ACPCatchUpSourceSnapshot.Entry.Kind,
            text: String,
            resultStatus: String?
        )
        var candidates: [Candidate] = []

        for (index, message) in messages.enumerated() where index != activeMessageIndex {
            switch message {
            case .user(_, _, let text, _, _):
                let visibleText = ACPSession.removingAlasWorkspaceContext(from: text)
                appendCandidate(message: message, kind: .user, text: visibleText, to: &candidates)
            case .agent(_, _, let text):
                if let activeTurnUserIndex, index > activeTurnUserIndex { continue }
                appendCandidate(message: message, kind: .agent, text: text.value, to: &candidates)
            case .toolCall(let toolCall):
                guard let terminalStatus = terminalStatus(toolCall.status) else { continue }
                let title = toolCall.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let safeTitle = title.isEmpty ? "Tool result" : title
                appendCandidate(
                    message: message,
                    kind: .result,
                    text: "\(safeTitle). Status: \(terminalStatus).",
                    resultStatus: terminalStatus,
                    to: &candidates
                )
            case .thought, .fileEdit, .plan, .systemNotice:
                continue
            }
        }

        guard !candidates.isEmpty else { return nil }
        var selected: [Candidate] = []
        var selectedCharacters = 0
        for candidate in candidates.reversed() {
            guard selected.count < limits.maxEntries else { break }
            let boundedText = String(candidate.text.prefix(limits.maxEntryCharacters))
            guard !boundedText.isEmpty else { continue }
            guard selected.isEmpty || selectedCharacters + boundedText.count <= limits.maxCharacters else { break }
            selected.append((candidate.stableID, candidate.kind, boundedText, candidate.resultStatus))
            selectedCharacters += boundedText.count
        }
        selected.reverse()
        guard !selected.isEmpty else { return nil }

        let entries = selected.enumerated().map { offset, entry in
            ACPCatchUpSourceSnapshot.Entry(
                reference: offset + 1,
                stableID: entry.stableID,
                kind: entry.kind,
                text: entry.text
            )
        }
        let omittedCount = candidates.count - entries.count + max(0, knownEarlierMessageCount)
        let scope: ACPCatchUpSourceSnapshot.Scope = omittedCount == 0
            ? .fullSession
            : .recentActivity(omittedEntryCount: omittedCount)
        let selectedStatuses = selected.compactMap(\.resultStatus)
        let evidence = ACPCatchUpSourceSnapshot.ResultEvidence(
            completedCount: selectedStatuses.count(where: { $0 == "completed" }),
            failedCount: selectedStatuses.count(where: { $0 == "failed" }),
            cancelledCount: selectedStatuses.count(where: { $0 == "cancelled" })
        )
        let fingerprint = fingerprint(sessionID: sessionID, entries: entries, scope: scope)
        return ACPCatchUpSourceSnapshot(
            sessionID: sessionID,
            entries: entries,
            scope: scope,
            resultEvidence: evidence,
            fingerprint: fingerprint
        )
    }

    private static func appendCandidate(
        message: ACPMessage,
        kind: ACPCatchUpSourceSnapshot.Entry.Kind,
        text: String,
        resultStatus: String? = nil,
        to candidates: inout [(
            stableID: String,
            kind: ACPCatchUpSourceSnapshot.Entry.Kind,
            text: String,
            resultStatus: String?
        )]
    ) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        candidates.append((message.stableId, kind, text, resultStatus))
    }

    private static func terminalStatus(_ status: String) -> String? {
        switch status.lowercased() {
        case "completed", "success": "completed"
        case "failed", "error": "failed"
        case "cancelled", "canceled": "cancelled"
        default: nil
        }
    }

    private static func fingerprint(
        sessionID: String,
        entries: [ACPCatchUpSourceSnapshot.Entry],
        scope: ACPCatchUpSourceSnapshot.Scope
    ) -> String {
        let scopeMarker = switch scope {
        case .fullSession: "full"
        case .recentActivity(let omittedEntryCount): "recent:\(omittedEntryCount)"
        }
        var source = sessionID + "\u{001F}" + scopeMarker
        for entry in entries {
            source.append("\u{001E}\(entry.reference)\u{001F}\(entry.stableID)\u{001F}\(entry.kind.rawValue)\u{001F}\(entry.text)")
        }
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct ACPCatchUpGeneratedDraft: Codable, Equatable, Sendable {
    struct Claim: Codable, Equatable, Sendable {
        let text: String
        let sourceReferences: [Int]
    }

    let changed: [Claim]
    let remains: [Claim]
}

struct ACPCatchUpSummary: Equatable, Sendable {
    struct Claim: Equatable, Sendable, Identifiable {
        let text: String
        let sourceStableIDs: [String]

        var id: String { text + "\u{001F}" + sourceStableIDs.joined(separator: "\u{001E}") }
    }

    let changed: [Claim]
    let remains: [Claim]
}

enum ACPCatchUpSummaryValidator {
    static func validate(
        _ draft: ACPCatchUpGeneratedDraft,
        against snapshot: ACPCatchUpSourceSnapshot
    ) -> ACPCatchUpSummary? {
        guard draft.changed.count <= 4, draft.remains.count <= 4 else { return nil }
        guard let changed = validate(draft.changed, entries: snapshot.entries),
              let remains = validate(draft.remains, entries: snapshot.entries),
              !changed.isEmpty || !remains.isEmpty else { return nil }
        return ACPCatchUpSummary(changed: changed, remains: remains)
    }

    private static func validate(
        _ claims: [ACPCatchUpGeneratedDraft.Claim],
        entries: [ACPCatchUpSourceSnapshot.Entry]
    ) -> [ACPCatchUpSummary.Claim]? {
        var validated: [ACPCatchUpSummary.Claim] = []
        for claim in claims {
            let text = claim.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 280, !claim.sourceReferences.isEmpty else { return nil }
            let references = Array(Set(claim.sourceReferences)).sorted()
            guard references.allSatisfy({ entries.indices.contains($0 - 1) }) else { return nil }
            validated.append(.init(
                text: text,
                sourceStableIDs: references.map { entries[$0 - 1].stableID }
            ))
        }
        return validated
    }
}

struct ACPCatchUpGenerationKey: Equatable, Sendable {
    let sessionID: String
    let fingerprint: String

    init(snapshot: ACPCatchUpSourceSnapshot) {
        sessionID = snapshot.sessionID
        fingerprint = snapshot.fingerprint
    }

    func accepts(sessionID: String, fingerprint: String) -> Bool {
        self.sessionID == sessionID && self.fingerprint == fingerprint
    }
}
