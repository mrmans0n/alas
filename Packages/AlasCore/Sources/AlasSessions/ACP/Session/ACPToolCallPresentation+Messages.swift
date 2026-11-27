import Foundation
import AlasFoundation
import AlasModel

extension ACPToolCallPresentation {
    /// The `toolCallId`s of finished `visual_show` calls whose visual is embedded: the visual flows
    /// straight out of the prose, so their tool chip is not shown. The call does not carry the
    /// presentation, so each visual row is linked to the call it names, or, for a visual that names
    /// none, to the nearest earlier `visual_show` call in its turn (stopping at the user message)
    /// that no other visual has claimed. Card visuals claim their
    /// call too but keep its chip, as do visuals stored before `presentation` existed (they decode as
    /// cards). A claimed call is hidden only while its latest snapshot here is `completed`, so an
    /// in-flight or failed call keeps its chip. Replayed duplicates of a visual claim nothing.
    public static func hiddenVisualShowToolCallIds(
        in messages: some BidirectionalCollection<ACPMessage>
    ) -> Set<String> {
        var claimed = Set<String>()
        var embeddedCalls = Set<String>()
        var linkedVisuals = Set<UUID>()
        for index in messages.indices {
            guard case .visualAid(let visual) = messages[index],
                  linkedVisuals.insert(visual.id).inserted
            else { continue }
            if let named = visual.toolCallId {
                if claimed.insert(named).inserted, visual.presentation == .embedded { embeddedCalls.insert(named) }
                continue
            }
            var cursor = index
            scan: while cursor != messages.startIndex {
                cursor = messages.index(before: cursor)
                switch messages[cursor] {
                case .user:
                    break scan
                case .toolCall(let toolCall)
                    where !claimed.contains(toolCall.toolCallId) && isVisualShow(toolCall):
                    claimed.insert(toolCall.toolCallId)
                    if visual.presentation == .embedded { embeddedCalls.insert(toolCall.toolCallId) }
                    break scan
                default:
                    continue
                }
            }
        }
        guard !embeddedCalls.isEmpty else { return [] }
        var latestStatus: [String: String] = [:]
        for message in messages {
            if case .toolCall(let toolCall) = message, embeddedCalls.contains(toolCall.toolCallId) {
                latestStatus[toolCall.toolCallId] = toolCall.status
            }
        }
        return embeddedCalls.filter { latestStatus[$0] == "completed" }
    }
}
