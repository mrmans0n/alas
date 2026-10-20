import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public struct SessionSummaryTurn: Equatable, Sendable {
    public let user: String
    public let assistant: String

    public init(user: String, assistant: String) {
        self.user = user
        self.assistant = assistant
    }
}

public struct SessionSummary: Equatable, Sendable {
    public let goal: String?
    public let completed: [String]
    public let blockers: [String]
    public let nextAction: String?
    public let isPartial: Bool

    public init(goal: String?, completed: [String], blockers: [String], nextAction: String?, isPartial: Bool) {
        self.goal = goal
        self.completed = completed
        self.blockers = blockers
        self.nextAction = nextAction
        self.isPartial = isPartial
    }
}
