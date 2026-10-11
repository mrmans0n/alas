import Foundation

/// Grammars and highlight queries from the bundled tree-sitter pack, a Rust
/// staticlib linked into the app. `PlatformServices.install()` sets the real
/// lookups at launch, before any reads; until then no language resolves.
struct TreeSitterGrammarPack: Sendable {
    /// The `TSLanguage` pointer for a language id.
    var language: @Sendable (String) -> UnsafeRawPointer?
    /// The highlight query source for a language id.
    var highlightQuery: @Sendable (String) -> String?
}

extension LanguageRegistry {
    nonisolated(unsafe) static var grammarPack = TreeSitterGrammarPack(language: { _ in nil }, highlightQuery: { _ in nil })
}
