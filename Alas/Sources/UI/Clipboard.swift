import AppKit

enum Clipboard {
    static func read(from pasteboard: NSPasteboard = .general) -> String? {
        pasteboard.string(forType: .string)
    }

    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Copies an absolute path as the real path: the in-app virtual form of a
    /// remote path is meaningless outside Alas. Local paths pass through.
    static func copyPath(_ path: String) {
        copy(RemotePath.realPath(path))
    }
}
