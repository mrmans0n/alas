import AlasHighlight
import TreeSitterPack

/// Hands the Rust grammar pack to `LanguageRegistry`, as the Mac's `PlatformServices.install()` does.
enum GrammarPack {
    static func install() {
        LanguageRegistry.grammarPack = TreeSitterGrammarPack(
            language: { id in id.withCString { alas_ts_language($0) } },
            highlightQuery: { id in
                // The pack returns static UTF-8 bytes that are not NUL-terminated,
                // so the length is read back through `out_len`.
                var length = 0
                guard let bytes = id.withCString({ alas_ts_query($0, &length) }), length > 0 else { return nil }
                return String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
            }
        )
    }
}
