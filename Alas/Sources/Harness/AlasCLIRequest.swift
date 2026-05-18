import Foundation

enum AlasCLIRequestError: Error, Equatable {
    case malformed
    case unsupportedKind
    case unsupportedVersion
    case unsupportedCommand
    case missingSession
    case missingPaths
}

struct AlasCLIRequest: Equatable {
    enum Command: String, Equatable {
        case open
    }

    let version: Int
    let command: Command
    let sessionId: String
    let paths: [String]

    private struct Raw: Decodable {
        var v: Int?
        var kind: String?
        var command: String?
        var session_id: String?
        var paths: [String]?
    }

    static func decode(from data: Data) throws -> AlasCLIRequest {
        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: data)
        } catch {
            throw AlasCLIRequestError.malformed
        }
        guard raw.kind == "cli" else { throw AlasCLIRequestError.unsupportedKind }
        guard raw.v == 1 else { throw AlasCLIRequestError.unsupportedVersion }
        guard let commandString = raw.command,
              let command = Command(rawValue: commandString) else {
            throw AlasCLIRequestError.unsupportedCommand
        }
        guard let sessionId = raw.session_id,
              !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AlasCLIRequestError.missingSession
        }
        guard let paths = raw.paths,
              !paths.isEmpty,
              paths.allSatisfy({
                  let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                  return !trimmed.isEmpty && URL(fileURLWithPath: trimmed).path == trimmed && trimmed.hasPrefix("/")
              }) else {
            throw AlasCLIRequestError.missingPaths
        }
        return AlasCLIRequest(version: 1, command: command, sessionId: sessionId, paths: paths)
    }
}

enum AlasCLIResponse: Equatable {
    case ok
    case error(String)

    func encode() throws -> Data {
        let object: [String: Any]
        switch self {
        case .ok:
            object = ["ok": true]
        case .error(let message):
            object = ["ok": false, "error": message]
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
