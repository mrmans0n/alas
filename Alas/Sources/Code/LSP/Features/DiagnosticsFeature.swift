import AppKit

/// Owns the squiggle drawing for a single editor's diagnostics and exposes
/// a count API used by the breadcrumb pill. Extracted from
/// `CodeEditorCoordinator` so the coordinator stays focused on lifecycle.
@MainActor
final class DiagnosticsFeature {
    private(set) var current: [LSPDiagnostic] = []
    var onChange: (() -> Void)?

    func apply(_ diagnostics: [LSPDiagnostic], to storage: NSTextStorage, theme: Theme) {
        current = diagnostics
        let editorTheme = EditorTheme(theme: theme)
        let full = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.underlineStyle, range: full)
        storage.removeAttribute(.underlineColor, range: full)
        for d in diagnostics {
            guard let nsr = Self.nsRange(for: d.range, in: storage.string) else { continue }
            storage.addAttributes(editorTheme.diagnosticAttributes(severity: d.severity), range: nsr)
        }
        onChange?()
    }

    var counts: (errors: Int, warnings: Int) {
        var e = 0, w = 0
        for d in current {
            switch d.severity {
            case 1: e += 1
            case 2: w += 1
            default: break
            }
        }
        return (e, w)
    }

    nonisolated static func nsRange(for range: LSPRange, in source: String) -> NSRange? {
        guard
            let start = utf16Index(line: range.start.line, character: range.start.character, in: source),
            let end = utf16Index(line: range.end.line, character: range.end.character, in: source),
            end >= start
        else { return nil }
        return NSRange(location: start, length: end - start)
    }

    nonisolated private static func utf16Index(line: Int, character: Int, in source: String) -> Int? {
        let ns = source as NSString
        var idx = 0
        var ln = 0
        while ln < line {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: idx, length: ns.length - idx))
            if r.location == NSNotFound { return nil }
            idx = r.location + 1
            ln += 1
        }
        let target = idx + character
        if target > ns.length { return nil }
        return target
    }
}
