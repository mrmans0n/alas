import AppKit

/// Owns the squiggle drawing for a single editor's diagnostics and exposes
/// a count API used by the breadcrumb pill. Extracted from
/// `CodeEditorCoordinator` so the coordinator stays focused on lifecycle.
@MainActor
final class DiagnosticsFeature {
    private(set) var current: [LSPDiagnostic] = []
    var onChange: (() -> Void)?

    /// Drops the cached `current` list without touching storage. Called
    /// when switching files: `load` resets the storage anyway, but if
    /// `repaint` (theme change) or `reloadFromDisk` (external edit) fires
    /// before the new file's diagnostics arrive — or if the new file has
    /// no LSP server — they would otherwise reapply the *previous* file's
    /// diagnostic ranges to the new content and paint stale squiggles.
    func reset() {
        current = []
        onChange?()
    }

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

    /// Returns every diagnostic containing the position, with the most severe
    /// item first. This ordering is deliberately separate from problem
    /// traversal, which follows document position.
    func diagnostics(at position: LSPPosition) -> [LSPDiagnostic] {
        current
            .filter { Self.contains($0.range, position: position) }
            .sorted { lhs, rhs in
                let lhsSeverity = Self.severityRank(lhs.severity)
                let rhsSeverity = Self.severityRank(rhs.severity)
                if lhsSeverity != rhsSeverity { return lhsSeverity < rhsSeverity }
                if lhs.range != rhs.range { return Self.rangePrecedes(lhs.range, rhs.range) }
                return lhs.message < rhs.message
            }
    }

    /// Finds the next (or previous) problem using document order and wraps at
    /// the end. A diagnostic's protocol range remains untouched: rendering
    /// may reject an out-of-bounds range, but later navigation and code-action
    /// requests always retain the server's original coordinates.
    func nextRange(after position: LSPPosition, backwards: Bool) -> LSPRange? {
        let ranges = current.map(\.range).sorted(by: Self.rangePrecedes)
        guard !ranges.isEmpty else { return nil }
        if backwards {
            return ranges.last(where: { Self.positionPrecedes($0.start, position) }) ?? ranges.last
        }
        return ranges.first(where: { Self.positionPrecedes(position, $0.start) }) ?? ranges.first
    }

    nonisolated static func detailMarkdown(for diagnostic: LSPDiagnostic) -> String {
        var lines = ["**\(severityName(for: diagnostic.severity))**"]
        if let source = diagnostic.source, let code = diagnostic.code {
            let label = "\(source) \(code.displayValue)"
            if let href = diagnostic.codeDescription?.href {
                lines.append("[`\(label)`](\(href))")
            } else {
                lines.append("`\(label)`")
            }
        } else if let source = diagnostic.source {
            lines.append("`\(source)`")
        } else if let code = diagnostic.code {
            lines.append("`\(code.displayValue)`")
        }
        lines.append(markdownLiteral(diagnostic.message))
        if let related = diagnostic.relatedInformation, !related.isEmpty {
            lines.append("**Related information**")
            for (index, item) in related.enumerated() {
                lines.append("[\(markdownLiteral(item.message))](alas-diagnostic://related/\(index))")
            }
        }
        lines.append("[Quick Fixes…](alas-diagnostic://actions)")
        return lines.joined(separator: "\n\n")
    }

    nonisolated static func nsRange(for range: LSPRange, in source: String) -> NSRange? {
        guard
            let start = utf16Index(line: range.start.line, character: range.start.character, in: source),
            let end = utf16Index(line: range.end.line, character: range.end.character, in: source),
            end >= start
        else { return nil }
        return NSRange(location: start, length: end - start)
    }

    nonisolated private static func severityRank(_ severity: Int?) -> Int {
        switch severity {
        case 1: 1
        case 2: 2
        case 3: 3
        case 4: 4
        default: 5
        }
    }

    nonisolated private static func severityName(for severity: Int?) -> String {
        switch severity {
        case 1: "Error"
        case 2: "Warning"
        case 3: "Information"
        case 4: "Hint"
        default: "Diagnostic"
        }
    }

    nonisolated private static func contains(_ range: LSPRange, position: LSPPosition) -> Bool {
        !positionPrecedes(position, range.start) && !positionPrecedes(range.end, position)
    }

    nonisolated private static func rangePrecedes(_ lhs: LSPRange, _ rhs: LSPRange) -> Bool {
        if lhs.start != rhs.start { return positionPrecedes(lhs.start, rhs.start) }
        return positionPrecedes(lhs.end, rhs.end)
    }

    nonisolated private static func positionPrecedes(_ lhs: LSPPosition, _ rhs: LSPPosition) -> Bool {
        lhs.line < rhs.line || lhs.line == rhs.line && lhs.character < rhs.character
    }

    /// Diagnostic prose is server data, not Markdown authored by the user.
    /// Escape it before combining it with the small Markdown shell that owns
    /// our metadata and navigation links.
    nonisolated private static func markdownLiteral(_ value: String) -> String {
        let syntax = CharacterSet(charactersIn: "\\`*_{}[]<>()#+-.!|")
        return String(value.unicodeScalars.reduce(into: "") { result, scalar in
            if syntax.contains(scalar) { result.append("\\") }
            result.unicodeScalars.append(scalar)
        })
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
