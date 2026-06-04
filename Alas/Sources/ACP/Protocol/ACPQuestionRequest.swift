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
