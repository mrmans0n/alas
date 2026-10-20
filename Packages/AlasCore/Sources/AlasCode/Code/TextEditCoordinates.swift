import Foundation
import SwiftTreeSitter
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures

public struct EditorTextEdit: Sendable, Equatable {
    public let location: Int
    public let oldLength: Int
    public let replacementText: String

    public var newLength: Int { (replacementText as NSString).length }
    public var oldRange: NSRange { NSRange(location: location, length: oldLength) }
    public var newRange: NSRange { NSRange(location: location, length: newLength) }

    public init(location: Int, oldLength: Int, replacementText: String) {
        self.location = location
        self.oldLength = oldLength
        self.replacementText = replacementText
    }
}

public enum TextEditCoordinates: Sendable {
    public struct LineIndex: Sendable {
        private let starts: [Int]
        private var textLength: Int
        private var shiftedAfterLine: Int?
        private var suffixShift = 0

        public init(_ text: String) {
            let ns = text as NSString
            var starts = [0]
            for index in 0..<ns.length where ns.character(at: index) == 10 {
                starts.append(index + 1)
            }
            self.starts = starts
            textLength = ns.length
        }

        public func adjustingOffsets(after offset: Int, by delta: Int) -> LineIndex? {
            guard delta != 0 else { return self }
            guard let line = lspPosition(utf16Offset: offset)?.line,
                  shiftedAfterLine == nil || shiftedAfterLine == line else { return nil }
            var adjusted = self
            adjusted.shiftedAfterLine = line
            adjusted.suffixShift += delta
            adjusted.textLength += delta
            return adjusted
        }

        public func utf16Offset(from position: LSPPosition) -> Int? {
            guard starts.indices.contains(position.line), position.character >= 0 else { return nil }
            let lineEnd = position.line + 1 < starts.count ? lineStart(position.line + 1) - 1 : textLength
            let offset = lineStart(position.line) + position.character
            return offset <= lineEnd ? offset : nil
        }

        public func lspPosition(utf16Offset target: Int) -> LSPPosition? {
            guard target >= 0, target <= textLength else { return nil }
            var lowerBound = 0
            var upperBound = starts.count
            while lowerBound < upperBound {
                let middle = (lowerBound + upperBound) / 2
                if lineStart(middle) <= target {
                    lowerBound = middle + 1
                } else {
                    upperBound = middle
                }
            }
            let line = lowerBound - 1
            return LSPPosition(line: line, character: target - lineStart(line))
        }

        private func lineStart(_ line: Int) -> Int {
            starts[line] + (shiftedAfterLine.map { line > $0 } == true ? suffixShift : 0)
        }
    }

    public static func apply(_ edit: EditorTextEdit, to text: String) -> String? {
        let ns = text as NSString
        guard edit.location >= 0,
              edit.oldLength >= 0,
              NSMaxRange(edit.oldRange) <= ns.length else {
            return nil
        }
        return ns.replacingCharacters(in: edit.oldRange, with: edit.replacementText)
    }

    public static func lspRange(for range: NSRange, in text: String) -> LSPRange? {
        guard let start = lspPosition(utf16Offset: range.location, in: text),
              let end = lspPosition(utf16Offset: NSMaxRange(range), in: text) else {
            return nil
        }
        return LSPRange(start: start, end: end)
    }

    public static func inputEdit(for edit: EditorTextEdit, oldText: String, newText: String) -> InputEdit? {
        guard let start = point(utf16Offset: edit.location, in: oldText),
              let oldEnd = point(utf16Offset: edit.location + edit.oldLength, in: oldText),
              let newEnd = point(utf16Offset: edit.location + edit.newLength, in: newText) else {
            return nil
        }
        return InputEdit(
            startByte: edit.location * 2,
            oldEndByte: (edit.location + edit.oldLength) * 2,
            newEndByte: (edit.location + edit.newLength) * 2,
            startPoint: Point(row: start.line, column: start.byteColumn),
            oldEndPoint: Point(row: oldEnd.line, column: oldEnd.byteColumn),
            newEndPoint: Point(row: newEnd.line, column: newEnd.byteColumn)
        )
    }

    public static func lspPosition(utf16Offset target: Int, in text: String) -> LSPPosition? {
        LineIndex(text).lspPosition(utf16Offset: target)
    }

    public static func utf16Offset(from position: LSPPosition, in text: String) -> Int? {
        LineIndex(text).utf16Offset(from: position)
    }

    private static func point(utf16Offset target: Int, in text: String) -> (line: Int, character: Int, byteColumn: Int)? {
        let ns = text as NSString
        guard target >= 0, target <= ns.length else { return nil }
        var line = 0
        var lineStart = 0
        var index = 0
        while index < target {
            if ns.character(at: index) == 10 {
                line += 1
                lineStart = index + 1
            }
            index += 1
        }
        let character = target - lineStart
        return (line, character, character * 2)
    }
}
