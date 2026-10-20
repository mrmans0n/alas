import Foundation

/// Agent-specific ask-user requests normalized for the Alas UI. V1 is wired
/// to Cursor's documented `cursor/ask_question` method.
public struct ACPQuestionRequestParams: Codable, Equatable, Sendable {
    public let toolCallId: String
    public let title: String?
    public let questions: [ACPQuestion]

    public init(toolCallId: String, title: String?, questions: [ACPQuestion]) {
        self.toolCallId = toolCallId
        self.title = title
        self.questions = questions
    }
}

public struct ACPQuestion: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let prompt: String
    public let options: [ACPQuestionOption]
    public let allowMultiple: Bool?

    public init(id: String, prompt: String, options: [ACPQuestionOption], allowMultiple: Bool?) {
        self.id = id
        self.prompt = prompt
        self.options = options
        self.allowMultiple = allowMultiple
    }
}

public struct ACPQuestionOption: Codable, Equatable, Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct ACPQuestionAnswer: Codable, Equatable, Sendable {
    public let questionId: String
    public let selectedOptionIds: [String]

    public init(questionId: String, selectedOptionIds: [String]) {
        self.questionId = questionId
        self.selectedOptionIds = selectedOptionIds
    }
}

public struct ACPQuestionResponse: Codable, Equatable, Sendable {
    public let outcome: ACPQuestionOutcome

    public init(outcome: ACPQuestionOutcome) {
        self.outcome = outcome
    }
}

public enum ACPQuestionOutcome: Equatable, Sendable {
    case answered(answers: [ACPQuestionAnswer])
    case skipped(reason: String?)
    case cancelled
}

extension ACPQuestionOutcome: Codable {
    private enum CodingKeys: String, CodingKey {
        case outcome
        case answers
        case reason
    }

    private enum Kind: String, Codable {
        case answered
        case skipped
        case cancelled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .outcome) {
        case .answered:
            self = .answered(answers: try c.decode([ACPQuestionAnswer].self, forKey: .answers))
        case .skipped:
            self = .skipped(reason: try c.decodeIfPresent(String.self, forKey: .reason))
        case .cancelled:
            self = .cancelled
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .answered(let answers):
            try c.encode(Kind.answered, forKey: .outcome)
            try c.encode(answers, forKey: .answers)
        case .skipped(let reason):
            try c.encode(Kind.skipped, forKey: .outcome)
            try c.encodeIfPresent(reason, forKey: .reason)
        case .cancelled:
            try c.encode(Kind.cancelled, forKey: .outcome)
        }
    }
}

public struct ACPQuestionRequest: Sendable {
    public let id: JSONRPCID
    public let params: ACPQuestionRequestParams

    public init(id: JSONRPCID, params: ACPQuestionRequestParams) {
        self.id = id
        self.params = params
    }
}

public struct ACPCursorPlanPhase: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let todos: [ACPCursorTodo]

    public var id: String { name }

    public init(name: String, todos: [ACPCursorTodo]) {
        self.name = name
        self.todos = todos
    }
}

public struct ACPCursorCreatePlanParams: Codable, Equatable, Sendable {
    public let toolCallId: String
    public let name: String
    public let overview: String
    public let plan: String
    public let todos: [ACPCursorTodo]
    public let isProject: Bool
    public let phases: [ACPCursorPlanPhase]

    public init(toolCallId: String, name: String, overview: String, plan: String, todos: [ACPCursorTodo], isProject: Bool, phases: [ACPCursorPlanPhase]) {
        self.toolCallId = toolCallId
        self.name = name
        self.overview = overview
        self.plan = plan
        self.todos = todos
        self.isProject = isProject
        self.phases = phases
    }
}

public struct ACPCursorPlanRequest: Sendable {
    public let id: JSONRPCID
    public let params: ACPCursorCreatePlanParams

    public init(id: JSONRPCID, params: ACPCursorCreatePlanParams) {
        self.id = id
        self.params = params
    }
}

