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
            self = .toolCall(ACPTranscriptFoldToolCall(
                status: toolCall.status,
                joins: ACPContextCompaction(toolCall: toolCall) == nil
                    && ACPSubagentRowDescriptor(toolCall: toolCall) == nil
                    && ACPBackgroundTask(toolCall: toolCall) == nil
                    && !hiddenToolCallIds.contains(toolCall.toolCallId),
                verb: ACPToolCallGroupSummary.verb(forLabel: ACPToolCallPresentation.resolve(toolCall).label)
            ))
        default:
            self = .other
        }
    }
}
