import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// Sparse task notifications. Output remains on the original tool call.
public struct ACPAsyncTaskUpdate: Codable, Equatable, Sendable {
    public let sessionUpdate: String
    public let asyncTaskId: String
    public var name: String?
    public var taskType: String?
    public var description: String?
    public var summary: String?
    public var state: String?
    public var canStop: Bool?
    public var showInTranscript: Bool?
    public var outputFilePath: String?
    public var toolCallId: String?
    public var usage: AnyCodable?
    public var metadata: AnyCodable?

    public enum CodingKeys: String, CodingKey, Sendable {
        case sessionUpdate, asyncTaskId, name, taskType, description, summary, state,
             canStop, showInTranscript, outputFilePath, toolCallId, usage
        case metadata = "_meta"
    }

    public init(sessionUpdate: String, asyncTaskId: String, name: String? = nil,
         state: String? = nil, canStop: Bool? = nil, summary: String? = nil) {
        self.sessionUpdate = sessionUpdate
        self.asyncTaskId = asyncTaskId
        self.name = name
        self.state = state
        self.canStop = canStop
        self.summary = summary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionUpdate = try c.decode(String.self, forKey: .sessionUpdate)
        asyncTaskId = try c.decode(String.self, forKey: .asyncTaskId)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        taskType = try? c.decodeIfPresent(String.self, forKey: .taskType)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        state = try? c.decodeIfPresent(String.self, forKey: .state)
        canStop = try? c.decodeIfPresent(Bool.self, forKey: .canStop)
        showInTranscript = try? c.decodeIfPresent(Bool.self, forKey: .showInTranscript)
        outputFilePath = try? c.decodeIfPresent(String.self, forKey: .outputFilePath)
        toolCallId = try? c.decodeIfPresent(String.self, forKey: .toolCallId)
        usage = try? c.decodeIfPresent(AnyCodable.self, forKey: .usage)
        metadata = try? c.decodeIfPresent(AnyCodable.self, forKey: .metadata)
    }
}
