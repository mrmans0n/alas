import Foundation

/// A streamed event from `gg sync --jsonl`. Lines normally contain one event,
/// while terminal summary envelopes can expand to entry errors followed by
/// `.summary`. Unknown/blank/malformed lines are skipped (tolerant, like the
/// phase-1 stack models).
enum GGSyncEvent: Equatable {
    case start(totalEntries: Int)
    case entryStarted(position: Int, title: String)
    case pushStarted(position: Int)
    case pushDone(position: Int, forced: Bool)
    case prCreated(position: Int, prNumber: Int, prURL: String?, draft: Bool)
    case prUpdated(position: Int, prNumber: Int, action: String)
    case prSkippedClosed(position: Int, prNumber: Int)
    case summary
    case error(position: Int?, operation: String?, message: String)

    static func parse(line: String) -> GGSyncEvent? {
        parseEvents(line: line).first
    }

    static func parseEvents(line: String) -> [GGSyncEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }

        let eventObject: [String: Any]
        if object["event"] == nil, let sync = object["sync"] as? [String: Any] {
            eventObject = sync
        } else {
            eventObject = object
        }
        let event = object["event"] as? String ?? (eventObject["entries"] == nil ? "" : "summary")
        guard !event.isEmpty else { return [] }
        func int(_ key: String) -> Int? { eventObject[key] as? Int }
        func message(from error: Any?) -> String? {
            guard let error, !(error is NSNull) else { return nil }
            if let string = error as? String, !string.isEmpty { return string }
            if let object = error as? [String: Any] {
                if let message = object["message"] as? String, !message.isEmpty { return message }
                if let nested = message(from: object["error"]) { return nested }
            }
            return String(describing: error)
        }
        func message(default fallback: String) -> String {
            if let message = eventObject["message"] as? String, !message.isEmpty { return message }
            if let error = message(from: eventObject["error"]) { return error }
            return fallback
        }
        switch event {
        case "start":
            guard let total = int("total_entries") else { return [] }
            return [.start(totalEntries: total)]
        case "entry_started":
            guard let pos = int("position"), let title = eventObject["title"] as? String else { return [] }
            return [.entryStarted(position: pos, title: title)]
        case "push_started":
            guard let pos = int("position") else { return [] }
            return [.pushStarted(position: pos)]
        case "push_done":
            guard let pos = int("position") else { return [] }
            return [.pushDone(position: pos, forced: object["forced"] as? Bool ?? false)]
        case "pr_created":
            guard let pos = int("position"), let number = int("pr_number") else { return [] }
            return [.prCreated(
                position: pos,
                prNumber: number,
                prURL: eventObject["pr_url"] as? String,
                draft: eventObject["draft"] as? Bool ?? false
            )]
        case "pr_updated":
            guard let pos = int("position"),
                  let number = int("pr_number"),
                  let action = eventObject["action"] as? String
            else { return [] }
            return [.prUpdated(position: pos, prNumber: number, action: action)]
        case "pr_skipped_closed":
            guard let pos = int("position"), let number = int("pr_number") else { return [] }
            return [.prSkippedClosed(position: pos, prNumber: number)]
        case "summary":
            var events: [GGSyncEvent] = []
            if let entries = eventObject["entries"] as? [[String: Any]] {
                for entry in entries {
                    if let error = message(from: entry["error"]) {
                        events.append(.error(
                            position: entry["position"] as? Int,
                            operation: nil,
                            message: error
                        ))
                    }
                }
            }
            events.append(.summary)
            return events
        case "error":
            return [.error(
                position: int("position"),
                operation: nil,
                message: message(default: "gg reported an error")
            )]
        default:
            if event.hasSuffix("_error") {
                return [.error(
                    position: int("position"),
                    operation: String(event.dropLast("_error".count)),
                    message: message(default: "gg reported \(event)")
                )]
            }
            return []
        }
    }
}

enum GGActionErrorMessage {
    private static let responseEnvelopeKeys = [
        "land",
        "sync",
        "clean",
        "drop",
        "unstack",
        "restack",
        "split",
    ]

    static func parse(fromJSON data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let line = String(data: data, encoding: .utf8),
           case .error(let position, _, let message) = GGSyncEvent.parse(line: line)
        {
            return position.map { "[\($0)] \(message)" } ?? message
        }
        return parse(from: object)
    }

    static func parse(from object: [String: Any]) -> String? {
        if let message = message(from: object["error"]) { return message }
        for key in responseEnvelopeKeys {
            if let envelope = object[key] as? [String: Any], let message = parse(from: envelope) {
                return message
            }
        }
        if let entries = object["entries"] as? [[String: Any]] {
            for entry in entries {
                if let message = message(from: entry["error"]) {
                    let prefix = (entry["position"] as? Int).map { "[\($0)] " } ?? ""
                    return prefix + message
                }
            }
        }
        return nil
    }

