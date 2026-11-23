import Foundation

/// Which agent reviews a branch before Alas pushes it.
public enum ReviewerChoice: Codable, Equatable, Hashable, Sendable {
    /// The agent that owns the session being shipped, with its default model.
    case sameAsSession
    /// A specific agent; `modelID == nil` uses the agent's default model.
    case agent(id: String, modelID: String?)
}

/// Global review-before-push settings (`AppConfig.Changes.codeReview`).
public struct CodeReviewSettings: Codable, Equatable, Sendable {
    public var reviewer: ReviewerChoice
    public var prompt: String

    public static let defaultPrompt = """
        Review the change below as a senior engineer on this codebase. Report only problems worth fixing before this ships:
        - correctness bugs and regressions
        - missing or swallowed error handling
        - security problems
        - leftover debug code, commented-out code and temporary markers
        - tests that don't test what they claim

        One finding per problem, each with a concrete fix. Skip style nits that a linter or formatter would catch, and don't praise the change.
        """

    private enum CodingKeys: String, CodingKey {
        case reviewer, prompt
    }

    public init(reviewer: ReviewerChoice = .sameAsSession, prompt: String = CodeReviewSettings.defaultPrompt) {
        self.reviewer = reviewer
        self.prompt = prompt
    }

    /// Tolerant: a missing or malformed field keeps its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reviewer = (try? c.decode(ReviewerChoice.self, forKey: .reviewer)) ?? .sameAsSession
        prompt = (try? c.decode(String.self, forKey: .prompt)) ?? Self.defaultPrompt
    }
}

/// Per-project review settings (`ProjectConfig.codeReview`).
public struct ProjectCodeReviewSettings: Codable, Equatable, Sendable {
    /// Nil inherits the global reviewer.
    public var reviewer: ReviewerChoice?
    /// Added to the global prompt, after `.alas/code-review.md`.
    public var instructions: String

    public var isEmpty: Bool {
        reviewer == nil && instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case reviewer, instructions
    }

    public init(reviewer: ReviewerChoice? = nil, instructions: String = "") {
        self.reviewer = reviewer
        self.instructions = instructions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reviewer = try? c.decode(ReviewerChoice.self, forKey: .reviewer)
        instructions = (try? c.decode(String.self, forKey: .instructions)) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(reviewer, forKey: .reviewer)
        try c.encode(instructions, forKey: .instructions)
    }
}

/// The agent and model a review round runs with.
public struct ResolvedReviewer: Equatable, Sendable {
    public let agentID: String
    public let modelID: String?

    public init(agentID: String, modelID: String?) {
        self.agentID = agentID
        self.modelID = modelID
    }
}

public enum ReviewerResolver {
    /// Ship choice, else project, else global. `.sameAsSession` resolves to the owner's agent with no model.
    public static func resolve(
        ship: ReviewerChoice?,
        project: ProjectCodeReviewSettings?,
        global: CodeReviewSettings,
        ownerAgentID: String
    ) -> ResolvedReviewer {
        switch ship ?? project?.reviewer ?? global.reviewer {
        case .sameAsSession:
            ResolvedReviewer(agentID: ownerAgentID, modelID: nil)
        case let .agent(id, modelID):
            ResolvedReviewer(agentID: id, modelID: modelID)
        }
    }
}
