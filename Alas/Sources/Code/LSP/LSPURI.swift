import Foundation

extension URL {
    /// LSP `DocumentUri` for this file URL. Uses `absoluteString` so spaces,
    /// `#`, `%`, and other reserved characters are percent-encoded as
    /// required by the protocol — a raw `"file://" + path` concatenation
    /// produces an invalid URI that some servers reject. Trailing slash
    /// from directory URLs is stripped to match the convention sourcekit-lsp
    /// and most other servers use for `rootURI`.
    var lspURI: String {
        var s = absoluteString
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
