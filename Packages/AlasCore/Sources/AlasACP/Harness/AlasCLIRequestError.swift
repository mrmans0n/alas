import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public enum AlasCLIRequestError: Error, Equatable, Sendable {
    case malformed
    case unsupportedKind
    case unsupportedVersion
    case unsupportedCommand
    case missingSession
    case missingPaths
}

public enum ReviewCommentWireFilter: String, Equatable, Sendable {
    case active
    case resolved
    case dismissed
    case all
}

public enum ReviewVerdictWire: String, Equatable, Sendable {
    case approve
    case requestChanges = "request_changes"
    case comment

    public var reviewVerdict: ReviewVerdict {
        switch self {
        case .approve: .approve
        case .requestChanges: .requestChanges
        case .comment: .comment
        }
    }
}

public enum AlasCLINotifyLevel: String, Equatable, Sendable {
    case info
    case attention
}

/// `pr_create` arguments after validation: title and body trimmed and
/// non-empty, `base` nil when omitted or blank (the worktree's base branch).
public struct PRCreateParams: Equatable, Sendable {
    public let title: String
    public let body: String
    public let draft: Bool
    public let base: String?

    public init(title: String, body: String, draft: Bool = false, base: String? = nil) {
        self.title = title
        self.body = body
        self.draft = draft
        self.base = base
    }
}

public enum AlasCLIResponse: Equatable, Sendable {
    case ok
    case text([String])
    case error(String)
    case errorWithExitCode(String, Int)

    public func encode() throws -> Data {
        var object: [String: Any]
        switch self {
        case .ok:
            object = ["ok": true]
        case .text(let lines):
            object = ["ok": true, "lines": lines]
        case .error(let message):
            object = ["ok": false, "error": message]
        case .errorWithExitCode(let message, let exitCode):
            object = ["ok": false, "error": message]
            if exitCode != 1 {
                object["exit_code"] = exitCode
            }
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

private extension String {
    package var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
