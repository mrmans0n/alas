import Foundation

/// Converts LSP's negotiated UTF-16 positions into validated storage offsets.
/// Unlike the forgiving editor-coordinate helpers, request results must never
/// silently land in the middle of a surrogate pair or on a line terminator.
enum LSPPositionCodec {
    enum Error: Swift.Error, Equatable {
        case negativePosition
        case lineOutOfRange
        case characterOutOfRange
        case surrogatePairSplit
    }

    static func offset(_ position: LSPPosition, in text: String) throws -> Int {
        guard position.line >= 0, position.character >= 0 else {
            throw Error.negativePosition
        }

        let utf16 = text.utf16
        var lineStart = utf16.startIndex
        var line = 0
        while line < position.line {
            guard let newline = utf16[lineStart...].firstIndex(of: 10) else {
                throw Error.lineOutOfRange
            }
            lineStart = utf16.index(after: newline)
            line += 1
        }

        let lineBreak = utf16[lineStart...].firstIndex(of: 10) ?? utf16.endIndex
        var lineEnd = lineBreak
        if lineEnd > lineStart {
            let previous = utf16.index(before: lineEnd)
            if utf16[previous] == 13 { lineEnd = previous }
        }
        let length = utf16.distance(from: lineStart, to: lineEnd)
        guard position.character <= length else {
            throw Error.characterOutOfRange
        }

        let target = utf16.index(lineStart, offsetBy: position.character)
        guard target.samePosition(in: text) != nil else {
            throw Error.surrogatePairSplit
        }
        return utf16.distance(from: utf16.startIndex, to: target)
    }
}
