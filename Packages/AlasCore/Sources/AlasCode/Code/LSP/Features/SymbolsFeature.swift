import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures

@MainActor
public final class SymbolsFeature {
    public private(set) var symbols: [Item] = []
    public var onChange: (() -> Void)?
    private var requestID: UInt64 = 0

    public struct Item: Identifiable, Hashable, Sendable {
        public let id = UUID()
        public let name: String
        public let kind: Int
        public let line: Int       // 0-based
        public let character: Int  // 0-based UTF-16
        public let depth: Int

        public init(name: String, kind: Int, line: Int, character: Int, depth: Int) {
            self.name = name
            self.kind = kind
            self.line = line
            self.character = character
            self.depth = depth
        }
    }

    public func refresh(client: LSPClient?, uri: String) async {
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

    public init() {}
}
