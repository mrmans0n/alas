import Foundation

enum RunScriptScope: String, Codable, Sendable, CaseIterable {
    case repo, global

    var sectionTitle: String {
        switch self {
        case .repo:   return "Repo"
        case .global: return "Global"
        }
    }
}

enum RunScriptOnExit: String, Sendable, Hashable {
    /// Return to the interactive shell prompt when the script exits.
    case keep
    /// Close the pane when the script exits (`exitOnCompletion` semantics).
    case close
}

/// A user-provided runnable script discovered on disk. Identity is
/// `(scope, fileName)`; `key` is the persisted form used to link a
/// terminal tab back to the script that launched it.
struct RunScript: Equatable, Identifiable, Sendable {
    let scope: RunScriptScope
    let fileName: String
    let fileURL: URL
    let displayName: String
    let onExit: RunScriptOnExit
    /// Working directory relative to the worktree root. Nil = worktree root.
    let cwd: String?
    let isExecutable: Bool
    /// Declared service endpoint (`# alas-url:`), when the script serves one.
    /// Optional by design — build/test/lint commands stay useful without it.
    var endpoint: URL?

    var key: String { "\(scope.rawValue):\(fileName)" }
    var id: String { key }
}

/// Parses the `# alas-…:` comment header from the first lines of a script.
/// Unknown keys and malformed values fall back to defaults so a bad header
/// never hides a script from the list.
enum RunScriptMetadata {
    private static let headerLineLimit = 20
    private static let pattern = /^#\s*alas-(name|on-exit|cwd|url):\s*(.+?)\s*$/

    static func parse(
        fileName: String,
        contents: String
    ) -> (displayName: String, onExit: RunScriptOnExit, cwd: String?, endpoint: URL?) {
        var name: String?
        var onExit = RunScriptOnExit.keep
        var cwd: String?
        var endpoint: URL?
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false).prefix(headerLineLimit) {
            guard let match = line.firstMatch(of: pattern) else { continue }
            let value = String(match.2)
            switch match.1 {
            case "name":    name = value
            case "on-exit": onExit = RunScriptOnExit(rawValue: value) ?? .keep
            case "cwd":     cwd = value
            case "url":     endpoint = RunEndpointPolicy.endpoint(from: value)
            default:        break
            }
        }
        let fallback = (fileName as NSString).deletingPathExtension
        return (name ?? (fallback.isEmpty ? fileName : fallback), onExit, cwd, endpoint)
    }
}
