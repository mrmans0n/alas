import Foundation

struct CompletionPrefix: Equatable, Sendable {
    let text: String
    let range: NSRange
}

enum CompletionCandidateSource: Equatable, Sendable {
    case lsp
    case buffer
}

struct CompletionCandidate: Identifiable, Equatable, Sendable {
    let id = UUID()
    let label: String
    let detail: String?
    let kind: Int?
    let documentation: String?
    let sortText: String?
    let filterText: String?
    let replacementText: String
    let textEdit: LSPTextEdit?
    let additionalTextEdits: [LSPTextEdit]
    let source: CompletionCandidateSource

    static func == (lhs: CompletionCandidate, rhs: CompletionCandidate) -> Bool {
        lhs.label == rhs.label &&
        lhs.detail == rhs.detail &&
        lhs.kind == rhs.kind &&
        lhs.documentation == rhs.documentation &&
        lhs.sortText == rhs.sortText &&
        lhs.filterText == rhs.filterText &&
        lhs.replacementText == rhs.replacementText &&
        lhs.textEdit == rhs.textEdit &&
        lhs.additionalTextEdits == rhs.additionalTextEdits &&
        lhs.source == rhs.source
    }
}

struct CompletionTextEdit: Equatable, Sendable {
    let range: NSRange
    let replacementText: String
}

struct CompletionEditPlan: Equatable, Sendable {
    /// Original-buffer ranges sorted ascending; consumers must apply edits in reverse order.
    let edits: [CompletionTextEdit]
    let finalSelection: NSRange
}

enum CompletionEngine {
    static func prefix(in text: String, caret: Int) -> CompletionPrefix? {
        let ns = text as NSString
        guard caret >= 0, caret <= ns.length else { return nil }

        var start = caret
        while start > 0, isIdentifierChar(ns.character(at: start - 1)) {
            start -= 1
        }

        let range = NSRange(location: start, length: caret - start)
        return CompletionPrefix(text: ns.substring(with: range), range: range)
    }

    static func lspCandidates(
        from items: [LSPCompletionItem],
        prefix: CompletionPrefix,
        memberAccessOnly: Bool = false
    ) -> [CompletionCandidate] {
        let candidates = items.compactMap { item -> CompletionCandidate? in
            guard !memberAccessOnly || isMemberAccessCandidate(item) else {
                return nil
            }

            let filter = item.filterText ?? item.label
            guard prefix.text.isEmpty ||
                    hasCaseInsensitivePrefix(filter, prefix.text) ||
                    hasCaseInsensitivePrefix(item.label, prefix.text) else {
                return nil
            }

            let rawReplacement = item.textEdit?.newText ?? item.insertText ?? item.label
            let replacement = item.insertTextFormat == .snippet
                ? plainText(fromSnippet: rawReplacement)
                : rawReplacement

            return CompletionCandidate(
                label: item.label,
                detail: item.detail,
                kind: item.kind,
                documentation: documentationText(item.documentation),
                sortText: item.sortText,
                filterText: item.filterText,
                replacementText: replacement,
                textEdit: item.textEdit,
                additionalTextEdits: item.additionalTextEdits ?? [],
                source: .lsp
            )
        }

        return rank(candidates, prefix: prefix)
    }

    static func bufferWordCandidates(in text: String, prefix: CompletionPrefix, limit: Int = 24) -> [CompletionCandidate] {
        guard (prefix.text as NSString).length >= 3, limit > 0 else { return [] }

        let ns = text as NSString
        var seen = Set<String>()
        var words: [String] = []
        var index = 0

        while index < ns.length {
            guard isIdentifierChar(ns.character(at: index)) else {
                index += 1
                continue
            }

            let start = index
            while index < ns.length, isIdentifierChar(ns.character(at: index)) {
                index += 1
            }

            let word = ns.substring(with: NSRange(location: start, length: index - start))
            if word != prefix.text,
               hasCaseInsensitivePrefix(word, prefix.text),
               seen.insert(word).inserted {
                words.append(word)
            }
        }

        return words.prefix(limit).map { word in
            CompletionCandidate(
                label: word,
                detail: "Current buffer",
                kind: nil,
                documentation: nil,
                sortText: nil,
                filterText: word,
                replacementText: word,
                textEdit: nil,
                additionalTextEdits: [],
                source: .buffer
            )
        }
    }

