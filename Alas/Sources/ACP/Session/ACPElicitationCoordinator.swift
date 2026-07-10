import AppKit
import Foundation

@MainActor
final class ACPElicitationCoordinator {
    private let session: ACPSession
    private let client: ACPClient
    private let launchBrowser: (URL) async -> Bool
    private let navigateURL: (URL) -> Void
    private let onInputResolved: () -> Void
    private var questionsTask: Task<Void, Never>?
    private var elicitationsTask: Task<Void, Never>?
    private var completionsTask: Task<Void, Never>?
    private var pendingByToken: [UUID: ACPUserInputRequest] = [:]
    private var pendingInputPreviousStreamingState: ACPSession.StreamingState?
    private var didStop = false

    init(
        session: ACPSession,
        client: ACPClient,
        launchBrowser: @escaping (URL) async -> Bool = { url in
            guard let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
                return false
            }
            return await withCheckedContinuation { continuation in
                NSWorkspace.shared.openApplication(
                    at: applicationURL,
                    configuration: .init()
                ) { application, error in
                    continuation.resume(returning: application != nil && error == nil)
                }
            }
        },
        navigateURL: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
        onInputResolved: @escaping () -> Void = {}
    ) {
        self.session = session
        self.client = client
        self.launchBrowser = launchBrowser
        self.navigateURL = navigateURL
        self.onInputResolved = onInputResolved
    }

    func start() {
        guard questionsTask == nil, elicitationsTask == nil else { return }
        questionsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await request in client.questionRequests {
                enqueue(.cursor(request))
            }
        }
        elicitationsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await request in client.elicitationRequests {
                handleElicitation(request)
            }
            if !Task.isCancelled { cancelAll() }
        }
        completionsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await completion in client.elicitationCompletions {
                session.transcript.urlElicitationWaits.removeAll {
                    $0.id == completion.elicitationId
                }
            }
        }
    }

    func stop() {
        guard !didStop else { return }
        didStop = true
        questionsTask?.cancel()
        elicitationsTask?.cancel()
        completionsTask?.cancel()
        cancelAll()
        session.transcript.urlElicitationWaits.removeAll()
    }

    func respond(to token: UUID, action: ACPUserInputAction) {
        guard let request = removePending(token: token) else { return }
        switch request.source {
        case .cursor(let id, let params):
            client.respondToQuestion(
                id: id,
                response: Self.cursorResponse(action: action, params: params)
            )
        case .elicitation(let id, _):
            let response: ACPElicitationResponse
            if case .submit = action, case .url(let urlRequest) = request.mode {
                session.transcript.urlElicitationWaits.append(.init(
                    id: urlRequest.elicitationId,
                    requestId: token,
                    message: request.message,
                    url: urlRequest.url
                ))
                response = .accept()
            } else {
                response = Self.elicitationResponse(action)
            }
            client.respondToElicitation(id: id, result: .success(response))
        }
        onInputResolved()
    }

    func respondToCursor(id: JSONRPCID, response: ACPQuestionResponse) {
        guard let request = session.transcript.pendingUserInputs.first(where: {
            if case .cursor(let requestId, _) = $0.source { return requestId == id }
            return false
        }) else { return }
        let action: ACPUserInputAction
        switch response.outcome {
        case .answered(let answers):
            var content: [String: ACPElicitationValue] = [:]
            for answer in answers {
                content[answer.questionId] = answer.selectedOptionIds.count == 1
                    ? .string(answer.selectedOptionIds[0])
                    : .strings(answer.selectedOptionIds)
            }
            action = .submit(content)
        case .skipped:
            action = .decline
        case .cancelled:
            action = .cancel
        }
        respond(to: request.id, action: action)
    }

    @discardableResult
    func openURL(for token: UUID) async -> Bool {
        guard let request = pendingByToken[token],
              case .url(let urlRequest) = request.mode,
              await launchBrowser(urlRequest.url)
        else { return false }

        guard removePending(token: token) != nil else { return false }
        client.respondToElicitation(id: request.jsonRPCID, result: .success(.accept()))
        session.transcript.urlElicitationWaits.append(.init(
            id: urlRequest.elicitationId,
            requestId: token,
            message: request.message,
            url: urlRequest.url
        ))
        onInputResolved()
        navigateURL(urlRequest.url)
        return true
    }

    func dismissURLWait(elicitationId: String) {
        session.transcript.urlElicitationWaits.removeAll { $0.id == elicitationId }
    }

    func cancelPendingInputs() {
        cancelAll()
    }

    private func handleElicitation(_ request: ACPElicitationRequest) {
        guard request.params.hasExactlyOneScope,
              scopeMatches(request.params),
              let normalized = ACPUserInputRequest.elicitation(request)
        else {
            client.respondToElicitation(
                id: request.id,
                result: .failure(.init(code: -32602, message: "Invalid elicitation parameters", data: nil))
            )
            return
        }
        if case .url(let urlRequest) = normalized.mode,
           (session.transcript.urlElicitationWaits.contains(where: { $0.id == urlRequest.elicitationId })
            || pendingByToken.values.contains(where: {
                if case .url(let active) = $0.mode {
                    return active.elicitationId == urlRequest.elicitationId
                }
                return false
            })) {
            client.respondToElicitation(
                id: request.id,
                result: .failure(.init(code: -32602, message: "Duplicate elicitation ID", data: nil))
            )
            return
        }
        enqueue(normalized)
    }

    private func scopeMatches(_ params: ACPElicitationRequestParams) -> Bool {
        if let requestId = params.requestId {
            return client.hasPendingOutboundRequest(id: requestId)
        }
        guard let requestedSessionId = params.sessionId else { return false }
        guard let remoteSessionId = session.remoteSessionId else {
            // This connection owns exactly one local session. The agent may
            // elicit while completing session/new, before its session id has
            // reached the client in the RPC result.
            return true
        }
        return requestedSessionId == remoteSessionId
    }

    private func enqueue(_ request: ACPUserInputRequest) {
        guard !didStop else {
            cancel(request)
            return
        }
        let wasEmpty = pendingByToken.isEmpty
        pendingByToken[request.id] = request
        session.transcript.pendingUserInputs.append(request)
        if wasEmpty, session.transcript.streamingState == .idle {
            pendingInputPreviousStreamingState = .idle
            session.transcript.streamingState = .awaitingInput
        }
        if case .cursor(let id, let params) = request.source,
           session.transcript.pendingQuestion == nil {
            session.transcript.pendingQuestion = .init(id: id, params: params)
        }
    }

    private func removePending(token: UUID) -> ACPUserInputRequest? {
        guard let request = pendingByToken.removeValue(forKey: token) else { return nil }
        session.transcript.pendingUserInputs.removeAll { $0.id == token }
        if case .cursor = request.source {
            session.transcript.pendingQuestion = session.transcript.pendingUserInputs.compactMap {
                if case .cursor(let id, let params) = $0.source {
                    return ACPSession.PendingQuestion(id: id, params: params)
                }
                return nil
            }.first
        }
        restoreStreamingStateIfResolved()
        return request
    }

    private func cancelAll() {
        let pending = session.transcript.pendingUserInputs
        pendingByToken.removeAll()
        session.transcript.pendingUserInputs.removeAll()
        session.transcript.pendingQuestion = nil
        restoreStreamingStateIfResolved()
        for request in pending { cancel(request) }
    }

    private func restoreStreamingStateIfResolved() {
        guard pendingByToken.isEmpty else { return }
        if session.transcript.streamingState == .awaitingInput {
            session.transcript.streamingState = pendingInputPreviousStreamingState ?? .idle
        }
        pendingInputPreviousStreamingState = nil
    }

    private func cancel(_ request: ACPUserInputRequest) {
        switch request.source {
        case .cursor(let id, _):
            client.respondToQuestion(id: id, response: .init(outcome: .cancelled))
        case .elicitation(let id, _):
            client.respondToElicitation(id: id, result: .success(.cancel))
        }
    }

    private static func elicitationResponse(_ action: ACPUserInputAction) -> ACPElicitationResponse {
        switch action {
        case .submit(let content): return .accept(content)
        case .decline: return .decline
        case .cancel: return .cancel
        }
    }

    private static func cursorResponse(
        action: ACPUserInputAction,
        params: ACPQuestionRequestParams
    ) -> ACPQuestionResponse {
        switch action {
        case .submit(let content):
            let answers = params.questions.compactMap { question -> ACPQuestionAnswer? in
                let values: [String]
                switch content[question.id] {
                case .string(let value): values = [value]
                case .strings(let selected): values = selected
                default: return nil
                }
                return .init(questionId: question.id, selectedOptionIds: values)
            }
            return .init(outcome: .answered(answers: answers))
        case .decline:
            return .init(outcome: .skipped(reason: nil))
        case .cancel:
            return .init(outcome: .cancelled)
        }
    }
}

private extension ACPUserInputRequest {
    var jsonRPCID: JSONRPCID {
        switch source {
        case .cursor(let id, _), .elicitation(let id, _): return id
        }
    }
}
