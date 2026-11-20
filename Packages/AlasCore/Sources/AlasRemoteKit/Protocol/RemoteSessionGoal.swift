import Foundation

/// A session's goal as the Mac's goal pill shows it.
public struct RemoteSessionGoal: Codable, Equatable, Sendable {
    public var objective: String
    /// The agent's word for it: `active`, `in_progress`, `paused`, `complete`…
    public var status: String?
    public var tokenBudget: Int?
    public var tokensUsed: Int?

    public init(objective: String, status: String?, tokenBudget: Int?, tokensUsed: Int?) {
        self.objective = objective
        self.status = status
        self.tokenBudget = tokenBudget
        self.tokensUsed = tokensUsed
    }

    public var isRunning: Bool { ["active", "in_progress"].contains(status?.lowercased()) }
    public var isPaused: Bool { status?.lowercased() == "paused" }

    /// "12k / 50k", "50k budget" or "3.4k used"; nil without either.
    public var tokenText: String? {
        switch (tokensUsed, tokenBudget) {
        case let (used?, budget?): "\(Self.tokens(used)) / \(Self.tokens(budget))"
        case let (nil, budget?): "\(Self.tokens(budget)) budget"
        case let (used?, nil): "\(Self.tokens(used)) used"
        case (nil, nil): nil
        }
    }

    private static func tokens(_ count: Int) -> String {
        guard count >= 1_000 else { return "\(count)" }
        let rounded = (Double(count) / 100).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded))k" : String(format: "%.1fk", rounded)
    }
}
