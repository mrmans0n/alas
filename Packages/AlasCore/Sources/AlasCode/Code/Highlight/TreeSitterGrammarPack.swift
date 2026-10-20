import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures

/// Grammars and highlight queries from the bundled tree-sitter pack, a Rust
/// staticlib linked into the app. `PlatformServices.install()` sets the real
/// lookups at launch, before any reads; until then no language resolves.
public struct TreeSitterGrammarPack: Sendable {
    /// The `TSLanguage` pointer for a language id.
    public var language: @Sendable (String) -> UnsafeRawPointer?
    /// The highlight query source for a language id.
    public var highlightQuery: @Sendable (String) -> String?

    public init(language: @escaping @Sendable (String) -> UnsafeRawPointer?, highlightQuery: @escaping @Sendable (String) -> String?) {
        self.language = language
        self.highlightQuery = highlightQuery
    }
}

extension LanguageRegistry {
    public nonisolated(unsafe) static var grammarPack = TreeSitterGrammarPack(language: { _ in nil }, highlightQuery: { _ in nil })
}
