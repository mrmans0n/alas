import Foundation

/// Agent-specific ask-user requests normalized for the Alas UI. V1 is wired
/// to Cursor's documented `cursor/ask_question` method.
struct ACPQuestionRequestParams: Codable, Equatable {
    let toolCallId: String
    let title: String?
    let questions: [ACPQuestion]
}

struct ACPQuestion: Codable, Equatable, Identifiable {
    let id: String
    let prompt: String
    let options: [ACPQuestionOption]
    let allowMultiple: Bool?
}

struct ACPQuestionOption: Codable, Equatable, Identifiable, Hashable {
    let id: String
    let label: String
}

struct ACPQuestionAnswer: Codable, Equatable {
    let questionId: String
    let selectedOptionIds: [String]
}

struct ACPQuestionResponse: Codable, Equatable {
    let outcome: ACPQuestionOutcome
}

enum ACPQuestionOutcome: Equatable {
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

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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

struct ACPQuestionRequest {
    let id: JSONRPCID
    let params: ACPQuestionRequestParams
}

struct ACPCursorTodo: Codable, Equatable, Identifiable {
    let id: String
    let content: String
    let status: String
}

struct ACPCursorPlanPhase: Codable, Equatable, Identifiable {
    let name: String
    let todos: [ACPCursorTodo]

    var id: String { name }
}

struct ACPCursorCreatePlanParams: Codable, Equatable {
    let toolCallId: String
    let name: String
    let overview: String
    let plan: String
    let todos: [ACPCursorTodo]
    let isProject: Bool
    let phases: [ACPCursorPlanPhase]
}

struct ACPCursorPlanRequest {
    let id: JSONRPCID
    let params: ACPCursorCreatePlanParams
}

struct ACPCursorPlanResponse: Codable, Equatable {
    let outcome: Outcome

    enum Outcome: Codable, Equatable {
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

        init(from decoder: Decoder) throws {
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

        func encode(to encoder: Encoder) throws {
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
}

struct ACPCursorUpdateTodosParams: Codable, Equatable {
    let toolCallId: String
    let todos: [ACPCursorTodo]
    let merge: Bool
}

struct ACPCursorUpdateTodosResponse: Codable, Equatable {
    let outcome: Outcome

    struct Outcome: Codable, Equatable {
        let outcome = "accepted"
        let todos: [ACPCursorTodo]
    }
}

struct ACPCursorTaskParams: Codable, Equatable {
    let toolCallId: String
    let agentId: String
    let durationMs: Int
}

struct ACPCursorTaskResponse: Codable, Equatable {
    let outcome: Outcome

    struct Outcome: Codable, Equatable {
        let outcome = "completed"
        let agentId: String
        let durationMs: Int
    }
}

struct ACPCursorGenerateImageParams: Codable, Equatable {
    let toolCallId: String
    let filePath: String
}

struct ACPCursorGenerateImageResponse: Codable, Equatable {
    let outcome: Outcome

    struct Outcome: Codable, Equatable {
        let outcome = "generated"
        let filePath: String
        let imageData: String
    }
}
