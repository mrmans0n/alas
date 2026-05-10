import Foundation

@MainActor
final class SymbolsFeature {
    private(set) var symbols: [Item] = []
    var onChange: (() -> Void)?

    struct Item: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let kind: Int
        let line: Int       // 0-based
        let character: Int  // 0-based UTF-16
        let depth: Int
    }

    func refresh(client: LSPClient?, uri: String) async {
        guard let client else { symbols = []
        onChange?()
        return }
        let raw = (try? await client.documentSymbol(uri: uri)) ?? []
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