public struct ACPCursorPlanResponse: Codable, Equatable, Sendable {
    public let outcome: Outcome

    public enum Outcome: Codable, Equatable, Sendable {
        case accepted(planUri: String)
        case rejected(reason: String)
        case cancelled

        private enum CodingKeys: String, CodingKey {
            case outcome
            case planUri
            case reason
        }

        private enum Kind: String, Codable {
            case accepted
            case rejected
            case cancelled
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .outcome) {
            case .accepted:
                self = .accepted(planUri: try container.decode(String.self, forKey: .planUri))
            case .rejected:
                self = .rejected(reason: try container.decode(String.self, forKey: .reason))
            case .cancelled:
                self = .cancelled
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .accepted(let planUri):
                try container.encode(Kind.accepted, forKey: .outcome)
                try container.encode(planUri, forKey: .planUri)
            case .rejected(let reason):
                try container.encode(Kind.rejected, forKey: .outcome)
                try container.encode(reason, forKey: .reason)
            case .cancelled:
                try container.encode(Kind.cancelled, forKey: .outcome)
            }
        }
    }

    public init(outcome: Outcome) {
        self.outcome = outcome
    }
}

public struct ACPCursorUpdateTodosParams: Codable, Equatable, Sendable {
    public let toolCallId: String
    public let todos: [ACPCursorTodo]
    public let merge: Bool

    public init(toolCallId: String, todos: [ACPCursorTodo], merge: Bool) {
        self.toolCallId = toolCallId
        self.todos = todos
        self.merge = merge
    }
}

extension ACPCursorUpdateTodosParams {
    public func mergedTodos(with current: [ACPCursorTodo]) -> [ACPCursorTodo] {
        guard merge else { return todos }

        var merged = current
        for todo in todos {
            if let index = merged.firstIndex(where: { $0.id == todo.id }) {
                merged[index] = todo
            } else {
                merged.append(todo)
            }
        }
        return merged
    }
}

public struct ACPCursorUpdateTodosResponse: Codable, Equatable, Sendable {
    public let outcome: Outcome

    public struct Outcome: Codable, Equatable, Sendable {
        public let outcome = "accepted"
        public let todos: [ACPCursorTodo]

        public init(todos: [ACPCursorTodo]) {
            self.todos = todos
        }
    }

    public init(outcome: Outcome) {
        self.outcome = outcome
    }
}

public struct ACPCursorTaskParams: Codable, Equatable, Sendable {
    public let toolCallId: String
    public let agentId: String
    public let durationMs: Int

    public init(toolCallId: String, agentId: String, durationMs: Int) {
        self.toolCallId = toolCallId
        self.agentId = agentId
        self.durationMs = durationMs
    }
}

public struct ACPCursorTaskResponse: Codable, Equatable, Sendable {
    public let outcome: Outcome

    public struct Outcome: Codable, Equatable, Sendable {
        public let outcome = "completed"
        public let agentId: String
        public let durationMs: Int

        public init(agentId: String, durationMs: Int) {
            self.agentId = agentId
            self.durationMs = durationMs
        }
    }

    public init(outcome: Outcome) {
        self.outcome = outcome
    }
}

public struct ACPCursorGenerateImageParams: Codable, Equatable, Sendable {
    public let toolCallId: String
    public let filePath: String

    public init(toolCallId: String, filePath: String) {
        self.toolCallId = toolCallId
        self.filePath = filePath
    }
}

public struct ACPCursorGenerateImageResponse: Codable, Equatable, Sendable {
    public let outcome: Outcome

    public struct Outcome: Codable, Equatable, Sendable {
        public let outcome = "generated"
        public let filePath: String
        public let imageData: String

        public init(filePath: String, imageData: String) {
            self.filePath = filePath
            self.imageData = imageData
        }
    }

    public init(outcome: Outcome) {
        self.outcome = outcome
    }
}