    static func completionTriggerSuffix(in text: String, caret: Int, triggers: [String]) -> String? {
        let ns = text as NSString
        guard caret >= 0, caret <= ns.length else { return nil }

        return triggers
            .filter { !$0.isEmpty }
            .sorted { lhs, rhs in
                let lhsLength = (lhs as NSString).length
                let rhsLength = (rhs as NSString).length
                if lhsLength == rhsLength {
                    return lhs < rhs
                }
                return lhsLength > rhsLength
            }
            .first { trigger in
                let length = (trigger as NSString).length
                guard length <= caret else { return false }
                let suffixRange = NSRange(location: caret - length, length: length)
                return ns.substring(with: suffixRange) == trigger
            }
    }

    static func editPlan(
        accepting candidate: CompletionCandidate,
        prefix: CompletionPrefix,
        originalPrefix: CompletionPrefix? = nil,
        in text: String
    ) -> CompletionEditPlan? {
        let primaryRange: NSRange
        if let textEdit = candidate.textEdit {
            guard let range = rebasedRange(
                for: textEdit.range,
                originalPrefix: originalPrefix,
                prefix: prefix,
                includeInsertedTextAtEnd: true,
                in: text
            ) else { return nil }
            if shouldReplacePrefix(range: range, replacement: candidate.replacementText, prefix: prefix) {
                primaryRange = prefix.range
            } else {
                primaryRange = range
            }
        } else {
            primaryRange = prefix.range
        }

        let primary = CompletionTextEdit(range: primaryRange, replacementText: candidate.replacementText)
        var edits: [CompletionTextEdit] = []

        for additional in candidate.additionalTextEdits {
            guard let range = rebasedRange(
                for: additional.range,
                originalPrefix: originalPrefix,
                prefix: prefix,
                includeInsertedTextAtEnd: false,
                in: text
            ) else { continue }
            let edit = CompletionTextEdit(range: range, replacementText: additional.newText)
            guard !overlaps(edit.range, primary.range),
                  edits.allSatisfy({ !overlaps($0.range, edit.range) }) else {
                continue
            }
            edits.append(edit)
        }

        edits.append(primary)
        edits.sort { lhs, rhs in
            if lhs.range.location == rhs.range.location {
                return lhs.range.length < rhs.range.length
            }
            return lhs.range.location < rhs.range.location
        }

        let primaryResultEnd = primary.range.location + (primary.replacementText as NSString).length
        let priorAdditionalDelta = edits
            .filter { $0.range.location < primary.range.location }
            .reduce(0) { partial, edit in
                partial + (edit.replacementText as NSString).length - edit.range.length
            }

        return CompletionEditPlan(
            edits: edits,
            finalSelection: NSRange(location: primaryResultEnd + priorAdditionalDelta, length: 0)
        )
    }

    static func plainText(fromSnippet snippet: String) -> String {
        var result = snippet
        result = result.replacingOccurrences(
            of: #"\$\{\d+\|([^,}|]+)(?:,[^}|]+)*\|\}"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\$\{\d+:([^}]+)\}"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\$\{\d+\}"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\$\d+"#,
            with: "",
            options: .regularExpression
        )
        return result
    }

