import Foundation
import SwiftTreeSitter
import TreeSitterPack

/// Maps a file extension to a `SwiftTreeSitter.Language` and the matching
/// `highlights.scm` `Query`. `Language` and `Query` are immutable after
/// construction, so we memoize them at module level — without this,
/// `DiffTabView`'s per-line `tokenize` calls would re-scan and recompile the
/// query thousands of times per render.
///
/// Grammars and queries both come from `ThirdParty/treesitter-pack`, a Rust
/// staticlib linked into the app (see `scripts/build-treesitter-pack.sh`).
/// Queries are compiled into the binary there, so there is nothing to look up
/// on disk at runtime.
enum LanguageRegistry {
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var languageCache: [String: Language] = [:]
    nonisolated(unsafe) private static var queryCache: [String: Query] = [:]
    nonisolated(unsafe) private static var queryMissCache: Set<String> = []

    /// File extension → grammar id in the pack. `markdown-inline` and
    /// `php-only` are not real extensions; they are how callers ask for the
    /// sub-grammars used to highlight embedded content.
    private static let languageIDsByExtension: [String: String] = [
        "swift": "swift",
        "yaml": "yaml", "yml": "yaml",
        "json": "json",
        "toml": "toml",
        "py": "python",
        "rb": "ruby",
        "lua": "lua",
        "rs": "rust",
        "go": "go",
        "sh": "bash", "bash": "bash", "zsh": "bash",
        // All JS variants share one grammar — it parses JSX natively.
        "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "jsx": "javascript",
        "ts": "typescript",
        "tsx": "tsx",
        "java": "java",
        "kt": "kotlin", "kts": "kotlin",
        "c": "c", "h": "c",
        "cpp": "cpp", "cc": "cpp", "cxx": "cpp",
        "hpp": "cpp", "hh": "cpp", "hxx": "cpp",
        "html": "html", "htm": "html",
        "css": "css",
        "php": "php",
        "php-only": "php_only",
        "md": "markdown", "markdown": "markdown",
        "markdown-inline": "markdown_inline",
        "hcl": "hcl", "tf": "hcl", "tfvars": "hcl",
        "dockerfile": "dockerfile",
        "cs": "csharp", "csx": "csharp",
        "scala": "scala", "sc": "scala", "sbt": "scala",
        "r": "r",
        "dart": "dart",
        "ex": "elixir", "exs": "elixir",
        "erl": "erlang", "hrl": "erlang",
        "hs": "haskell", "lhs": "haskell",
        "clj": "clojure", "cljs": "clojure", "cljc": "clojure", "edn": "clojure",
        "jl": "julia",
        "zig": "zig",
        "ps1": "powershell", "psm1": "powershell", "psd1": "powershell",
        // Gradle build scripts are Groovy; `.gradle.kts` lands on Kotlin via
        // its own `kts` entry above.
        "groovy": "groovy", "gradle": "groovy", "gvy": "groovy",
        // `.m` is Objective-C here rather than MATLAB — this is a macOS
        // workspace, and `.mm` next to it is unambiguous.
        "m": "objc", "mm": "objc",
        "sql": "sql",
        "graphql": "graphql", "gql": "graphql",
        "proto": "proto",
        "scss": "scss",
        "svelte": "svelte",
        "xml": "xml", "xsd": "xml", "xsl": "xml", "xslt": "xml", "svg": "xml",
        "plist": "xml", "storyboard": "xml", "xib": "xml",
        "csproj": "xml", "resx": "xml",
        "ini": "ini", "cfg": "ini", "properties": "ini",
        "mk": "make",
        "cmake": "cmake",
        // TypeScript's ESM/CJS variants, which the base `ts` entry misses.
        "mts": "typescript", "cts": "typescript"
    ]

    /// Files whose language is carried by the whole filename rather than an
    /// extension. Values are keys into `languageIDsByExtension`, not grammar
    /// ids. `CMakeLists.txt` is why this is matched before the extension: its
    /// `.txt` would otherwise win and resolve to nothing.
    private static let extensionsByFilename: [String: String] = [
        "dockerfile": "dockerfile",
        "containerfile": "dockerfile",
        "makefile": "mk",
        "gnumakefile": "mk",
        "cmakelists.txt": "cmake",
        ".editorconfig": "ini",
        "jenkinsfile": "groovy"
    ]

