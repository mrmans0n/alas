import Foundation
import AlasFoundation
import AlasPlatform
import AlasACP

extension ACPToolCallDiff {
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
        make(path: path, payload: payload, source: .toolCall).flattenedText
    }

    /// What an approval card previews: the request's own patches (Claude
    /// sends them on the request) when it carries any, else the diffs already
    /// on the call's row (Codex sends the patch on the started call and an
    /// empty request).
    public static func permissionPreview(
        request: ACPPermissionToolCall, existingRow: ACPMessage.ToolCall?
    ) -> [ACPToolCallDiff] {
        let own = diffs(in: request.content ?? [], source: .permissionRequest)
        return own.isEmpty ? existingRow?.diffs ?? [] : own
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
