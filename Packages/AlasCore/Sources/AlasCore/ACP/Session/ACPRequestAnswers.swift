import Foundation

/// The rules for answering what an agent asked a person: which answers a
/// pending permission, question, plan or form request accepts, and what each
/// one resumes the agent with. Every surface that answers one goes through
/// here, so they cannot drift apart.
public enum ACPRequestAnswers {
    /// How long a permission decision applies.
    public enum PermissionScope: String, Codable, Equatable, Sendable {
        /// What the option itself implies: once for `*_once`, the project for
        /// `*_always`, the session otherwise.
        case optionDefault
        /// This request only.
        case once
        case session
        case project
    }

    public struct PermissionDecision: Equatable, Sendable {
        public let scopeKey: String
        public let optionId: String
        public let decision: ACPPermissionDecision
        public let persistScope: ACPPermissionScopeKind?
    }

    public enum PlanAction: Codable, Equatable, Sendable {
        case accept
        /// Needs a reason that is not blank.
        case reject(reason: String)
        case cancel
    }

    public enum UserInputAnswer: Codable, Equatable, Sendable {
        /// Must satisfy the form: every required field, each value of its
        /// field's type and within its bounds; nothing for a URL request.
        case submit(content: [String: ACPElicitationValue])
        case decline
        case cancel
    }

    /// The decision choosing `optionId` records, or nil when the request
    /// offers no such option. Mirrors the local permission prompt.
    public static func permission(
        _ pending: ACPSession.PendingPermission,
        optionId: String,
        scope: PermissionScope
    ) -> PermissionDecision? {
        guard let option = pending.params.options.first(where: { $0.optionId == optionId }) else { return nil }
        let persistScope: ACPPermissionScopeKind?
        switch scope {
        case .once: persistScope = nil
        case .session: persistScope = .session
        case .project: persistScope = .project
        case .optionDefault:
            switch option.kind {
            case "allow_once", "reject_once": persistScope = nil
            case "allow_always", "reject_always": persistScope = .project
            default: persistScope = .session
            }
        }
        return PermissionDecision(
            scopeKey: scopeKey(for: pending.params),
            optionId: optionId,
            decision: option.kind.hasPrefix("allow") ? .allow : .deny,
            persistScope: persistScope
        )
    }

    /// The key a permission decision is recorded under, the same one the
    /// local prompt uses.
    public static func scopeKey(for params: ACPPermissionRequestParams) -> String {
        "tool:\(params.toolCall.title ?? params.toolCall.toolCallId)"
    }

    /// The question waiting for an answer: the head of the input queue when
    /// it is one, else the session's single pending question.
    @MainActor
    public static func pendingQuestion(in session: ACPSession) -> ACPSession.PendingQuestion? {
        guard let head = session.transcript.pendingUserInputs.first else {
            return session.transcript.pendingQuestion
        }
        guard case .cursor(let id, let params) = head.source else { return nil }
        return .init(id: id, params: params)
    }

    /// The response `answers` give, each question's selection in its option
    /// order, or nil unless every question has a selection of its own options
    /// only, and only one where the question allows one.
    public static func question(_ pending: ACPSession.PendingQuestion, answers: [ACPQuestionAnswer]) -> ACPQuestionResponse? {
        let selectionByQuestion = Dictionary(
            answers.map { ($0.questionId, Set($0.selectedOptionIds)) },
            uniquingKeysWith: { $1 }
        )
        var resolved: [ACPQuestionAnswer] = []
        for question in pending.params.questions {
            let selected = selectionByQuestion[question.id] ?? []
            let offered = question.options.map(\.id)
            guard !selected.isEmpty, selected.isSubset(of: offered),
                  question.allowMultiple == true || selected.count == 1
            else { return nil }
            let ordered = offered.filter { selected.contains($0) }
            resolved.append(ACPQuestionAnswer(questionId: question.id, selectedOptionIds: ordered))
        }
        return .init(outcome: .answered(answers: resolved))
    }

    /// The response `action` gives a pending plan, or nil for a rejection
    /// without a reason.
    public static func plan(_ pending: ACPSession.PendingPlan, action: PlanAction) -> ACPCursorPlanResponse? {
        switch action {
        case .accept:
            return .init(outcome: .accepted(planUri: "alas://plans/\(pending.params.toolCallId)"))
        case .reject(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return .init(outcome: .rejected(reason: trimmed))
        case .cancel:
            return .init(outcome: .cancelled)
        }
    }

    /// The action `answer` takes on a pending form or URL request, or nil
    /// when its content does not satisfy the request.
    public static func userInput(_ pending: ACPUserInputRequest, answer: UserInputAnswer) -> ACPUserInputAction? {
        switch answer {
        case .submit(let content):
            guard Self.content(content, satisfies: pending) else { return nil }
            return .submit(content)
        case .decline:
            return .decline
        case .cancel:
            return .cancel
        }
    }

    private static func content(
        _ content: [String: ACPElicitationValue],
        satisfies request: ACPUserInputRequest
    ) -> Bool {
        if case .url = request.mode { return content.isEmpty }
        let fields = Dictionary(uniqueKeysWithValues: request.fields.map { ($0.key, $0) })
        guard content.keys.allSatisfy({ fields[$0] != nil }) else { return false }
        for field in request.fields where field.required {
            guard content[field.key] != nil else { return false }
        }
        for (key, value) in content {
            guard let field = fields[key] else { return false }
            switch (field.schema.type, value) {
            case ("string", .string(let string)):
                guard validString(string, for: field) else { return false }
            case ("number", .number(let number)):
                guard validNumber(number, for: field) else { return false }
            case ("number", .integer(let integer)):
                guard validNumber(Double(integer), for: field) else { return false }
            case ("integer", .integer(let integer)):
                guard validNumber(Double(integer), for: field) else { return false }
            case ("boolean", .boolean):
                continue
            case ("array", .strings(let selected)):
                let allowed = Set(field.schema.options.map(\.const))
                guard selected.allSatisfy(allowed.contains),
                      field.schema.minItems.map({ selected.count >= $0 }) != false,
                      field.schema.maxItems.map({ selected.count <= $0 }) != false
                else { return false }
            default:
                return false
            }
        }
        return true
    }

    private static func validString(_ value: String, for field: ACPUserInputField) -> Bool {
        guard field.schema.minLength.map({ value.count >= $0 }) != false,
              field.schema.maxLength.map({ value.count <= $0 }) != false
        else { return false }
        if !field.schema.options.isEmpty,
           !field.schema.options.contains(where: { $0.const == value }) {
            return false
        }
        if let pattern = field.schema.pattern,
           let regex = try? NSRegularExpression(pattern: pattern),
           regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) == nil {
            return false
        }
        switch field.schema.format {
        case "email":
            let parts = value.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2 && parts[1].contains(".")
        case "uri":
            return URL(string: value)?.scheme != nil
        case "date":
            return dateFormatter.date(from: value) != nil
        case "date-time":
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractionalFormatter.date(from: value) != nil
                || ISO8601DateFormatter().date(from: value) != nil
        default:
            return true
        }
    }

    private static func validNumber(_ value: Double, for field: ACPUserInputField) -> Bool {
        value.isFinite
            && field.schema.minimum.map({ value >= $0 }) != false
            && field.schema.maximum.map({ value <= $0 }) != false
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()
}
