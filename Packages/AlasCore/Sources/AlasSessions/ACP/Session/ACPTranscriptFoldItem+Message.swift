import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP

extension ACPTranscriptFoldItem {
    /// The fold facts of a local transcript message. Context compactions,
    /// subagents, background tasks and an embedded visual's hidden
    /// `visual_show` chip (`hiddenToolCallIds`) never join an activity run.
    /// Main-actor because `StreamingText` is.
    @MainActor
    public init(_ message: ACPMessage, hiddenToolCallIds: Set<String>) {
        self.init(message, hiddenToolCallIds: hiddenToolCallIds, foldOnly: false)
    }

    /// `foldOnly` skips the work the fold never reads, for a caller that
    /// only folds: the verb is left `.other`, and a status that can't join
    /// a run anyway skips the exclusion checks (`joins` is then false).
    @MainActor
    public init(_ message: ACPMessage, hiddenToolCallIds: Set<String>, foldOnly: Bool) {
        switch message {
        case .user:
            self = .user
        case .agent(_, _, let buffer):
            self = .agent(isCommentary: buffer.phase == .commentary)
        case .thought:
            self = .thought
        case .plan:
            self = .plan
        case .toolCall(let toolCall):
            let canJoin = !foldOnly || ACPToolCallGrouping.isFinished(status: toolCall.status)
                || toolCall.status == "in_progress" || toolCall.status == "pending"
            self = .toolCall(ACPTranscriptFoldToolCall(
                status: toolCall.status,
                joins: canJoin
                    && !hiddenToolCallIds.contains(toolCall.toolCallId)
                    && ACPContextCompaction(toolCall: toolCall) == nil
                    && ACPSubagentRowDescriptor(toolCall: toolCall) == nil
                    && ACPToolCallPresentation.delegatedChildSessionId(toolCall) == nil
                    && ACPBackgroundTask(toolCall: toolCall) == nil,
                verb: foldOnly
                    ? .other
                    : ACPToolCallGroupSummary.verb(forLabel: ACPToolCallPresentation.resolve(toolCall).label)
            ))
        default:
            self = .other
        }
    }
}
