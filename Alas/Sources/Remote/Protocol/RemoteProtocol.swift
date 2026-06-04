import Foundation

struct RemoteModelInfo: Codable, Equatable, Sendable {
    let id: String
    let name: String
}

struct RemoteSessionConfig: Codable, Equatable, Sendable {
    let sessionId: String
    let models: [RemoteModelInfo]
    let modes: [RemoteModelInfo]
    let currentModel: String?
    let currentMode: String?
    let autoRunEnabled: Bool
    let acceptsImages: Bool
}

/// Client → server. `type` discriminates.
enum RemoteClientMessage: Equatable, Sendable {
    case listSessions
    case subscribe(sessionId: String)
    case unsubscribe(sessionId: String)
    case permissionDecision(sessionId: String, requestId: Int, optionId: String, persistScope: String?)
    case questionAnswer(sessionId: String, requestId: Int, answers: [RemoteQuestionAnswer])
    case takeOver(sessionId: String)
    case sendPrompt(sessionId: String, text: String)
    case stop(sessionId: String)
    case setModel(sessionId: String, modelId: String)
    case setMode(sessionId: String, modeId: String)
    case setAutoRun(sessionId: String, enabled: Bool)
}

extension RemoteClientMessage: Codable {
    private enum CodingKeys: String, CodingKey { case type, sessionId, requestId, optionId, persistScope, answers, text, modelId, modeId, enabled }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "listSessions": self = .listSessions
        case "subscribe": self = .subscribe(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "unsubscribe": self = .unsubscribe(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "permissionDecision":
            self = .permissionDecision(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                requestId: try c.decode(Int.self, forKey: .requestId),
                optionId: try c.decode(String.self, forKey: .optionId),
                persistScope: try c.decodeIfPresent(String.self, forKey: .persistScope))
        case "questionAnswer":
            self = .questionAnswer(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                requestId: try c.decode(Int.self, forKey: .requestId),
                answers: try c.decode([RemoteQuestionAnswer].self, forKey: .answers))
        case "takeOver":
            self = .takeOver(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "sendPrompt":
            self = .sendPrompt(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                text: try c.decode(String.self, forKey: .text))
        case "stop":
            self = .stop(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "setModel":
            self = .setModel(sessionId: try c.decode(String.self, forKey: .sessionId), modelId: try c.decode(String.self, forKey: .modelId))
        case "setMode":
            self = .setMode(sessionId: try c.decode(String.self, forKey: .sessionId), modeId: try c.decode(String.self, forKey: .modeId))
        case "setAutoRun":
            self = .setAutoRun(sessionId: try c.decode(String.self, forKey: .sessionId), enabled: try c.decode(Bool.self, forKey: .enabled))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown type \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .listSessions: try c.encode("listSessions", forKey: .type)
        case .subscribe(let s): try c.encode("subscribe", forKey: .type)
        try c.encode(s, forKey: .sessionId)
        case .unsubscribe(let s): try c.encode("unsubscribe", forKey: .type)
        try c.encode(s, forKey: .sessionId)
        case .permissionDecision(let s, let r, let o, let p):
            try c.encode("permissionDecision", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(r, forKey: .requestId)
            try c.encode(o, forKey: .optionId)
            try c.encodeIfPresent(p, forKey: .persistScope)
        case .questionAnswer(let s, let r, let a):
            try c.encode("questionAnswer", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(r, forKey: .requestId)
            try c.encode(a, forKey: .answers)
        case .takeOver(let s):
            try c.encode("takeOver", forKey: .type)
            try c.encode(s, forKey: .sessionId)
        case .sendPrompt(let s, let t):
            try c.encode("sendPrompt", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(t, forKey: .text)
        case .stop(let s):
            try c.encode("stop", forKey: .type)
            try c.encode(s, forKey: .sessionId)
        case .setModel(let id, let m):
            try c.encode("setModel", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(m, forKey: .modelId)
        case .setMode(let id, let m):
            try c.encode("setMode", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(m, forKey: .modeId)
        case .setAutoRun(let id, let e):
            try c.encode("setAutoRun", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(e, forKey: .enabled)
        }
    }
}

/// Server → client. `type` discriminates.
enum RemoteServerMessage: Equatable, Sendable {
    case sessionList(sessions: [RemoteSessionSummary])
    case transcriptSnapshot(sessionId: String, streamingState: String, canDrive: Bool, messages: [RemoteWireMessage])
    case transcriptDelta(sessionId: String, streamingState: String, canDrive: Bool, upserts: [RemoteWireMessage])
    case permissionRequest(sessionId: String, payload: RemotePermissionPayload)
    case permissionResolved(sessionId: String, requestId: Int)
    case questionRequest(sessionId: String, payload: RemoteQuestionPayload)
    case questionResolved(sessionId: String, requestId: Int)
    case sessionClosed(sessionId: String)
    /// The server dropped a `sendPrompt` (caller is no longer the writer, or
    /// the prompt was empty), so the client should restore the user's text
    /// instead of silently losing it.
    case promptRejected(sessionId: String)
    case sessionConfig(RemoteSessionConfig)
    case error(message: String)
}

extension RemoteServerMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, sessions, sessionId, streamingState, canDrive, messages, upserts, payload, requestId, message
        case models, modes, currentModel, currentMode, autoRunEnabled, acceptsImages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "sessionList": self = .sessionList(sessions: try c.decode([RemoteSessionSummary].self, forKey: .sessions))
        case "transcriptSnapshot":
            self = .transcriptSnapshot(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                streamingState: try c.decode(String.self, forKey: .streamingState),
                canDrive: try c.decode(Bool.self, forKey: .canDrive),
                messages: try c.decode([RemoteWireMessage].self, forKey: .messages))
        case "transcriptDelta":
            self = .transcriptDelta(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                streamingState: try c.decode(String.self, forKey: .streamingState),
                canDrive: try c.decode(Bool.self, forKey: .canDrive),
                upserts: try c.decode([RemoteWireMessage].self, forKey: .upserts))
        case "permissionRequest":
            self = .permissionRequest(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                payload: try c.decode(RemotePermissionPayload.self, forKey: .payload))
        case "permissionResolved":
            self = .permissionResolved(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                requestId: try c.decode(Int.self, forKey: .requestId))
        case "questionRequest":
            self = .questionRequest(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                payload: try c.decode(RemoteQuestionPayload.self, forKey: .payload))
        case "questionResolved":
            self = .questionResolved(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                requestId: try c.decode(Int.self, forKey: .requestId))
        case "sessionClosed": self = .sessionClosed(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "promptRejected": self = .promptRejected(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "sessionConfig":
            self = .sessionConfig(RemoteSessionConfig(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                models: try c.decode([RemoteModelInfo].self, forKey: .models),
                modes: try c.decode([RemoteModelInfo].self, forKey: .modes),
                currentModel: try c.decodeIfPresent(String.self, forKey: .currentModel),
                currentMode: try c.decodeIfPresent(String.self, forKey: .currentMode),
                autoRunEnabled: try c.decode(Bool.self, forKey: .autoRunEnabled),
                acceptsImages: try c.decode(Bool.self, forKey: .acceptsImages)))
        case "error": self = .error(message: try c.decode(String.self, forKey: .message))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown type \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sessionList(let s): try c.encode("sessionList", forKey: .type)
        try c.encode(s, forKey: .sessions)
        case .transcriptSnapshot(let id, let st, let cd, let m):
            try c.encode("transcriptSnapshot", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(st, forKey: .streamingState)
            try c.encode(cd, forKey: .canDrive)
            try c.encode(m, forKey: .messages)
        case .transcriptDelta(let id, let st, let cd, let u):
            try c.encode("transcriptDelta", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(st, forKey: .streamingState)
            try c.encode(cd, forKey: .canDrive)
            try c.encode(u, forKey: .upserts)
        case .permissionRequest(let id, let p):
            try c.encode("permissionRequest", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(p, forKey: .payload)
        case .permissionResolved(let id, let r):
            try c.encode("permissionResolved", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(r, forKey: .requestId)
        case .questionRequest(let id, let p):
            try c.encode("questionRequest", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(p, forKey: .payload)
        case .questionResolved(let id, let r):
            try c.encode("questionResolved", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(r, forKey: .requestId)
        case .sessionClosed(let id): try c.encode("sessionClosed", forKey: .type)
        try c.encode(id, forKey: .sessionId)
        case .promptRejected(let id): try c.encode("promptRejected", forKey: .type)
        try c.encode(id, forKey: .sessionId)
        case .sessionConfig(let cfg):
            try c.encode("sessionConfig", forKey: .type)
            try c.encode(cfg.sessionId, forKey: .sessionId)
            try c.encode(cfg.models, forKey: .models)
            try c.encode(cfg.modes, forKey: .modes)
            try c.encodeIfPresent(cfg.currentModel, forKey: .currentModel)
            try c.encodeIfPresent(cfg.currentMode, forKey: .currentMode)
            try c.encode(cfg.autoRunEnabled, forKey: .autoRunEnabled)
            try c.encode(cfg.acceptsImages, forKey: .acceptsImages)
        case .error(let m): try c.encode("error", forKey: .type)
        try c.encode(m, forKey: .message)
        }
    }
}
