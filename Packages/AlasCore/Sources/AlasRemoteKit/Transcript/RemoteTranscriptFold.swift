import Foundation

/// The activity fold over forwarded transcript rows, from the facts each
/// wire row carries. Shared by the phone and the Mac's peer view.
public enum RemoteTranscriptFold {
    /// `messages` in transcript order; `isHidden` rows are dropped before folding.
    /// Row indices in the result are positions in `messages`.
    public static func renderRows(
        messages: [RemoteWireMessage],
        isTurnActive: Bool,
        isExpanded: (ACPTranscriptToolCallGroup) -> Bool,
        memberLimit: (ACPTranscriptToolCallGroup) -> Int?
    ) -> [ACPTranscriptRenderRow] {
        renderRows(
            messages: messages, items: messages.map(item(for:)), isTurnActive: isTurnActive,
            isExpanded: isExpanded, memberLimit: memberLimit
        )
    }

    /// `items[i]` must be `item(for: messages[i])`; a caller that caches them
    /// per row avoids decoding every tool call on each change.
    public static func renderRows(
        messages: [RemoteWireMessage],
        items: [ACPTranscriptFoldItem],
        isTurnActive: Bool,
        isExpanded: (ACPTranscriptToolCallGroup) -> Bool,
        memberLimit: (ACPTranscriptToolCallGroup) -> Int?
    ) -> [ACPTranscriptRenderRow] {
        precondition(items.count == messages.count, "One fold item per message")
        let rows = messages.enumerated().compactMap { position, message in
            message.isHidden == true ? nil : ACPTranscriptVisibleRow(index: position, stableId: message.stableId)
        }
        let source = ACPTranscriptFoldSource(
            count: messages.count,
            item: { items[$0] },
            createdAt: { position in
                messages[position].createdAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            }
        )
        let latestUserIndex = items.lastIndex(of: .user)
        let options = ACPToolCallGrouping.Options(
            enabled: true,
            currentTurnAnswerIndex: ACPToolCallGrouping.currentTurnAnswerIndex(
                source: source, currentTurnUserIndex: latestUserIndex, isTurnActive: isTurnActive
            ),
            priorCurrentTurnCommentaryIndices: ACPToolCallGrouping.priorCurrentTurnCommentaryIndices(
                source: source, currentTurnUserIndex: latestUserIndex, visibleRange: 0..<messages.count
            ),
            isTurnActive: isTurnActive
        )
        return ACPToolCallGrouping.fold(
            rows: rows, source: source, options: options, isExpanded: isExpanded, memberLimit: memberLimit
        )
    }

    /// Fold facts for one wire row; falls back when an older Mac sent no `fold`.
    /// A hidden row is transparent to runs, like a plan.
    public static func item(for message: RemoteWireMessage) -> ACPTranscriptFoldItem {
        if message.isHidden == true { return .plan }
        switch message.kind {
        case "user": return .user
        case "agent": return .agent(isCommentary: message.phase == "commentary")
        case "thought": return .thought
        case "plan": return .plan
        case "toolCall":
            // An undecodable call renders as a notice, so it folds as one.
            guard let json = message.json,
                  let call = try? JSONDecoder().decode(ACPToolCall.self, from: Data(json.utf8))
            else { return .other }
            guard let fold = message.fold else {
                return .toolCall(.init(status: call.status, joins: true, verb: verb(forKind: call.kind)))
            }
            return .toolCall(.init(
                status: call.status, joins: fold.joins,
                verb: ACPToolCallGroupSummary.Verb(rawValue: fold.verb) ?? .other
            ))
        default: return .other
        }
    }

    public static func summaryToolCalls(
        of group: ACPTranscriptToolCallGroup,
        in messages: [RemoteWireMessage]
    ) -> [ACPTranscriptFoldToolCall] {
        group.members.compactMap {
            guard case .toolCall(let call) = item(for: messages[$0.index]) else { return nil }
            return call
        }
    }

    /// `items` indexed like the messages the group was folded from, as in `renderRows`.
    public static func summaryToolCalls(
        of group: ACPTranscriptToolCallGroup,
        items: [ACPTranscriptFoldItem]
    ) -> [ACPTranscriptFoldToolCall] {
        group.members.compactMap {
            guard case .toolCall(let call) = items[$0.index] else { return nil }
            return call
        }
    }

    private static func verb(forKind kind: String?) -> ACPToolCallGroupSummary.Verb {
        switch kind {
        case "read": .read
        case "search", "fetch": .search
        case "execute": .run
        case "edit", "delete", "move": .edit
        default: .other
        }
    }
}
