import Foundation

extension LSPFormattingOptions {
    /// Formatting options that match the document's existing indentation.
    static func inferred(from text: String) -> LSPFormattingOptions {
        let unit = IndentationHelper.indentUnit(in: text)
        return LSPFormattingOptions(tabSize: unit == "\t" ? 4 : unit.count, insertSpaces: unit != "\t")
    }
}
