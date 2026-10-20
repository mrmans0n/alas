import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures

extension LSPFormattingOptions {
    /// Formatting options that match the document's existing indentation.
    public static func inferred(from text: String) -> LSPFormattingOptions {
        let unit = IndentationHelper.indentUnit(in: text)
        return LSPFormattingOptions(tabSize: unit == "\t" ? 4 : unit.count, insertSpaces: unit != "\t")
    }
}
