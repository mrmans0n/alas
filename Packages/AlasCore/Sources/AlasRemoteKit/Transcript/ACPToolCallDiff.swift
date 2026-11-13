import Foundation

/// How a file changed in an exact single-file git patch. `GitFilePatch.Change`
/// aliases it.
public enum GitFilePatchChange: String, Codable, Equatable, Hashable, Sendable { case modified, added, deleted, renamed }

/// One exact git patch an adapter attached to a tool call or a permission
/// request through the `diffPatch` extension, after strict validation.
///
/// Persisted on `ACPMessage.ToolCall.diffs`. Only the validated text is
/// stored; `parsed()` rebuilds the hunks for display.
public struct ACPToolCallDiff: Codable, Equatable, Hashable, Sendable {
    /// Where the patch came from: an approval shows a proposed change, a
    /// tool call reports the change it made or is making.
    public enum Source: String, Codable, Hashable, Sendable { case permissionRequest, toolCall }

    /// Why the patch is not shown. The parse failures share their raw values
    /// with `GitFilePatchFailure`.
    public enum Failure: String, Codable, Hashable, Sendable {
        case notNegotiated, unsupportedVersion, unsupportedFormat, missingText
        case truncated, malformedHeader, malformedPath, pathMismatch, malformedHunk, noHunks
    }

    /// The block's path, as sent.
    public let path: String
    public let source: Source
    /// The validated patch text; nil when invalid.
    public let patch: String?
    /// Nil when valid.
    public let failure: Failure?
    public let change: GitFilePatchChange?
    public let added: Int
    public let removed: Int

    public var isValid: Bool { failure == nil }

    public init(
        path: String, source: Source, patch: String?, failure: Failure?,
        change: GitFilePatchChange?, added: Int, removed: Int
    ) {
        self.path = path
        self.source = source
        self.patch = patch
        self.failure = failure
        self.change = change
        self.added = added
        self.removed = removed
    }

    /// The text this diff's block flattens to in the tool call's `content`;
    /// see `flattenedText(path:payload:)`.
    public var flattenedText: String {
        let unavailable = "Change unavailable: \(path)"
        guard let text = patch else { return unavailable }
        // Work on scalars: a `\r\n` pair is one Character, and only the
        // final `\n` is dropped.
        let scalars = text.unicodeScalars
        var lineStart = scalars.startIndex
        while lineStart < scalars.endIndex, !scalars[lineStart...].starts(with: "@@".unicodeScalars) {
            guard let newline = scalars[lineStart...].firstIndex(of: "\n") else { return unavailable }
            lineStart = scalars.index(after: newline)
        }
        guard lineStart < scalars.endIndex else { return unavailable }
        var end = scalars.endIndex
        if scalars[scalars.index(before: end)] == "\n" {
            end = scalars.index(before: end)
        }
        return String(String.UnicodeScalarView(scalars[lineStart..<end]))
    }
}
