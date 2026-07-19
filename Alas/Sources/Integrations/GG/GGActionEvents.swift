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
    case summary
    case error(message: String)

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
        func message(default fallback: String) -> String {
            if let message = eventObject["message"] as? String, !message.isEmpty { return message }
            if let error = eventObject["error"] as? String, !error.isEmpty { return error }
            if let error = eventObject["error"], !(error is NSNull) { return String(describing: error) }
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
        case "summary":
            if let entries = eventObject["entries"] as? [[String: Any]] {
                for entry in entries {
                    if let error = entry["error"], !(error is NSNull) {
                        let prefix = (entry["position"] as? Int).map { "[\($0)] " } ?? ""
                        return .error(message: prefix + String(describing: error))
                    }
                }
            }
            return .summary
        case "error":
            return .error(message: message(default: "gg reported an error"))
        default:
            if event.hasSuffix("_error") {
                return .error(message: message(default: "gg reported \(event)"))
            }
            return nil
        }
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
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let land = object["land"] as? [String: Any],
           let error = land["error"], !(error is NSNull)
        {
            throw GGServiceError.commandFailed(stderr: String(describing: error))
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
}
