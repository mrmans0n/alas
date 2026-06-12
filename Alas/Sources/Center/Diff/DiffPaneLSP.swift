import AppKit
import Foundation

struct DiffPaneLSPContext {
    let worktreeId: String
    let worktreeRoot: URL
    let relativePath: String
    let language: String
    let lsp: WorkspaceLSPManager
    let openTarget: @MainActor (URL, Int, Int) -> Void

    var fileURL: URL {
        worktreeRoot.appendingPathComponent(relativePath)
    }

    var uri: String {
        fileURL.lspURI
    }
}

enum DiffPaneLSPLineMap {
    static func position(
        at characterIndex: Int,
        metadata: [DiffPaneTextDocumentBuilder.LineMetadata],
        allowedSide: DiffLineSide
    ) -> LSPPosition? {
        guard let line = metadata.first(where: { NSLocationInRange(characterIndex, $0.range) }) else {
            return nil
        }
        guard let source = line.sourceLine,
              source.anchor.side == allowedSide,
              let newLine = source.anchor.newLine,
              newLine > 0
        else {
            return nil
        }

        let character = characterIndex - line.range.location
        guard character >= 0, character < source.text.utf16.count else {
            return nil
        }
        return LSPPosition(line: newLine - 1, character: character)
    }
}
