import Foundation
import SwiftTreeSitter
import TreeSitterSwift
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
        guard let bundle = grammarBundle(named: needle) else { return nil }
        let url = bundle.url(forResource: "queries/\(name)", withExtension: "scm")
            ?? bundle.url(forResource: name, withExtension: "scm",
                          subdirectory: "queries")
            ?? bundle.url(forResource: name, withExtension: "scm")
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? Query(language: language, data: data)
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
