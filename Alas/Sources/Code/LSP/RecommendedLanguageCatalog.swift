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
    ]

    private static let byLanguage: [String: RecommendedLanguage] = Dictionary(
        uniqueKeysWithValues: allEntries.map { ($0.language, $0) }
    )

    static func entry(forLanguage language: String) -> RecommendedLanguage? {
        byLanguage[language]
    }

    /// All language IDs that share the same install recipes as `language` —
    /// i.e. the canonical language plus every entry that aliases to it. Used
    /// after an install completes to re-fire `didOpen` for buffers in every
    /// language served by the just-installed binary (e.g. installing
    /// typescript-language-server from a `.tsx` banner should also revive
    /// open `.ts`/`.js`/`.jsx` tabs).
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
