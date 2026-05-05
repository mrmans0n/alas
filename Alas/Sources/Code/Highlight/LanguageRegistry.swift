import Foundation
import SwiftTreeSitter
import TreeSitterSwift

/// Maps a file extension to a `SwiftTreeSitter.Language` and the
/// matching `highlights.scm` `Query`. Both lookups are cached at the
/// call site of the highlighter (we don't cache here yet — one query
/// per highlight call is fine for v1; if that becomes a hot path,
/// memoize on `ext`).
enum LanguageRegistry {
    static func language(forFileExtension ext: String) -> Language? {
        switch ext.lowercased() {
        case "swift":
            return Language(language: tree_sitter_swift())
        default:
            return nil
        }
    }

    /// Loads the highlight query bundled with the grammar package.
    static func highlightQuery(forExtension ext: String) -> Query? {
        guard let lang = language(forFileExtension: ext) else { return nil }
        switch ext.lowercased() {
        case "swift":
            return loadQuery(named: "highlights",
                             bundleNameContains: "TreeSitterSwift",
                             language: lang)
        default:
            return nil
        }
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
        guard let url else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
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