    private static func rank(_ candidates: [CompletionCandidate], prefix: CompletionPrefix) -> [CompletionCandidate] {
        candidates.sorted { lhs, rhs in
            let lhsFilter = lhs.filterText ?? lhs.label
            let rhsFilter = rhs.filterText ?? rhs.label
            let lhsStarts = hasCaseInsensitivePrefix(lhsFilter, prefix.text)
            let rhsStarts = hasCaseInsensitivePrefix(rhsFilter, prefix.text)
            if lhsStarts != rhsStarts {
                return lhsStarts
            }

            let lhsSort = lhs.sortText ?? lhs.label
            let rhsSort = rhs.sortText ?? rhs.label
            return lhsSort.localizedCaseInsensitiveCompare(rhsSort) == .orderedAscending
        }
    }

    private static func documentationText(_ markup: LSPMarkup?) -> String? {
        guard let markup else { return nil }
        switch markup {
        case .markupContent(_, let value):
            return value
        case .plain(let value):
            return value
        }
    }

    private static func isMemberAccessCandidate(_ item: LSPCompletionItem) -> Bool {
        guard let kind = item.kind else { return true }
        switch kind {
        case 2, 3, 4, 5, 6, 10, 12, 20, 21, 23, 24:
            return true
        default:
            return false
        }
    }

    private static func nsRange(for range: LSPRange, in text: String) -> NSRange? {
        guard let start = TextEditCoordinates.utf16Offset(from: range.start, in: text),
              let end = TextEditCoordinates.utf16Offset(from: range.end, in: text),
              start <= end else {
            return nil
        }
        return NSRange(location: start, length: end - start)
    }

    private static func overlaps(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        if lhs.length == 0, rhs.length == 0 {
            return lhs.location == rhs.location
        }
        if lhs.length == 0 {
            return rhs.location <= lhs.location && lhs.location < NSMaxRange(rhs)
        }
        if rhs.length == 0 {
            return lhs.location <= rhs.location && rhs.location < NSMaxRange(lhs)
        }
        return NSIntersectionRange(lhs, rhs).length > 0
    }

    private static func rebasedRange(
        for range: LSPRange,
        originalPrefix: CompletionPrefix?,
        prefix: CompletionPrefix,
        includeInsertedTextAtEnd: Bool,
        in text: String
    ) -> NSRange? {
        guard let originalPrefix,
              originalPrefix.range.location == prefix.range.location else {
            return nsRange(for: range, in: text)
        }

        let growth = NSMaxRange(prefix.range) - NSMaxRange(originalPrefix.range)
        guard growth != 0,
              let prefixStart = TextEditCoordinates.lspPosition(
                utf16Offset: prefix.range.location,
                in: text
              ) else {
            return nsRange(for: range, in: text)
        }
        let oldCaretCharacter = prefixStart.character + originalPrefix.range.length

        func shifted(_ position: LSPPosition, atEnd: Bool) -> LSPPosition {
            guard position.line == prefixStart.line,
                  position.character > oldCaretCharacter ||
                  (!atEnd || includeInsertedTextAtEnd) && position.character == oldCaretCharacter else {
                return position
            }
            return LSPPosition(line: position.line, character: position.character + growth)
        }

        return nsRange(
            for: LSPRange(start: shifted(range.start, atEnd: false), end: shifted(range.end, atEnd: true)),
            in: text
        )
    }

    private static func shouldReplacePrefix(
        range: NSRange,
        replacement: String,
        prefix: CompletionPrefix
    ) -> Bool {
        guard !prefix.text.isEmpty,
              hasCaseInsensitivePrefix(replacement, prefix.text) else { return false }

        return (range.length == 0 && range.location == NSMaxRange(prefix.range)) ||
            (range.location == prefix.range.location && NSMaxRange(range) < NSMaxRange(prefix.range))
    }

    static func hasCaseInsensitivePrefix(_ text: String, _ prefix: String) -> Bool {
        prefix.isEmpty || text.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
    }

    private static func isIdentifierChar(_ character: unichar) -> Bool {
        (character >= 0x41 && character <= 0x5A) ||
        (character >= 0x61 && character <= 0x7A) ||
        (character >= 0x30 && character <= 0x39) ||
        character == 0x5F
    }
}