    /// Grammar ids whose highlight query is more than just their own, listed
    /// in concatenation order. This covers two cases: grammars that inherit
    /// patterns from a base grammar via a `;;; inherits:` directive nothing in
    /// this path honors (TS ⇐ JS, C++ ⇐ C), and grammars shipping an overlay
    /// beside the base query (JS + JSX). Any id absent here uses its own query.
    ///
    /// The JSX overlay is merged for every JavaScript file, not just `.jsx` —
    /// in pure-JS files its patterns simply never match. TSX gets it too, but
    /// plain TypeScript must not: that grammar has no `jsx_*` nodes, so
    /// including the overlay would fail `Query` compilation outright.
    /// Objective-C and SCSS both extend another grammar the same way C++ does.
    /// SCSS is the starkest case: its own query covers only SCSS-specific
    /// constructs (mixins, `@use`, variables) and names no selector, property,
    /// colour or comment node at all, so without CSS merged in front of it a
    /// stylesheet would highlight almost nothing.
    private static let queryIDsByLanguageID: [String: [String]] = [
        "javascript": ["javascript", "javascript_jsx"],
        "typescript": ["javascript", "typescript"],
        "tsx": ["javascript", "javascript_jsx", "tsx"],
        "cpp": ["c", "cpp"],
        "objc": ["c", "objc"],
        "scss": ["css", "scss"]
    ]

    static func highlighterExtension(forPath path: String) -> String {
        let filename = (path as NSString).lastPathComponent.lowercased()
        if let byFilename = extensionsByFilename[filename] { return byFilename }
        return (path as NSString).pathExtension.lowercased()
    }

    static func language(forFileExtension ext: String) -> Language? {
        let key = ext.lowercased()
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = languageCache[key] { return cached }
        guard let id = languageIDsByExtension[key],
              let pointer = id.withCString({ alas_ts_language($0) }) else {
            return nil
        }
        let lang = Language(OpaquePointer(pointer))
        languageCache[key] = lang
        return lang
    }

    /// Loads and compiles the highlight query for `ext`.
    static func highlightQuery(forExtension ext: String) -> Query? {
        let key = ext.lowercased()
        cacheLock.lock()
        if let cached = queryCache[key] {
            cacheLock.unlock()
            return cached
        }
        if queryMissCache.contains(key) {
            cacheLock.unlock()
            return nil
        }
        cacheLock.unlock()

        let query: Query?
        if let lang = language(forFileExtension: key),
           let id = languageIDsByExtension[key] {
            if id == "php_only" {
                query = phpOnlyQuery(language: lang)
            } else {
                query = mergedQuery(ids: queryIDsByLanguageID[id] ?? [id], language: lang)
            }
        } else {
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

    /// Compiles the concatenation of `ids`' queries as one `Query`. Missing
    /// ids are skipped rather than failing the whole query, matching how the
    /// previous bundle-based loader tolerated an absent `.scm`.
    private static func mergedQuery(ids: [String], language: Language) -> Query? {
        let combined = ids.compactMap(queryText(id:)).joined(separator: "\n")
        guard !combined.isEmpty else { return nil }
        return try? Query(language: language, data: Data(combined.utf8))
    }

    /// PHP-only reuses the PHP query with the `php_tag`/`php_end_tag` pattern
    /// removed — that grammar has no such nodes.
    private static func phpOnlyQuery(language: Language) -> Query? {
        guard let text = queryText(id: "php") else { return nil }
        return try? Query(language: language, data: Data(phpOnlyQueryText(from: text).utf8))
    }

    /// The pack returns static UTF-8 bytes that are not NUL-terminated, so the
    /// length is read back through `out_len` rather than inferred.
    private static func queryText(id: String) -> String? {
        var length = 0
        guard let bytes = id.withCString({ alas_ts_query($0, &length) }), length > 0 else {
            return nil
        }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
    }

    static func phpOnlyQueryText(from queryText: String) -> String {
        let pattern = #"\[\s*\(php_tag\)\s*\(php_end_tag\)\s*\]\s*@tag\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return queryText
        }
        let range = NSRange(location: 0, length: (queryText as NSString).length)
        return regex.stringByReplacingMatches(in: queryText, range: range, withTemplate: "")
    }
}
