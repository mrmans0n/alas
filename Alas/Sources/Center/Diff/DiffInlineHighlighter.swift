import Foundation

enum DiffInlineHighlighter {
    struct Result: Equatable {
        let oldSpans: [DiffInlineSpan]
        let newSpans: [DiffInlineSpan]
    }

    static func highlightDeleteAdd(old oldText: String, new newText: String) -> Result {
        let oldTokens = tokenize(oldText)
        let newTokens = tokenize(newText)

        guard !oldTokens.isEmpty || !newTokens.isEmpty else {
            return Result(oldSpans: [], newSpans: [])
        }

        guard oldTokens.contains(where: { oldToken in
            newTokens.contains(where: { $0.text == oldToken.text })
        }) else {
            return Result(
                oldSpans: fullLineSpan(for: oldText),
                newSpans: fullLineSpan(for: newText)
            )
        }

        var prefixCount = 0
        while prefixCount < oldTokens.count,
              prefixCount < newTokens.count,
              oldTokens[prefixCount].text == newTokens[prefixCount].text {
            prefixCount += 1
        }

        var oldSuffixIndex = oldTokens.count - 1
        var newSuffixIndex = newTokens.count - 1
        while oldSuffixIndex >= prefixCount,
              newSuffixIndex >= prefixCount,
              oldTokens[oldSuffixIndex].text == newTokens[newSuffixIndex].text {
            oldSuffixIndex -= 1
            newSuffixIndex -= 1
        }

        return Result(
            oldSpans: span(from: oldTokens, lowerBound: prefixCount, upperBound: oldSuffixIndex),
            newSpans: span(from: newTokens, lowerBound: prefixCount, upperBound: newSuffixIndex)
        )
    }

    private struct Token: Equatable {
        let text: String
        let range: NSRange
    }

    private static func tokenize(_ text: String) -> [Token] {
        let pattern = #"[A-Za-z0-9_]+|[^\sA-Za-z0-9_]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        return regex.matches(in: text, range: fullRange).map { match in
            Token(text: nsText.substring(with: match.range), range: match.range)
        }
    }

    private static func fullLineSpan(for text: String) -> [DiffInlineSpan] {
        let length = (text as NSString).length
        return length == 0 ? [] : [DiffInlineSpan(start: 0, length: length)]
    }

    private static func span(from tokens: [Token], lowerBound: Int, upperBound: Int) -> [DiffInlineSpan] {
        guard lowerBound <= upperBound,
              tokens.indices.contains(lowerBound),
              tokens.indices.contains(upperBound) else {
            return []
        }

        let start = tokens[lowerBound].range.location
        let end = tokens[upperBound].range.location + tokens[upperBound].range.length
        return [DiffInlineSpan(start: start, length: end - start)]
    }
}
