import AppKit

enum Clipboard {
    static func read(from pasteboard: NSPasteboard = .general) -> String? {
        pasteboard.string(forType: .string)
    }

    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
