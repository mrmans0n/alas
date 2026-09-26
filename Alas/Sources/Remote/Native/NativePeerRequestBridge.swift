import Foundation

/// Maps forwarded peer requests onto the local ACP prompt models, and the
/// prompts' replies back onto the wire actions the gateway accepts. Pure
/// value mapping so the peer pane can host `ACPUserInputPrompt` and
/// `ACPPlanApprovalPrompt` unchanged.
enum NativePeerRequestBridge {
    // MARK: Questions

    static func userInputRequest(question payload: RemoteQuestionPayload) -> ACPUserInputRequest {
        let params = ACPQuestionRequestParams(
            toolCallId: "",
            title: payload.title,
            questions: payload.questions.map { question in
                ACPQuestion(
                    id: question.id,
                    prompt: question.prompt,
                    options: question.options.map { ACPQuestionOption(id: $0.id, label: $0.label) },
                    allowMultiple: question.allowMultiple
                )
            }
        )
        var request = ACPUserInputRequest.cursor(ACPQuestionRequest(id: .number(payload.requestId), params: params))
        // `cursor(_:)` mints a random id; pin it to the wire request so a
        // re-mapped payload keeps the prompt's form state instead of
        // re-seeding it on every transcript update.
        request = .init(
            id: stableToken(for: payload.requestId),
            source: request.source,
            title: request.title,
            message: request.message,
            fields: request.fields,
            mode: request.mode
        )
        return request
    }

    /// Nil when the prompt's action cannot be expressed on the wire: the
    /// gateway only accepts complete answers, never a skip or a cancel.
    static func questionAnswers(
        for action: ACPUserInputAction,
        question payload: RemoteQuestionPayload
    ) -> [RemoteQuestionAnswer]? {
        guard case .submit(let content) = action else { return nil }
        return payload.questions.compactMap { question in
            switch content[question.id] {
            case .string(let value):
                return RemoteQuestionAnswer(questionId: question.id, selectedOptionIds: [value])
            case .strings(let values):
                return RemoteQuestionAnswer(questionId: question.id, selectedOptionIds: values)
            default:
                return nil
            }
        }
    }

    // MARK: Elicitations

    /// Nil when the peer forwarded a mode the local prompt cannot render, or
    /// a URL elicitation whose target is not an http(s) host.
    static func userInputRequest(elicitation payload: RemoteElicitationPayload) -> ACPUserInputRequest? {
        let params = ACPElicitationRequestParams(
            mode: payload.mode, message: payload.message,
            elicitationId: payload.elicitationId, url: payload.url
        )
        let source = ACPUserInputRequest.Source.elicitation(id: .string(payload.requestId), params: params)
        let id = UUID(uuidString: payload.requestId) ?? stableToken(for: payload.requestId.hashValue)
        switch payload.mode {
        case "form":
            let fields = payload.fields.map { field in
                ACPUserInputField(
                    key: field.key,
                    required: field.required,
                    schema: .init(
                        type: field.type,
                        title: field.title,
                        description: field.description,
                        minLength: field.minLength,
                        maxLength: field.maxLength,
                        pattern: field.pattern,
                        format: field.format,
                        minimum: field.minimum,
                        maximum: field.maximum,
                        minItems: field.minItems,
                        maxItems: field.maxItems,
                        options: field.options.map {
                            ACPElicitationOption(const: $0.value, title: $0.title, description: $0.description)
                        },
                        defaultValue: field.defaultValue.map(anyCodable),
                        isSecret: field.isSecret
                    )
                )
            }
            return .init(id: id, source: source, title: payload.title, message: payload.message,
                         fields: fields, mode: .form)
        case "url":
            guard let elicitationId = payload.elicitationId,
                  let rawURL = payload.url,
                  let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil
            else { return nil }
            return .init(id: id, source: source, title: nil, message: payload.message,
                         fields: [], mode: .url(.init(elicitationId: elicitationId, url: url)))
        default:
            return nil
        }
    }

    static func elicitationReply(
        for action: ACPUserInputAction
    ) -> (action: String, content: [String: ACPElicitationValue]?) {
        switch action {
        case .submit(let content): ("accept", content)
        case .decline: ("decline", nil)
        case .cancel: ("cancel", nil)
        }
    }

    // MARK: Plans

    static func planParams(_ payload: RemotePlanPayload) -> ACPCursorCreatePlanParams {
        ACPCursorCreatePlanParams(
            toolCallId: payload.toolCallId,
            name: payload.name,
            overview: payload.overview,
            plan: payload.plan,
            todos: payload.todos.map(todo),
            isProject: payload.isProject,
            phases: payload.phases.map { ACPCursorPlanPhase(name: $0.name, todos: $0.todos.map(todo)) }
        )
    }

    static func planReply(_ response: ACPCursorPlanResponse) -> (action: String, reason: String?) {
        switch response.outcome {
        case .accepted: ("accept", nil)
        case .rejected(let reason): ("reject", reason.trimmingCharacters(in: .whitespacesAndNewlines))
        case .cancelled: ("cancel", nil)
        }
    }

    // MARK: Helpers

    private static func todo(_ todo: RemotePlanTodo) -> ACPCursorTodo {
        ACPCursorTodo(id: todo.id, content: todo.content, status: todo.status)
    }

    private static func anyCodable(_ value: ACPElicitationValue) -> AnyCodable {
        switch value {
        case .string(let value): AnyCodable(value)
        case .integer(let value): AnyCodable(value)
        case .number(let value): AnyCodable(value)
        case .boolean(let value): AnyCodable(value)
        case .strings(let values): AnyCodable(values)
        }
    }

    /// A deterministic `UUID` for an integer wire id, so the same request
    /// maps to the same prompt identity across transcript updates.
    private static func stableToken(for value: Int) -> UUID {
        let magnitude = UInt64(bitPattern: Int64(value))
        return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", magnitude & 0xFFFF_FFFF_FFFF)) ?? UUID()
    }
}
