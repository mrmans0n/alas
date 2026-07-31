import Foundation

/// A single streamed event from `gg sync --jsonl`. Parsed per line;
/// unknown/blank/malformed lines yield nil and are skipped (tolerant, like
/// the phase-1 stack models).
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
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        let eventObject: [String: Any]
        if object["event"] == nil, let sync = object["sync"] as? [String: Any] {
            eventObject = sync
        } else {
            eventObject = object
        }
        let event = object["event"] as? String ?? (eventObject["entries"] == nil ? "" : "summary")
        guard !event.isEmpty else { return nil }
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
            guard let total = int("total_entries") else { return nil }
            return .start(totalEntries: total)
        case "entry_started":
            guard let pos = int("position"), let title = eventObject["title"] as? String else { return nil }
            return .entryStarted(position: pos, title: title)
        case "push_started":
            guard let pos = int("position") else { return nil }
            return .pushStarted(position: pos)
        case "push_done":
            guard let pos = int("position") else { return nil }
            return .pushDone(position: pos, forced: object["forced"] as? Bool ?? false)
        case "pr_created":
            guard let pos = int("position"), let number = int("pr_number") else { return nil }
            return .prCreated(
                position: pos,
                prNumber: number,
                prURL: eventObject["pr_url"] as? String,
                draft: eventObject["draft"] as? Bool ?? false
            )
        case "pr_updated":
            guard let pos = int("position"),
                  let number = int("pr_number"),
                  let action = eventObject["action"] as? String
            else { return nil }
            return .prUpdated(position: pos, prNumber: number, action: action)
        case "pr_skipped_closed":
            guard let pos = int("position"), let number = int("pr_number") else { return nil }
            return .prSkippedClosed(position: pos, prNumber: number)
        case "summary":
            if let entries = eventObject["entries"] as? [[String: Any]] {
                for entry in entries {
                    if let error = message(from: entry["error"]) {
                        return .error(position: entry["position"] as? Int, operation: nil, message: error)
                    }
                }
            }
            return .summary
        case "error":
            return .error(
                position: int("position"),
                operation: nil,
                message: message(default: "gg reported an error")
            )
        default:
            if event.hasSuffix("_error") {
                return .error(
                    position: int("position"),
                    operation: String(event.dropLast("_error".count)),
                    message: message(default: "gg reported \(event)")
                )
            }
            return nil
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
struct GGLandResult: Equatable {
    let landed: [GGLandedEntry]

    private struct Envelope: Decodable {
        struct Land: Decodable { let landed: [GGLandedEntry] }
        let land: Land
    }

    static func decode(fromJSON data: Data) throws -> GGLandResult {
        if let message = GGActionErrorMessage.parse(fromJSON: data) {
            throw GGServiceError.commandFailed(stderr: message)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            let envelope = try decoder.decode(Envelope.self, from: data)
            return GGLandResult(landed: envelope.land.landed)
        } catch {
            throw GGServiceError.malformedOutput(String(describing: error))
        }
    }
}

struct GGLandedEntry: Equatable, Decodable {
    let position: Int
    let prNumber: Int?
    var action: String? = nil
}