    private static func message(from error: Any?) -> String? {
        guard let error, !(error is NSNull) else { return nil }
        if let string = error as? String, !string.isEmpty { return string }
        if let object = error as? [String: Any] {
            if let message = object["message"] as? String, !message.isEmpty { return message }
            if let nested = message(from: object["error"]) { return nested }
        }
        return String(describing: error)
    }
}

enum GGErrorPresentation {
    static func message(for error: Error) -> String {
        if let serviceError = error as? GGServiceError {
            return serviceError.userMessage
        }
        return error.localizedDescription
    }
}

/// Decoded result of `gg land … --json`.
struct GGLandResult: Equatable, Decodable, Sendable {
    let stack: String?
    let base: String?
    let landed: [GGLandedEntry]
    let remaining: Int?
    let cleaned: Bool?
    let warnings: [String]
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case stack, base, landed, remaining, cleaned, warnings, error
    }

    init(
        stack: String? = nil,
        base: String? = nil,
        landed: [GGLandedEntry],
        remaining: Int? = nil,
        cleaned: Bool? = nil,
        warnings: [String] = [],
        error: String? = nil
    ) {
        self.stack = stack
        self.base = base
        self.landed = landed
        self.remaining = remaining
        self.cleaned = cleaned
        self.warnings = warnings
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stack = try container.decodeIfPresent(String.self, forKey: .stack)
        base = try container.decodeIfPresent(String.self, forKey: .base)
        landed = try container.decode([GGLandedEntry].self, forKey: .landed)
        remaining = try container.decodeIfPresent(Int.self, forKey: .remaining)
        cleaned = try container.decodeIfPresent(Bool.self, forKey: .cleaned)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    private struct Envelope: Decodable {
        let land: GGLandResult
    }

    static func decode(fromJSON data: Data) throws -> GGLandResult {
        if let message = GGActionErrorMessage.parse(fromJSON: data) {
            throw GGServiceError.commandFailed(stderr: message)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            let envelope = try decoder.decode(Envelope.self, from: data)
            return envelope.land
        } catch {
            throw GGServiceError.malformedOutput(String(describing: error))
        }
    }
}

struct GGLandedEntry: Equatable, Decodable, Sendable {
    let position: Int
    var sha: String? = nil
    var title: String? = nil
    var ggId: String? = nil
    let prNumber: Int?
    var action: String? = nil
    var error: String? = nil
}

enum GGLandPhase: String, Decodable, Equatable, Sendable {
    case readiness
    case mergeTrain = "merge_train"
}

struct GGLandWait: Decodable, Equatable, Sendable {
    let position: Int
    let prNumber: Int
    let phase: GGLandPhase
    let poll: Int
    let elapsedSeconds: Int
    let ciStatus: String?
    let approved: Bool?
    let mergeTrainStatus: String?
    let mergeTrainPosition: Int?
    let pipelineRunning: Bool?
    let error: String?
}

enum GGLandEvent: Equatable, Sendable {
    case start(stack: String, base: String, totalEntries: Int)
    case wait(GGLandWait)
    case entry(GGLandedEntry)
    case summary(GGLandResult)
    case error(message: String)

    static func decode(line: String) throws -> GGLandEvent {
        let data = Data(line.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope = try decoder.decode(GGLandEventEnvelope.self, from: data)
        guard envelope.version == 1 else { throw GGServiceError.unsupportedSchema(envelope.version) }
        guard envelope.command == "land" else {
            throw GGServiceError.malformedOutput("Expected gg land event, got \(envelope.command).")
        }
        switch envelope.event {
        case "start":
            let value = try decoder.decode(GGLandStartPayload.self, from: data)
            return .start(stack: value.stack, base: value.base, totalEntries: value.totalEntries)
        case "wait": return .wait(try decoder.decode(GGLandWait.self, from: data))
        case "entry": return .entry(try decoder.decode(GGLandedEntry.self, from: data))
        case "summary": return .summary(try decoder.decode(GGLandResult.self, from: data))
        case "error": return .error(message: try decoder.decode(GGLandErrorPayload.self, from: data).message)
        default: throw GGServiceError.malformedOutput("Unknown gg land event: \(envelope.event)")
        }
    }
}

private struct GGLandEventEnvelope: Decodable {
    let version: Int
    let command: String
    let event: String
}

private struct GGLandStartPayload: Decodable {
    let stack: String
    let base: String
    let totalEntries: Int
}

private struct GGLandErrorPayload: Decodable {
    let message: String
}
