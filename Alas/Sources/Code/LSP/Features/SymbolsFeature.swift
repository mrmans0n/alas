import Foundation

@MainActor
final class SymbolsFeature {
    private(set) var symbols: [Item] = []
    var onChange: (() -> Void)?
    private var requestID: UInt64 = 0

    struct Item: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let kind: Int
        let line: Int       // 0-based
        let character: Int  // 0-based UTF-16
        let depth: Int
    }

    func refresh(client: LSPClient?, uri: String) async {
        requestID += 1
        let currentRequestID = requestID
        guard let client else {
            symbols = []
            onChange?()
            return
        }
        let raw = (try? await client.documentSymbol(uri: uri)) ?? []
        guard !Task.isCancelled, requestID == currentRequestID else { return }
        var flat: [Item] = []
        func walk(_ list: [LSPDocumentSymbol], depth: Int) {
            for s in list {
                flat.append(Item(
                    name: s.name, kind: s.kind,
                    line: s.selectionRange.start.line,
                    character: s.selectionRange.start.character,
                    depth: depth
                ))
                if let kids = s.children { walk(kids, depth: depth + 1) }
            }
        }
        walk(raw, depth: 0)
        symbols = flat
        onChange?()
    }
}
