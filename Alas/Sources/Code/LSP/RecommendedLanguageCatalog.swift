import Foundation

/// Curated metadata for languages we recommend out of the box: how to
/// install the language server and what to call the language in UI copy.
/// Parallel to `LanguageServerRegistry` — registry says how to *spawn*,
/// catalog says how to *provision*.
struct RecommendedLanguage: Codable, Equatable, Sendable {
    let language: String
    let displayName: String
    let masonId: String?
    let aliasOf: String?           // non-nil → recipes resolve via that language ID
    let recipes: [InstallRecipe]   // empty when aliasOf is set OR when bundled (e.g. swift)
}

enum RecommendedLanguageCatalog {
    /// Single source of truth. Ordering doesn't matter for correctness but is
    /// kept stable for predictable diffs when adding entries.
    static let allEntries: [RecommendedLanguage] = [
        RecommendedLanguage(
            language: "swift",
            displayName: "Swift",
            masonId: nil,
            aliasOf: nil,
            recipes: []
        ),
        RecommendedLanguage(
            language: "rust",
            displayName: "Rust",
            masonId: "rust-analyzer",
            aliasOf: nil,
            // No cargo recipe: the `rust-analyzer` crate on crates.io is a
            // reserved/placeholder name (the actual programmatic crate is
            // `ra_ap_rust_analyzer`), so `cargo install rust-analyzer`
            // doesn't produce the LSP binary. The official install paths
            // are rustup component-add and Homebrew.
            recipes: [
                InstallRecipe(installer: .rustup, package: "", extraArgs: ["component", "add", "rust-analyzer"]),
                InstallRecipe(installer: .brew, package: "rust-analyzer"),
            ]
        ),
        RecommendedLanguage(
            language: "typescript",
            displayName: "TypeScript / JavaScript",
            masonId: "typescript-language-server",
            aliasOf: nil,
            recipes: [
                InstallRecipe(installer: .brew, package: "typescript-language-server"),
                InstallRecipe(installer: .npm, package: "typescript-language-server"),
            ]
        ),
        RecommendedLanguage(
            language: "typescriptreact",
            displayName: "TypeScript / JavaScript",
            masonId: nil,
            aliasOf: "typescript",
            recipes: []
        ),
        RecommendedLanguage(
            language: "javascript",
            displayName: "TypeScript / JavaScript",
            masonId: nil,
            aliasOf: "typescript",
            recipes: []
        ),
        RecommendedLanguage(
            language: "javascriptreact",
            displayName: "TypeScript / JavaScript",
            masonId: nil,
            aliasOf: "typescript",
            recipes: []
        ),
        RecommendedLanguage(
            language: "python",
            displayName: "Python",
            masonId: "pyright",
            aliasOf: nil,
            recipes: [
                InstallRecipe(installer: .brew, package: "pyright"),
                InstallRecipe(installer: .npm, package: "pyright"),
                InstallRecipe(installer: .pipx, package: "pyright"),
            ]
        ),
        RecommendedLanguage(
            language: "go",
            displayName: "Go",
            masonId: "gopls",
            aliasOf: nil,
            recipes: [
                InstallRecipe(installer: .brew, package: "gopls"),
                InstallRecipe(installer: .go, package: "golang.org/x/tools/gopls"),
            ]
        ),
        RecommendedLanguage(
            language: "c",
            displayName: "C / C++",
            masonId: "clangd",
            aliasOf: nil,
            // Homebrew's `llvm` formula is keg-only on macOS: `clangd` lands
            // in `/opt/homebrew/opt/llvm/bin/clangd` which is NOT on the
            // standard PATH and not in our well-known directories, so an
            // install would succeed but availability detection would still
            // report "not installed". clangd is also bundled with Xcode CLT,
            // so most dev machines already have it. Ship without a recipe;
            // power users can wire their own via Add language → manual fields.
            recipes: []
        ),
        RecommendedLanguage(
            language: "cpp",
            displayName: "C / C++",
            masonId: nil,
            aliasOf: "c",
            recipes: []
        ),
        RecommendedLanguage(
            language: "ruby",
            displayName: "Ruby",
            masonId: "ruby-lsp",
            aliasOf: nil,
            recipes: [
                InstallRecipe(installer: .brew, package: "ruby-lsp"),
            ]
        ),
        RecommendedLanguage(
            language: "shellscript",
            displayName: "Shell",
            masonId: "bash-language-server",
            aliasOf: nil,
            recipes: [
                InstallRecipe(installer: .brew, package: "bash-language-server"),
                InstallRecipe(installer: .npm, package: "bash-language-server"),
            ]
        ),
        RecommendedLanguage(
            language: "lua",
            displayName: "Lua",
            masonId: "lua-language-server",
            aliasOf: nil,
            recipes: [
                InstallRecipe(installer: .brew, package: "lua-language-server"),
            ]
        ),
        RecommendedLanguage(
            language: "markdown",
            displayName: "Markdown",
            masonId: "marksman",
            aliasOf: nil,
            recipes: [
                InstallRecipe(installer: .brew, package: "marksman"),
            ]
        ),
        RecommendedLanguage(
            language: "json",
            displayName: "JSON",
            masonId: "vscode-json-languageserver",
            aliasOf: nil,
            recipes: [
                InstallRecipe(installer: .brew, package: "vscode-langservers-extracted"),
                InstallRecipe(installer: .npm, package: "vscode-langservers-extracted"),
            ]
        ),
        RecommendedLanguage(
            language: "jsonc",
            displayName: "JSON",
            masonId: nil,
            aliasOf: "json",
            recipes: []
        ),
        RecommendedLanguage(
            language: "kotlin",
            displayName: "Kotlin",
            masonId: nil,
            aliasOf: nil,
            recipes: [
                InstallRecipe(installer: .brew, package: "JetBrains/utils/kotlin-lsp"),
            ]
        ),
        // Objective-C rides on clangd, so it inherits C's (deliberately
        // empty) recipes for the keg-only-llvm reason documented above.
        RecommendedLanguage(
            language: "objective-c",
            displayName: "Objective-C",
            masonId: nil,
            aliasOf: "c",
            recipes: []
        ),
        RecommendedLanguage(
            language: "objective-cpp",
            displayName: "Objective-C",
            masonId: nil,
            aliasOf: "c",
            recipes: []
        ),
        // Same package as the JSON entry above — one install covers
        // JSON + CSS + SCSS + HTML.
        RecommendedLanguage(
            language: "css",
            displayName: "CSS / SCSS",
            masonId: "css-lsp",
            aliasOf: nil,
            recipes: [
                InstallRecipe(installer: .brew, package: "vscode-langservers-extracted"),
                InstallRecipe(installer: .npm, package: "vscode-langservers-extracted"),
            ]
        ),
        RecommendedLanguage(
            language: "scss",
            displayName: "CSS / SCSS",
            masonId: nil,
            aliasOf: "css",
            recipes: []
        ),
        RecommendedLanguage(
            language: "html",
            displayName: "HTML",
            masonId: "html-lsp",
            aliasOf: nil,
            recipes: [
                InstallRecipe(installer: .brew, package: "vscode-langservers-extracted"),
                InstallRecipe(installer: .npm, package: "vscode-langservers-extracted"),
            ]
        ),
        RecommendedLanguage(
            language: "scala",
            displayName: "Scala",
            masonId: "metals",
            aliasOf: nil,
            recipes: [
                InstallRecipe(installer: .brew, package: "metals"),
            ]
        ),
        RecommendedLanguage(
            language: "clojure",
            displayName: "Clojure",
            masonId: "clojure-lsp",
            aliasOf: nil,
            recipes: [
                InstallRecipe(installer: .brew, package: "clojure-lsp"),
            ]
        ),
        RecommendedLanguage(
            language: "zig",
            displayName: "Zig",
            masonId: "zls",
            aliasOf: nil,
            recipes: [
                InstallRecipe(installer: .brew, package: "zls"),
            ]
        ),
        RecommendedLanguage(
            language: "elixir",
            displayName: "Elixir",
            masonId: "elixir-ls",
            aliasOf: nil,
            recipes: [
                InstallRecipe(installer: .brew, package: "elixir-ls"),
            ]
        ),
        RecommendedLanguage(
            language: "cmake",
            displayName: "CMake",
            masonId: "cmake-language-server",
            aliasOf: nil,
            recipes: [
                InstallRecipe(installer: .brew, package: "cmake-language-server"),
                InstallRecipe(installer: .pipx, package: "cmake-language-server"),
            ]
        ),
        // The language server is a subcommand of the SDK, so the install is
        // the whole SDK rather than a standalone server package.
        RecommendedLanguage(
            language: "dart",
            displayName: "Dart",
            masonId: nil,
            aliasOf: nil,
            recipes: [
                InstallRecipe(installer: .brew, package: "dart-sdk"),
            ]
        ),
        // Homebrew's haskell-language-server is built against specific GHC
        // versions and does not bring one: its own caveat says "You need to
        // provide your own GHC or install one with `brew install ghc`".
        // Installing this alone gets a server that completes the LSP
        // handshake but cannot type-check a project until a matching GHC is
        // present — worth knowing before treating a green install as done.
        RecommendedLanguage(
            language: "haskell",
            displayName: "Haskell",
            masonId: "haskell-language-server",
            aliasOf: nil,
            recipes: [
                InstallRecipe(installer: .brew, package: "haskell-language-server"),
            ]
        ),
    ]

