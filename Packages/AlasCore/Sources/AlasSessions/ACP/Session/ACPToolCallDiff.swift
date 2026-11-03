import Foundation
import AlasPlatform
import AlasACP

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
    public let change: GitFilePatch.Change?
    public let added: Int
    public let removed: Int

    public var isValid: Bool { failure == nil }

    public init(
        path: String, source: Source, patch: String?, failure: Failure?,
        change: GitFilePatch.Change?, added: Int, removed: Int
    ) {
        self.path = path
        self.source = source
        self.patch = patch
        self.failure = failure
        self.change = change
        self.added = added
        self.removed = removed
    }

    /// Validates `payload` for the block at `path`. Checks, in order: that the
    /// connection negotiated `diffPatch`, version 1, the `git_patch` format,
    /// non-empty text, then that the text parses as an exact patch of `path`.
    public static func make(path: String, payload: ACPDiffPatchPayload, source: Source) -> ACPToolCallDiff {
        func invalid(_ failure: Failure) -> ACPToolCallDiff {
            ACPToolCallDiff(
                path: path, source: source, patch: nil, failure: failure, change: nil, added: 0, removed: 0)
        }
        guard payload.negotiated else { return invalid(.notNegotiated) }
        guard payload.version == ACPDiffPatchAdvertisement.supportedVersion else { return invalid(.unsupportedVersion) }
        guard payload.format == ACPDiffPatchAdvertisement.supportedFormat else { return invalid(.unsupportedFormat) }
        guard let text = payload.text, !text.isEmpty else { return invalid(.missingText) }
        switch GitPatchParser.parse(text, path: path) {
        case .success(let file):
            return ACPToolCallDiff(
                path: path, source: source, patch: text, failure: nil,
                change: file.change, added: file.added, removed: file.removed)
        case .failure(let failure):
            return invalid(Failure(failure))
        }
    }

    /// One entry per `.diff` item that carries a patch payload, in order.
    /// Standard diffs contribute nothing.
    public static func diffs(in items: [ACPToolCallContent], source: Source) -> [ACPToolCallDiff] {
        items.compactMap { item in
            guard case .diff(let path, _, _, _, _, let payload?) = item else { return nil }
            return make(path: path, payload: payload, source: source)
        }
    }

    /// The tool call's flattened text for a patch block: for a valid patch,
    /// its text from the first hunk header without the final newline; for an
    /// invalid one, `Change unavailable: <path>`.
    public static func flattenedText(path: String, payload: ACPDiffPatchPayload) -> String {
        let unavailable = "Change unavailable: \(path)"
        let diff = make(path: path, payload: payload, source: .toolCall)
        guard let text = diff.patch else { return unavailable }
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

    /// The patch's hunks for display; nil when invalid.
    public func parsed() -> GitFilePatch? {
        guard let patch, case .success(let file) = GitPatchParser.parse(patch, path: path) else { return nil }
        return file
    }
}

extension ACPToolCallDiff.Failure {
    init(_ failure: GitFilePatchFailure) {
        switch failure {
        case .truncated: self = .truncated
        case .malformedHeader: self = .malformedHeader
        case .malformedPath: self = .malformedPath
        case .pathMismatch: self = .pathMismatch
        case .malformedHunk: self = .malformedHunk
        case .noHunks: self = .noHunks
        }
    }
}
