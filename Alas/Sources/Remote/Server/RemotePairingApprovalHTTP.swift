import Foundation

@MainActor
struct RemotePairingApprovalHTTP {
    struct ChallengeRequest: Codable {
        let requester: ApprovalPeer
        let attemptNonce: String
    }

    let coordinator: RemotePairingApprovalCoordinator
    let enabled: () -> Bool

    static func operation(for path: String) -> ApprovalOperation? {
        switch path {
        case "/peer-approval/v1/challenge": .challenge
        case "/peer-approval/v1/submit": .submit
        case "/peer-approval/v1/status": .status
        case "/peer-approval/v1/cancel": .cancel
        default: nil
        }
    }

    func response(for req: HTTPRequest, body: Data) -> Data? {
        guard let operation = Self.operation(for: req.path) else { return nil }
        guard req.headers["origin"] == nil else { return Self.failure(.disabled) }
        guard enabled() else { return Self.failure(.disabled) }
        guard req.method == "POST" else {
            return Self.error("405 Method Not Allowed", "method not allowed")
        }
        guard body.count <= 16 * 1024 else {
            return Self.error("413 Payload Too Large", "request too large")
        }
        do {
            let reply: ApprovalEnvelope
            if operation == .challenge {
                let request = try JSONDecoder().decode(ChallengeRequest.self, from: body)
                reply = try coordinator.challenge(requester: request.requester, attemptNonce: request.attemptNonce)
            } else {
                let request = try JSONDecoder().decode(ApprovalEnvelope.self, from: body)
                guard request.payload.operation == operation else { return Self.failure(.invalid) }
                reply = try coordinator.receive(request)
            }
            return RemoteHTTPResponder.http(status: "200 OK", contentType: "application/json",
                                            body: try JSONEncoder().encode(reply))
        } catch let failure as ApprovalFailure {
            return Self.failure(failure)
        } catch {
            return Self.failure(.invalid)
        }
    }

    static func failure(_ failure: ApprovalFailure) -> Data {
        switch failure {
        case .invalid: error("400 Bad Request", "invalid request")
        case .unauthorized: error("401 Unauthorized", "unauthorized")
        case .disabled: error("403 Forbidden", "approval unavailable")
        case .expired: error("410 Gone", "request expired")
        case .conflict, .capacity: error("409 Conflict", "request conflict")
        case .throttled: error("429 Too Many Requests", "try again later", headers: [("Retry-After", "2")])
        }
    }

    private static func error(_ status: String, _ message: String, headers: [(String, String)] = []) -> Data {
        RemoteHTTPResponder.http(status: status, contentType: "application/json",
                                 body: Data("{\"error\":\"\(message)\"}".utf8), extraHeaders: headers)
    }
}
