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
    enum Command: Equatable {
        case open(paths: [String])
        case worktree(WorktreeCommand)
        case review(ReviewCommand)
        case resolve
    }

    enum WorktreeCommand: Equatable {
        case list
        case `switch`(target: String)
        case new(branch: String, base: String?)
        case delete(target: String, force: Bool, keepBranch: Bool)
    }

    enum ReviewCommand: Equatable {
        case localChanges
        case provider(target: String)
    }

    let version: Int
    let sessionId: String?
    let cwd: String?
    let command: Command

    var paths: [String] {
        guard case .open(let paths) = command else { return [] }
        return paths
    }

    private struct Raw: Decodable {
        var v: Int?
        var kind: String?
        var command: String?
        var subcommand: String?
        var session_id: String?
        var cwd: String?
        var paths: [String]?
        var target: String?
        var branch: String?
        var base: String?
        var force: Bool?
        var keep_branch: Bool?
    }

    static func decode(from data: Data) throws -> AlasCLIRequest {
        func requiredNonEmpty(_ value: String?) throws -> String {
            guard let value else { throw AlasCLIRequestError.malformed }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw AlasCLIRequestError.malformed }
            return trimmed
        }

        func validatedAbsolutePaths(_ paths: [String]?) throws -> [String] {
            guard let paths,
                  !paths.isEmpty,
                  paths.allSatisfy({
                      let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                      return !trimmed.isEmpty && URL(fileURLWithPath: trimmed).path == trimmed && trimmed.hasPrefix("/")
                  }) else {
                throw AlasCLIRequestError.missingPaths
            }
            return paths
        }

        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: data)
        } catch {
            throw AlasCLIRequestError.malformed
        }
        guard raw.kind == "cli" else { throw AlasCLIRequestError.unsupportedKind }
        guard raw.v == 1 else { throw AlasCLIRequestError.unsupportedVersion }
        let sessionId = raw.session_id?.nilIfBlank
        // Validate against the raw value and return it unchanged: trimming
        // would silently resolve a different directory than the one the CLI
        // sent for a path that legitimately ends in whitespace (the Rust
        // side already sends absolutized, non-trimmed paths). Whitespace is
        // checked only to reject an effectively-empty value.
        let cwd = try raw.cwd.map { rawCwd -> String in
            guard !rawCwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  rawCwd.hasPrefix("/"),
                  URL(fileURLWithPath: rawCwd).path == rawCwd else {
                throw AlasCLIRequestError.malformed
            }
            return rawCwd
        }
        guard sessionId != nil || cwd != nil else {
            throw AlasCLIRequestError.missingSession
        }

        let command: Command
        switch raw.command {
        case "open":
            command = .open(paths: try validatedAbsolutePaths(raw.paths))
        case "wt":
            switch raw.subcommand {
            case "list":
                command = .worktree(.list)
            case "switch":
                command = .worktree(.switch(target: try requiredNonEmpty(raw.target)))
            case "new":
                command = .worktree(.new(branch: try requiredNonEmpty(raw.branch), base: raw.base?.nilIfBlank))
            case "delete":
                command = .worktree(.delete(
                    target: try requiredNonEmpty(raw.target),
                    force: raw.force ?? false,
                    keepBranch: raw.keep_branch ?? false
                ))
            default:
                throw AlasCLIRequestError.unsupportedCommand
            }
        case "review":
            if let target = raw.target?.nilIfBlank {
                command = .review(.provider(target: target))
            } else {
                command = .review(.localChanges)
            }
        case "resolve":
            command = .resolve
        default:
            throw AlasCLIRequestError.unsupportedCommand
        }

        return AlasCLIRequest(version: 1, sessionId: sessionId, cwd: cwd, command: command)
    }
}

enum AlasCLIResponse: Equatable {
    case ok
    case text([String])
    case error(String)

    func encode() throws -> Data {
        let object: [String: Any]
        switch self {
        case .ok:
            object = ["ok": true]
        case .text(let lines):
            object = ["ok": true, "lines": lines]
        case .error(let message):
            object = ["ok": false, "error": message]
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
