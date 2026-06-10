import Foundation

enum ACPBareURLLinkifier {
    static func markdownAutolinkingBareURLs(_ text: String, preserveFencedCodeBlocks: Bool) -> String {
        guard text.contains("http://") || text.contains("https://") else { return text }

        var output = ""
        var lineStart = text.startIndex
        var openingFence: CodeFenceDelimiter?
        var inlineState = InlineRewriteState(referenceLabels: markdownReferenceLabels(in: text))
        var referenceDefinitionContinuation: ReferenceDefinitionContinuation?

        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let includesNewline = lineEnd < text.endIndex
            let lineRangeEnd = includesNewline ? text.index(after: lineEnd) : lineEnd
            let line = String(text[lineStart..<lineRangeEnd])

            if preserveFencedCodeBlocks, let currentFence = openingFence {
                output += line
                if closingCodeFenceDelimiter(in: line)?.closes(currentFence) == true {
                    openingFence = nil
                }
            } else if inlineState.codeSpanDelimiterLength == nil,
                      referenceDefinitionContinuation == .destination,
                      markdownReferenceDefinitionDestinationContinuationLine(in: line) {
                output += line
                referenceDefinitionContinuation = .title
            } else if inlineState.codeSpanDelimiterLength == nil,
                      referenceDefinitionContinuation == .title,
                      markdownReferenceDefinitionTitleContinuationLine(in: line) {
                output += line
                referenceDefinitionContinuation = nil
            } else if inlineState.codeSpanDelimiterLength == nil,
                      let referenceDefinition = markdownReferenceDefinition(in: line) {
                output += line
                referenceDefinitionContinuation = referenceDefinition.hasDestination ? .title : .destination
            } else if preserveFencedCodeBlocks,
                      inlineState.codeSpanDelimiterLength == nil,
                      let lineFence = openingCodeFenceDelimiter(in: line) {
                output += line
                openingFence = lineFence
            } else {
                if inlineState.codeSpanDelimiterLength == nil {
                    referenceDefinitionContinuation = nil
                }
                output += rewriteInline(line, state: &inlineState, remainingTextAfterSegment: text[lineRangeEnd...])
            }

            lineStart = lineRangeEnd
        }

