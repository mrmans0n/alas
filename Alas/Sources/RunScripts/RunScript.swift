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

/// Whether a run's terminal tab is shown when the run starts.
enum RunScriptConsole: String, Sendable, Hashable {
    case shown
    /// The tab stays out of the tab strip until something activates it.
    case hidden

    var flipped: RunScriptConsole { self == .shown ? .hidden : .shown }
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
    /// Declared as `# alas-console:`. ⌥ flips it for one launch.
    var console: RunScriptConsole = .shown

    var key: String { "\(scope.rawValue):\(fileName)" }
    var id: String { key }

    /// Menu title for running once against the console default.
    var flippedConsoleRunTitle: String {
        console == .shown ? "Run \(displayName) in Background" : "Run \(displayName) with Console"
    }
}

/// Parses the `# alas-…:` comment header from the first lines of a script.
/// Unknown keys and malformed values fall back to defaults so a bad header
/// never hides a script from the list.
enum RunScriptMetadata {
    private static let headerLineLimit = 20
    /// `nonisolated(unsafe)` is sound: a compiled `Regex` built from a literal
    /// is immutable, and `firstMatch(of:)` below does not mutate it — `Regex`
    /// simply isn't `Sendable` yet. Do not rebuild this per call: `parse` runs
    /// once per script file discovered on disk.
    nonisolated(unsafe) private static let pattern = /^#\s*alas-(name|on-exit|cwd|url|console):\s*(.+?)\s*$/

    static func parse(
        fileName: String,
        contents: String
    ) -> (displayName: String, onExit: RunScriptOnExit, cwd: String?, endpoint: URL?, console: RunScriptConsole) {
        var name: String?
        var onExit = RunScriptOnExit.keep
        var cwd: String?
        var endpoint: URL?
        var console = RunScriptConsole.shown
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false).prefix(headerLineLimit) {
            guard let match = line.firstMatch(of: pattern) else { continue }
            let value = String(match.2)
            switch match.1 {
            case "name":    name = value
            case "on-exit": onExit = RunScriptOnExit(rawValue: value) ?? .keep
            case "cwd":     cwd = value
            case "url":     endpoint = RunEndpointPolicy.endpoint(from: value)
            case "console": console = RunScriptConsole(rawValue: value) ?? .shown
            default:        break
            }
        }
        let fallback = (fileName as NSString).deletingPathExtension
        return (name ?? (fallback.isEmpty ? fileName : fallback), onExit, cwd, endpoint, console)
    }
}
