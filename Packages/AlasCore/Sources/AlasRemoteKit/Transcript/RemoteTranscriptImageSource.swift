import Foundation

/// Where a transcript image's bytes come from on a phone, mirroring the Mac's
/// `ACPToolCallAsset.loadedTranscriptImage` and `TranscriptImageFile.resolve`.
/// The phone has no trusted worktree root, so every path goes to the host,
/// which resolves relative paths and enforces its own read policy.
public enum RemoteTranscriptImageSource: Equatable, Sendable {
    /// A `data:` URI or an asset's base64 `data`.
    case inline(Data)
    /// Fetched with `readTranscriptImage`.
    case host(path: String)
    /// Shown as alt text or name: the Mac refuses it too (remote URLs, other hosts' files).
    case unavailable

    public static func resolve(source: String) -> RemoteTranscriptImageSource {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !source.utf8.contains(0) else { return .unavailable }
        if source.lowercased().hasPrefix("data:") {
            return decodeBase64(source).map(RemoteTranscriptImageSource.inline) ?? .unavailable
        }
        guard let url = URL(string: source), let scheme = url.scheme else { return .host(path: source) }
        guard scheme.lowercased() == "file", url.host == nil || url.host == "" || url.host == "localhost",
              !url.path.isEmpty else { return .unavailable }
        return .host(path: url.path)
    }

    /// Inline data first, then the uri, as on the Mac.
    public static func resolve(asset: ACPToolCallAsset) -> RemoteTranscriptImageSource {
        if let data = asset.data, let decoded = decodeBase64(data) { return .inline(decoded) }
        return resolve(source: asset.uri ?? "")
    }

    private static func decodeBase64(_ value: String) -> Data? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let base64 = trimmed.range(of: "base64,", options: .caseInsensitive).map { String(trimmed[$0.upperBound...]) }
            ?? trimmed
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !data.isEmpty else { return nil }
        return data
    }
}
