import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

public enum RunScriptScope: String, Codable, Sendable, CaseIterable {
    case repo, global

    public var sectionTitle: String {
        switch self {
        case .repo:   return "Repo"
        case .global: return "Global"
        }
    }
}

public enum RunScriptOnExit: String, Sendable, Hashable {
    /// Return to the interactive shell prompt when the script exits.
    case keep
    /// Close the pane when the script exits (`exitOnCompletion` semantics).
    case close
}

/// Whether a run's terminal tab is shown when the run starts.
public enum RunScriptConsole: String, Sendable, Hashable {
    case shown
    /// The tab stays out of the tab strip until something activates it.
    case hidden

    public var flipped: RunScriptConsole { self == .shown ? .hidden : .shown }
}

/// A user-provided runnable script discovered on disk. Identity is
/// `(scope, fileName)`; `key` is the persisted form used to link a
/// terminal tab back to the script that launched it.
public struct RunScript: Equatable, Identifiable, Sendable {
    public let scope: RunScriptScope
    public let fileName: String
    public let fileURL: URL
    public let displayName: String
    public let onExit: RunScriptOnExit
    /// Working directory relative to the worktree root. Nil = worktree root.
    public let cwd: String?
    public let isExecutable: Bool
    /// Declared service endpoint (`# alas-url:`), when the script serves one.
    /// Optional by design — build/test/lint commands stay useful without it.
    public var endpoint: URL?
    /// Declared as `# alas-console:`. ⌥ flips it for one launch.
    public var console: RunScriptConsole = .shown

    public var key: String { "\(scope.rawValue):\(fileName)" }
    public var id: String { key }

    /// Menu title for running once against the console default.
    public var flippedConsoleRunTitle: String {
        console == .shown ? "Run \(displayName) in Background" : "Run \(displayName) with Console"
    }

    public init(scope: RunScriptScope, fileName: String, fileURL: URL, displayName: String, onExit: RunScriptOnExit, cwd: String?, isExecutable: Bool, endpoint: URL? = nil, console: RunScriptConsole = .shown) {
        self.scope = scope
        self.fileName = fileName
        self.fileURL = fileURL
        self.displayName = displayName
        self.onExit = onExit
        self.cwd = cwd
        self.isExecutable = isExecutable
        self.endpoint = endpoint
        self.console = console
    }
}

/// Parses the `# alas-…:` comment header from the first lines of a script.
/// Unknown keys and malformed values fall back to defaults so a bad header
/// never hides a script from the list.
public enum RunScriptMetadata: Sendable {
    private static let headerLineLimit = 20
    /// `nonisolated(unsafe)` is sound: a compiled `Regex` built from a literal
    /// is immutable, and `firstMatch(of:)` below does not mutate it — `Regex`
    /// simply isn't `Sendable` yet. Do not rebuild this per call: `parse` runs
    /// once per script file discovered on disk.
    nonisolated(unsafe) private static let pattern = /^#\s*alas-(name|on-exit|cwd|url|console):\s*(.+?)\s*$/

    public static func parse(
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
