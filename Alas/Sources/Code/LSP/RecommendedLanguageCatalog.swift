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
            recipes: [
                InstallRecipe(installer: .rustup, package: "", extraArgs: ["component", "add", "rust-analyzer"]),
                InstallRecipe(installer: .brew, package: "rust-analyzer"),
                InstallRecipe(installer: .cargo, package: "rust-analyzer"),
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
            recipes: [
                // clangd ships inside the llvm formula on macOS
                InstallRecipe(installer: .brew, package: "llvm"),
            ]
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
            // kotlin-lsp (JetBrains) is distributed via GitHub releases only — out of scope.
            // kotlin-language-server (community/fwcd) is a different server and would not
            // satisfy the LanguageServerRegistry spawn expectation for "kotlin-lsp".
            recipes: []
        ),
    ]

    private static let byLanguage: [String: RecommendedLanguage] = Dictionary(
        uniqueKeysWithValues: allEntries.map { ($0.language, $0) }
    )

    static func entry(forLanguage language: String) -> RecommendedLanguage? {
        byLanguage[language]
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
