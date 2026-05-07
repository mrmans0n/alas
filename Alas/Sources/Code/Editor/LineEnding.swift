import Foundation

/// Line-ending style of a file as read from disk. The buffer captures this
/// at load time and the save path normalizes back to it before writing, so
/// editing a CRLF file in the editor doesn't silently rewrite it as LF.
enum LineEnding: String, Codable {
    case lf
    case crlf

    /// Detects the dominant line ending in `text`. If any CRLF appears, the
    /// file is treated as CRLF (we err on the side of preserving the foreign
    /// style — it's much better to leave a stray LF in a CRLF file than to
    /// rewrite the whole file with the wrong endings).
    static func detect(in text: String) -> LineEnding {
        text.contains("\r\n") ? .crlf : .lf
    }

    /// Returns `text` with its line endings rewritten to this style. The
    /// editor stores text in the AppKit-canonical LF form internally, so
    /// `normalize` is only meaningful when writing to disk.
    func normalize(_ text: String) -> String {
        // Always go through LF as the canonical form so that double-CRLF
        // ("\r\r\n") doesn't get produced when normalizing an already-CRLF
        // string with `crlf`.
        let lfForm = text.replacingOccurrences(of: "\r\n", with: "\n")
        switch self {
        case .lf:   return lfForm
        case .crlf: return lfForm.replacingOccurrences(of: "\n", with: "\r\n")
        }
    }
}