    private static let byLanguage: [String: RecommendedLanguage] = Dictionary(
        uniqueKeysWithValues: allEntries.map { ($0.language, $0) }
    )

    static func entry(forLanguage language: String) -> RecommendedLanguage? {
        byLanguage[language]
    }

    /// All language IDs served by the same install as `language`. Used after
    /// an install completes to re-fire `didOpen` for buffers in every
    /// language the just-installed package covers (e.g. installing
    /// typescript-language-server from a `.tsx` banner should also revive
    /// open `.ts`/`.js`/`.jsx` tabs).
    ///
    /// Membership is two things, not one:
    ///
    /// 1. the alias chain — the canonical language plus everything aliasing
    ///    to it, which covers the TypeScript family and C/C++/Objective-C;
    /// 2. any *other* canonical language whose resolved recipes are
    ///    identical, because one package can supply several servers that are
    ///    not aliases of each other. `vscode-langservers-extracted` is the
    ///    case in point: it installs the JSON, CSS and HTML binaries in one
    ///    go, so installing it from a CSS banner has to revive open HTML and
    ///    JSON tabs too — they are equally un-blocked by that install.
    ///
    /// Recipe matching is skipped for entries with no recipes at all, or
    /// every bundled/unprovisioned language (swift, c, …) would collapse
    /// into one group on the strength of being equally empty.
    ///
    /// If `language` is not in the catalog, returns `[language]` unchanged.
    static func aliasGroup(forLanguage language: String) -> [String] {
        // Canonical = either the alias target or this entry itself. For
        // languages we don't recognize, the caller's own ID is the only
        // thing we can confidently include.
        guard let entry = byLanguage[language] else { return [language] }
        let canonical = entry.aliasOf ?? entry.language
        var group = [canonical]
        for other in allEntries where other.aliasOf == canonical && other.language != canonical {
            group.append(other.language)
        }

        let recipes = entry.resolvedRecipes
        guard !recipes.isEmpty else { return group }
        for other in allEntries
        where !group.contains(other.language) && other.resolvedRecipes == recipes {
            group.append(other.language)
        }
        return group
    }
}

extension RecommendedLanguage {
    /// Returns this entry's recipes, recursively following `aliasOf`. The
    /// catalog's invariant is that alias targets are themselves canonical, so
    /// recursion bottoms out in one hop today; recursion is used defensively
    /// in case a future edit chains aliases.
    var resolvedRecipes: [InstallRecipe] {
        if let target = aliasOf,
           let canonical = RecommendedLanguageCatalog.entry(forLanguage: target) {
            return canonical.resolvedRecipes
        }
        return recipes
    }
}
