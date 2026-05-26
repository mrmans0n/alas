import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterGo
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterKotlin
import TreeSitterJSON
import TreeSitterPython
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTOML
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

/// Maps a file extension to a `SwiftTreeSitter.Language` and the
/// matching `highlights.scm` `Query`. `Language` and `Query` are immutable
/// after construction, so we memoize them at module level — without this,
/// `DiffTabView`'s per-line `tokenize` calls would re-scan the bundle and
/// recompile the query thousands of times per render.
enum LanguageRegistry {
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var languageCache: [String: Language] = [:]
    nonisolated(unsafe) private static var queryCache: [String: Query] = [:]
    nonisolated(unsafe) private static var queryMissCache: Set<String> = []

    static func language(forFileExtension ext: String) -> Language? {
        let key = ext.lowercased()
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = languageCache[key] { return cached }
        let lang: Language?
        switch key {
        case "swift":         lang = Language(language: tree_sitter_swift())
        case "yaml", "yml":   lang = Language(language: tree_sitter_yaml())
        case "json":          lang = Language(language: tree_sitter_json())
        case "toml":          lang = Language(language: tree_sitter_toml())
        case "py":            lang = Language(language: tree_sitter_python())
        case "rs":            lang = Language(language: tree_sitter_rust())
        case "go":            lang = Language(language: tree_sitter_go())
        case "sh", "bash":    lang = Language(language: tree_sitter_bash())
        case "js", "mjs", "cjs", "jsx":
                              lang = Language(language: tree_sitter_javascript())
        case "ts":            lang = Language(language: tree_sitter_typescript())
        case "tsx":           lang = Language(language: tree_sitter_tsx())
        case "java":          lang = Language(language: tree_sitter_java())
        case "kt", "kts":     lang = Language(language: tree_sitter_kotlin())
        default:              lang = nil
        }
        if let lang { languageCache[key] = lang }
        return lang
    }

    /// Loads the highlight query bundled with the grammar package.
    static func highlightQuery(forExtension ext: String) -> Query? {
        let key = ext.lowercased()
        cacheLock.lock()
        if let cached = queryCache[key] { cacheLock.unlock()
        return cached }
        if queryMissCache.contains(key) { cacheLock.unlock()
        return nil }
        cacheLock.unlock()

        guard let lang = language(forFileExtension: ext) else { return nil }
        let query: Query?
        switch key {
        case "swift":
            query = loadQuery(named: "highlights",
                              bundleNameContains: "TreeSitterSwift",
                              language: lang)
        case "yaml", "yml":
            query = loadQuery(named: "highlights",
                              bundleNameContains: "TreeSitterYAML",
                              language: lang)
        case "json":
            query = loadQuery(named: "highlights",
                              bundleNameContains: "TreeSitterJSON",
                              language: lang)
        case "toml":
            query = loadQuery(named: "highlights",
                              bundleNameContains: "TreeSitterTOML",
                              language: lang)
        case "py":
            query = loadQuery(named: "highlights",
                              bundleNameContains: "TreeSitterPython",
                              language: lang)
        case "rs":
            query = loadQuery(named: "highlights",
                              bundleNameContains: "TreeSitterRust",
                              language: lang)
        case "go":
            query = loadQuery(named: "highlights",
                              bundleNameContains: "TreeSitterGo",
                              language: lang)
        case "sh", "bash":
            query = loadQuery(named: "highlights",
                              bundleNameContains: "TreeSitterBash",
                              language: lang)
        case "js", "mjs", "cjs", "jsx":
            query = loadQuery(named: "highlights",
                              bundleNameContains: "TreeSitterJavaScript",
                              language: lang)
        case "ts":
            // TS query inherits from JS — merge them so strings, functions,
            // comments etc. are colored alongside the TS-specific captures.
            query = loadMergedQuery(
                named: "highlights",
                bundleNeedles: ["TreeSitterJavaScript", "TreeSitterTypeScript_TreeSitterTypeScript"],
                language: lang
            )
        case "tsx":
            query = loadMergedQuery(
                named: "highlights",
                bundleNeedles: ["TreeSitterJavaScript", "TreeSitterTypeScript_TreeSitterTSX"],
                language: lang
            )
        case "java":
            query = loadQuery(named: "highlights",
                              bundleNameContains: "TreeSitterJava_TreeSitterJava",
                              language: lang)
        case "kt", "kts":
            query = loadQuery(named: "highlights",
                              bundleNameContains: "TreeSitterKotlin",
                              language: lang)
        default:
            query = nil
        }

        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let query {
            queryCache[key] = query
        } else {
            queryMissCache.insert(key)
        }
        return query
    }

    /// The grammar packages ship pure C with no Swift symbol we can
    /// pass to `Bundle(for:)`, so we locate the resource bundle by
    /// scanning `Bundle.allBundles` for the SPM-generated name
    /// (`<Pkg>_<Target>.bundle`, e.g. `TreeSitterSwift_TreeSitterSwift.bundle`).
    private static func loadQuery(
        named name: String,
        bundleNameContains needle: String,
        language: Language
    ) -> Query? {
        loadMergedQuery(
            named: name,
            bundleNeedles: [needle],
            language: language
        )
    }

    /// Loads `.scm` files from multiple bundles and compiles their
    /// concatenated text as one Query against `language`. Tree-sitter
    /// grammars often inherit query patterns from a base grammar (e.g.
    /// TypeScript inherits from JavaScript via a `;;; inherits:` comment
    /// the SwiftTreeSitter loader doesn't honor); concatenating the
    /// inherited base file with the derived overlay reproduces the
    /// expected behavior. Bundles are looked up in order; any missing one
    /// is silently skipped, which keeps the call sites tidy when an
    /// optional overlay isn't present.
    private static func loadMergedQuery(
        named name: String,
        bundleNeedles needles: [String],
        language: Language
    ) -> Query? {
        var combined = Data()
        for needle in needles {
            guard let bundle = grammarBundle(named: needle) else { continue }
            let url = bundle.url(forResource: "queries/\(name)", withExtension: "scm")
                ?? bundle.url(forResource: name, withExtension: "scm",
                              subdirectory: "queries")
                ?? bundle.url(forResource: name, withExtension: "scm")
            guard let url, let data = try? Data(contentsOf: url) else { continue }
            combined.append(data)
            combined.append(0x0A)  // newline between files
        }
        guard !combined.isEmpty else { return nil }
        return try? Query(language: language, data: combined)
    }

    private static func grammarBundle(named needle: String) -> Bundle? {
        // Resource-only bundles produced by SPM (e.g.
        // `TreeSitterSwift_TreeSitterSwift.bundle`) live next to the host
        // executable in `Contents/Resources/` — they aren't in
        // `Bundle.allBundles` until explicitly loaded. Search the host's
        // bundleURL for a child whose lastPathComponent contains `needle`,
        // covering both the app target and the .xctest test runner.
        let candidates: [Bundle] = [.main] + Bundle.allBundles + Bundle.allFrameworks
        for host in candidates {
            let resourcesURL = host.bundleURL.appendingPathComponent("Contents/Resources")
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: resourcesURL, includingPropertiesForKeys: nil
            ) {
                if let match = entries.first(where: {
                    $0.lastPathComponent.contains(needle)
                        && $0.pathExtension == "bundle"
                }), let b = Bundle(url: match) {
                    return b
                }
            }
        }
        // Last-ditch fallback for bundles already loaded by name.
        if let b = Bundle.allBundles.first(where: {
            $0.bundleURL.lastPathComponent.contains(needle)
        }) {
            return b
        }
        return nil
    }
}
