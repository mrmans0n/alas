import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

/// A streamed event from `gg sync --jsonl`. Lines normally contain one event,
/// while terminal summary envelopes can expand to entry errors followed by
/// `.summary`. Unknown/blank/malformed lines are skipped (tolerant, like the
/// phase-1 stack models).
public enum GGSyncEvent: Equatable, Sendable {
    case start(totalEntries: Int)
    case entryStarted(position: Int, title: String)
    case pushStarted(position: Int)
    case pushDone(position: Int, forced: Bool)
    case prCreated(position: Int, prNumber: Int, prURL: String?, draft: Bool)
    case prUpdated(position: Int, prNumber: Int, action: String)
    case prSkippedClosed(position: Int, prNumber: Int)
    case summary
    case error(position: Int?, operation: String?, message: String)

    public static func parse(line: String) -> GGSyncEvent? {
        parseEvents(line: line).first
    }

    public static func parseEvents(line: String) -> [GGSyncEvent] {
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

public enum GGActionErrorMessage: Sendable {
    private static let responseEnvelopeKeys = [
        "land",
        "sync",
        "clean",
        "drop",
        "unstack",
        "restack",
        "split",
    ]

    public static func parse(fromJSON data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let line = String(data: data, encoding: .utf8),
           case .error(let position, _, let message) = GGSyncEvent.parse(line: line)
        {
            return position.map { "[\($0)] \(message)" } ?? message
        }
        return parse(from: object)
    }

    public static func parse(from object: [String: Any]) -> String? {
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

public enum GGErrorPresentation: Sendable {
    public static func message(for error: Error) -> String {
        if let serviceError = error as? GGServiceError {
            return serviceError.userMessage
        }
        return error.localizedDescription
    }
}

/// Decoded result of `gg land … --json`.
public struct GGLandResult: Equatable, Decodable, Sendable {
    public let stack: String?
    public let base: String?
    public let landed: [GGLandedEntry]
    public let remaining: Int?
    public let cleaned: Bool?
    public let warnings: [String]
    public let error: String?

    private enum CodingKeys: String, CodingKey {
        case stack, base, landed, remaining, cleaned, warnings, error
    }

    public init(
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

    public init(from decoder: Decoder) throws {
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

        public init(land: GGLandResult) {
            self.land = land
        }
    }

    public static func decode(fromJSON data: Data) throws -> GGLandResult {
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

public struct GGLandedEntry: Equatable, Decodable, Sendable {
    public let position: Int
    public var sha: String? = nil
    public var title: String? = nil
    public var ggId: String? = nil
    public let prNumber: Int?
    public var action: String? = nil
    public var error: String? = nil

    public init(position: Int, sha: String? = nil, title: String? = nil, ggId: String? = nil, prNumber: Int?, action: String? = nil, error: String? = nil) {
        self.position = position
        self.sha = sha
        self.title = title
        self.ggId = ggId
        self.prNumber = prNumber
        self.action = action
        self.error = error
    }
}

public enum GGLandPhase: String, Decodable, Equatable, Sendable {
    case readiness
    case mergeTrain = "merge_train"
}

public struct GGLandWait: Decodable, Equatable, Sendable {
    public let position: Int
    public let prNumber: Int
    public let phase: GGLandPhase
    public let poll: Int
    public let elapsedSeconds: Int
    public let ciStatus: String?
    public let approved: Bool?
    public let mergeTrainStatus: String?
    public let mergeTrainPosition: Int?
    public let pipelineRunning: Bool?
    public let error: String?

    public init(position: Int, prNumber: Int, phase: GGLandPhase, poll: Int, elapsedSeconds: Int, ciStatus: String?, approved: Bool?, mergeTrainStatus: String?, mergeTrainPosition: Int?, pipelineRunning: Bool?, error: String?) {
        self.position = position
        self.prNumber = prNumber
        self.phase = phase
        self.poll = poll
        self.elapsedSeconds = elapsedSeconds
        self.ciStatus = ciStatus
        self.approved = approved
        self.mergeTrainStatus = mergeTrainStatus
        self.mergeTrainPosition = mergeTrainPosition
        self.pipelineRunning = pipelineRunning
        self.error = error
    }
}

public enum GGLandEvent: Equatable, Sendable {
    case start(stack: String, base: String, totalEntries: Int)
    case wait(GGLandWait)
    case entry(GGLandedEntry)
    case summary(GGLandResult)
    case error(message: String)

    public static func decode(line: String) throws -> GGLandEvent {
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

    public init(version: Int, command: String, event: String) {
        self.version = version
        self.command = command
        self.event = event
    }
}

private struct GGLandStartPayload: Decodable {
    let stack: String
    let base: String
    let totalEntries: Int

    public init(stack: String, base: String, totalEntries: Int) {
        self.stack = stack
        self.base = base
        self.totalEntries = totalEntries
    }
}

private struct GGLandErrorPayload: Decodable {
    let message: String

    public init(message: String) {
        self.message = message
    }
}