        return output
    }

    private static func rewriteInline(_ text: String) -> String {
        var state = InlineRewriteState(referenceLabels: markdownReferenceLabels(in: text))
        return rewriteInline(text, state: &state)
    }

    private struct InlineRewriteState {
        var codeSpanDelimiterLength: Int?
        var referenceLabels: Set<String>
    }

    private enum ReferenceDefinitionContinuation {
        case destination
        case title
    }

    private static func rewriteInline(
        _ text: String,
        state: inout InlineRewriteState,
        remainingTextAfterSegment: Substring? = nil
    ) -> String {
        var output = ""
        var index = text.startIndex

        while index < text.endIndex {
            if let delimiterLength = state.codeSpanDelimiterLength {
                if text[index] == "`" {
                    let closingLength = repeatedCharacterRunLength(in: text, from: index, matching: "`")
                    if closingLength == delimiterLength {
                        let end = text.index(index, offsetBy: delimiterLength)
                        output += text[index..<end]
                        index = end
                        state.codeSpanDelimiterLength = nil
                        continue
                    }
                }

                output.append(text[index])
                index = text.index(after: index)
                continue
            }

            if text[index] == "`" {
                let delimiterLength = repeatedCharacterRunLength(in: text, from: index, matching: "`")
                if isFenceLikeBacktickDelimiterLine(in: text, at: index, delimiterLength: delimiterLength) {
                    let end = text.index(index, offsetBy: delimiterLength)
                    output += text[index..<end]
                    index = end
                    continue
                }

                if let end = codeSpanEnd(in: text, from: index) {
                    output += text[index...end]
                    index = text.index(after: end)
                    continue
                }

                let end = text.index(index, offsetBy: delimiterLength)
                output += text[index..<end]
                index = end
                let remainingText = remainingTextAfterSegment ?? text[index...]
                if hasCodeSpanEnd(in: remainingText, delimiterLength: delimiterLength) {
                    state.codeSpanDelimiterLength = delimiterLength
                }
                continue
            }

            if text[index] == "<",
               startsWithWebScheme(text, at: text.index(after: index)),
               let end = text[text.index(after: index)...].firstIndex(of: ">") {
                output += text[index...end]
                index = text.index(after: end)
                continue
            }

            if text[index] == "<", let end = rawHTMLTagEnd(in: text, from: index) {
                output += text[index...end]
                index = text.index(after: end)
                continue
            }

            if text[index] == "[",
               let linkEnd = markdownBracketedLinkEnd(in: text, from: index, referenceLabels: state.referenceLabels) {
                output += text[index...linkEnd]
                index = text.index(after: linkEnd)
                continue
            }

            if startsWithWebScheme(text, at: index), hasValidBoundaryBefore(index, in: text) {
                let rawEnd = rawURLEnd(in: text, from: index)
                let trimmedEnd = trimmedURLEnd(in: text, from: index, rawEnd: rawEnd)
                if trimmedEnd > index {
                    let urlText = String(text[index..<trimmedEnd])
                    if isValidBareWebURL(urlText) {
                        output += "<\(urlText)>"
                        output += text[trimmedEnd..<rawEnd]
                        index = rawEnd
                        continue
                    }
                }
            }

            output.append(text[index])
            index = text.index(after: index)
        }

        return output
    }

    private struct CodeFenceDelimiter {
        let marker: Character
        let length: Int

        func closes(_ openingFence: CodeFenceDelimiter) -> Bool {
            marker == openingFence.marker && length >= openingFence.length
        }
    }

    private static func openingCodeFenceDelimiter(in line: String) -> CodeFenceDelimiter? {
        codeFenceDelimiter(in: line, allowsTrailingText: true)
    }

    private static func closingCodeFenceDelimiter(in line: String) -> CodeFenceDelimiter? {
        codeFenceDelimiter(in: line, allowsTrailingText: false)
    }

    private static func codeFenceDelimiter(in line: String, allowsTrailingText: Bool) -> CodeFenceDelimiter? {
        let contentEnd = trailingWhitespaceTrimmedEnd(in: line)
        var index = line.startIndex
        var leadingSpaces = 0
        while index < contentEnd, line[index] == " " {
            leadingSpaces += 1
            index = line.index(after: index)
        }
        guard leadingSpaces <= 3 else { return nil }
        guard index < contentEnd else { return nil }

        let first = line[index]
        guard first == "`" || first == "~" else { return nil }

        var count = 0
        while index < contentEnd, line[index] == first {
            count += 1
            index = line.index(after: index)
        }

        guard allowsTrailingText || index == contentEnd else { return nil }
        guard first != "`" || !line[index..<contentEnd].contains("`") else { return nil }
        return count >= 3 ? CodeFenceDelimiter(marker: first, length: count) : nil
    }

    private static func trailingWhitespaceTrimmedEnd(in line: String) -> String.Index {
        var end = line.endIndex
        while end > line.startIndex {
            let previous = line.index(before: end)
            guard line[previous].isWhitespace || line[previous].isNewline else { break }
            end = previous
        }
        return end
    }

    private static func isFenceLikeBacktickDelimiterLine(in text: String, at index: String.Index, delimiterLength: Int) -> Bool {
        guard delimiterLength >= 3 else { return false }

        var lineStart = index
        while lineStart > text.startIndex {
            let previous = text.index(before: lineStart)
            guard text[previous] != "\n" else { break }
            lineStart = previous
        }

        var prefixIndex = lineStart
        while prefixIndex < index {
            guard text[prefixIndex] == " " else { return false }
            prefixIndex = text.index(after: prefixIndex)
        }

        var lineEnd = index
        while lineEnd < text.endIndex, text[lineEnd] != "\n" {
            lineEnd = text.index(after: lineEnd)
        }

        let afterDelimiter = text.index(index, offsetBy: delimiterLength)
        return !text[afterDelimiter..<lineEnd].contains("`")
    }

    private static func codeSpanEnd(in text: String, from start: String.Index) -> String.Index? {
        let delimiterLength = repeatedCharacterRunLength(in: text, from: start, matching: "`")
        var index = text.index(start, offsetBy: delimiterLength)
        var currentLineIsBlank = false

        while index < text.endIndex {
            let character = text[index]
            if character == "\n" {
                if currentLineIsBlank {
                    return nil
                }
                currentLineIsBlank = true
                index = text.index(after: index)
            } else if character.isWhitespace {
                index = text.index(after: index)
            } else if character == "`" {
                currentLineIsBlank = false
                let closingLength = repeatedCharacterRunLength(in: text, from: index, matching: "`")
                if closingLength == delimiterLength {
                    var end = index
                    for _ in 1..<closingLength {
                        end = text.index(after: end)
                    }
                    return end
                }

                for _ in 0..<closingLength {
                    index = text.index(after: index)
                }
            } else {
                currentLineIsBlank = false
                index = text.index(after: index)
            }
        }

        return nil
    }

    private static func hasCodeSpanEnd(in text: Substring, delimiterLength: Int) -> Bool {
        var index = text.startIndex
        var currentLineIsBlank = true
        while index < text.endIndex {
            let character = text[index]
            if character == "\n" {
                if currentLineIsBlank {
                    return false
                }
                currentLineIsBlank = true
                index = text.index(after: index)
            } else if character.isWhitespace {
                index = text.index(after: index)
            } else if character == "`" {
                currentLineIsBlank = false
                let closingLength = repeatedCharacterRunLength(in: text, from: index, matching: "`")
                if closingLength == delimiterLength {
                    return true
                }

                for _ in 0..<closingLength {
                    index = text.index(after: index)
                }
            } else {
                currentLineIsBlank = false
                index = text.index(after: index)
            }
        }

        return false
    }

    private static func repeatedCharacterRunLength(in text: String, from start: String.Index, matching character: Character) -> Int {
        var count = 0
        var index = start
        while index < text.endIndex, text[index] == character {
            count += 1
            index = text.index(after: index)
        }
        return count
    }

    private static func repeatedCharacterRunLength(in text: Substring, from start: String.Index, matching character: Character) -> Int {
        var count = 0
        var index = start
        while index < text.endIndex, text[index] == character {
            count += 1
            index = text.index(after: index)
        }
        return count
    }

    private static func startsWithWebScheme(_ text: String, at index: String.Index) -> Bool {
        index <= text.endIndex &&
        (text[index...].hasPrefix("https://") || text[index...].hasPrefix("http://"))
    }

    private static func hasValidBoundaryBefore(_ index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return true }
        let previous = text[text.index(before: index)]
        return previous.isWhitespace || "([{\"'".contains(previous)
    }

    private static func rawHTMLTagEnd(in text: String, from start: String.Index) -> String.Index? {
        guard isRawHTMLTagStart(in: text, at: start) else { return nil }

        var index = text.index(after: start)
        var quote: Character?
        while index < text.endIndex {
            let character = text[index]
            if let currentQuote = quote {
                if character == currentQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = text.index(after: index)
        }

        return nil
    }

    private static func isRawHTMLTagStart(in text: String, at start: String.Index) -> Bool {
        guard start < text.endIndex, text[start] == "<" else { return false }
        let next = text.index(after: start)
        guard next < text.endIndex else { return false }
        let character = text[next]
        return character.isLetter || character == "!" || character == "/" || character == "?"
    }

    private static func rawURLEnd(in text: String, from start: String.Index) -> String.Index {
        var index = start
        while index < text.endIndex {
            let character = text[index]
            let nextIndex = text.index(after: index)
            if character.isWhitespace ||
                character.isNewline ||
                "<>".contains(character) ||
                (character == "]" && nextIndex < text.endIndex && text[nextIndex] == "[") ||
                character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                break
            }
            index = nextIndex
        }
        return index
    }

    private static func trimmedURLEnd(in text: String, from start: String.Index, rawEnd: String.Index) -> String.Index {
        var end = rawEnd
        while end > start {
            let previousIndex = text.index(before: end)
            let character = text[previousIndex]
            if ". ,;:!?\"'".filter({ !$0.isWhitespace }).contains(character) {
                end = previousIndex
                continue
            }
            if isUnbalancedClosing(character, in: text[start..<end]) {
                end = previousIndex
                continue
            }
            break
        }
        return end
    }

    private static func isValidBareWebURL(_ text: String) -> Bool {
        let scheme: String
        if text.hasPrefix("https://") {
            scheme = "https://"
        } else if text.hasPrefix("http://") {
            scheme = "http://"
        } else {
            return false
        }

        let hostStart = text.index(text.startIndex, offsetBy: scheme.count)
        guard hostStart < text.endIndex else { return false }

        let hostEnd = text[hostStart...].firstIndex { character in
            character == "/" || character == "?" || character == "#"
        } ?? text.endIndex
        let host = text[hostStart..<hostEnd]
        return host.contains { character in
            character.isLetter || character.isNumber
        }
    }

    private static func isUnbalancedClosing(_ character: Character, in candidate: Substring) -> Bool {
        let pair: (open: Character, close: Character)?
        switch character {
        case ")": pair = ("(", ")")
        case "]": pair = ("[", "]")
        case "}": pair = ("{", "}")
        case ">": pair = ("<", ">")
        default: pair = nil
        }
        guard let pair else { return false }
        let opens = candidate.filter { $0 == pair.open }.count
        let closes = candidate.filter { $0 == pair.close }.count
        return closes > opens
    }

    private static func markdownBracketedLinkEnd(
        in text: String,
        from start: String.Index,
        referenceLabels: Set<String>
    ) -> String.Index? {
        guard let labelEnd = markdownLabelEnd(in: text, from: start) else { return nil }
        let label = normalizeMarkdownReferenceLabel(String(text[text.index(after: start)..<labelEnd]))
        if referenceLabels.contains(label) {
            return labelEnd
        }

        let next = text.index(after: labelEnd)
        guard next < text.endIndex else { return nil }
        if text[next...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }

        if text[next] == "(", let destinationEnd = markdownDestinationEnd(in: text, from: next) {
            return destinationEnd
        }

        if text[next] == "[", let referenceEnd = markdownLabelEnd(in: text, from: next) {
            let referenceLabel = String(text[text.index(after: next)..<referenceEnd])
            let normalizedReference = normalizeMarkdownReferenceLabel(referenceLabel)
            let effectiveReference = normalizedReference.isEmpty ? label : normalizedReference
            return referenceLabels.contains(effectiveReference) ? referenceEnd : nil
        }

        return nil
    }

    private static func markdownLabelEnd(in text: String, from start: String.Index) -> String.Index? {
        guard start < text.endIndex, text[start] == "[" else { return nil }

        var depth = 0
        var isEscaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index = text.index(after: index)
        }

        return nil
    }

    private static func markdownDestinationEnd(in text: String, from start: String.Index) -> String.Index? {
        guard start < text.endIndex, text[start] == "(" else { return nil }

        var depth = 1
        var isEscaped = false
        var quote: Character?
        var hasDestinationContent = false
        var canStartTitleQuote = false
        var index = text.index(after: start)
        while index < text.endIndex {
            let character = text[index]
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if let currentQuote = quote {
                if character == currentQuote {
                    quote = nil
                }
            } else if canStartTitleQuote, character == "\"" || character == "'" {
                quote = character
                canStartTitleQuote = false
            } else if character == "(" {
                depth += 1
                hasDestinationContent = true
                canStartTitleQuote = false
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    return index
                }
                hasDestinationContent = true
                canStartTitleQuote = false
            } else if character.isWhitespace || character.isNewline {
                if hasDestinationContent, depth == 1 {
                    canStartTitleQuote = true
                }
            } else {
                hasDestinationContent = true
                canStartTitleQuote = false
            }
            index = text.index(after: index)
        }

        return nil
    }

    private struct MarkdownReferenceDefinition {
        let label: String
        let hasDestination: Bool
    }

    private static func markdownReferenceLabels(in text: String) -> Set<String> {
        var labels: Set<String> = []
        var lineStart = text.startIndex
        var openingFence: CodeFenceDelimiter?
        var pendingDefinitionLabel: String?

        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let includesNewline = lineEnd < text.endIndex
            let lineRangeEnd = includesNewline ? text.index(after: lineEnd) : lineEnd
            let line = String(text[lineStart..<lineRangeEnd])

            if let currentFence = openingFence {
                if closingCodeFenceDelimiter(in: line)?.closes(currentFence) == true {
                    openingFence = nil
                }
            } else if let label = pendingDefinitionLabel {
                if markdownReferenceDefinitionDestinationContinuationLine(in: line) {
                    labels.insert(normalizeMarkdownReferenceLabel(label))
                }
                pendingDefinitionLabel = nil
            } else if let lineFence = openingCodeFenceDelimiter(in: line) {
                openingFence = lineFence
            } else if let definition = markdownReferenceDefinition(in: line) {
                if definition.hasDestination {
                    labels.insert(normalizeMarkdownReferenceLabel(definition.label))
                } else {
                    pendingDefinitionLabel = definition.label
                }
            }

            lineStart = lineRangeEnd
        }

        return labels
    }

    private static func markdownReferenceDefinition(in line: String) -> MarkdownReferenceDefinition? {
        var index = line.startIndex
        var leadingSpaces = 0
        while index < line.endIndex, line[index] == " " {
            leadingSpaces += 1
            index = line.index(after: index)
        }
        guard leadingSpaces <= 3, index < line.endIndex, line[index] == "[" else { return nil }
        guard let labelEnd = markdownLabelEnd(in: line, from: index) else { return nil }
        let colonIndex = line.index(after: labelEnd)
        guard colonIndex < line.endIndex, line[colonIndex] == ":" else { return nil }

        let label = String(line[line.index(after: index)..<labelEnd])
        guard !normalizeMarkdownReferenceLabel(label).isEmpty else { return nil }

        let afterColon = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return MarkdownReferenceDefinition(label: label, hasDestination: !afterColon.isEmpty)
    }

    private static func markdownReferenceDefinitionDestinationContinuationLine(in line: String) -> Bool {
        guard let content = indentedReferenceDefinitionContinuationContent(in: line) else { return false }
        return !content.isEmpty
    }

    private static func markdownReferenceDefinitionTitleContinuationLine(in line: String) -> Bool {
        guard let content = indentedReferenceDefinitionContinuationContent(in: line) else { return false }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let opener = trimmed.first else { return false }
        let closer: Character
        switch opener {
        case "\"", "'":
            closer = opener
        case "(":
            closer = ")"
        default:
            return false
        }

        var isEscaped = false
        var index = trimmed.index(after: trimmed.startIndex)
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == closer {
                return trimmed.index(after: index) == trimmed.endIndex
            }
            index = trimmed.index(after: index)
        }

        return false
    }

    private static func indentedReferenceDefinitionContinuationContent(in line: String) -> String? {
        let contentEnd = trailingWhitespaceTrimmedEnd(in: line)
        var index = line.startIndex
        var leadingWhitespace = 0
        while index < contentEnd, line[index] == " " || line[index] == "\t" {
            leadingWhitespace += 1
            index = line.index(after: index)
        }
        guard leadingWhitespace > 0, index < contentEnd else { return nil }
        return String(line[index..<contentEnd])
    }

    private static func normalizeMarkdownReferenceLabel(_ label: String) -> String {
        label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}
