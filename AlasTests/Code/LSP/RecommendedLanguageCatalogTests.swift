import Foundation
import Testing
@testable import Alas

@Suite("RecommendedLanguageCatalog")
struct RecommendedLanguageCatalogTests {
    @Test("rust entry exists with rustup → brew → cargo order")
    func rustRecipes() {
        let entry = RecommendedLanguageCatalog.entry(forLanguage: "rust")
        #expect(entry != nil)
        let installers = entry!.resolvedRecipes.map(\.installer)
        #expect(installers == [.rustup, .brew, .cargo])
        // rustup uses extraArgs, not package
        #expect(entry!.resolvedRecipes[0].extraArgs == ["component", "add", "rust-analyzer"])
        #expect(entry!.resolvedRecipes[1].package == "rust-analyzer")
    }

    @Test("typescriptreact aliases to typescript")
    func aliasResolution() {
        let alias = RecommendedLanguageCatalog.entry(forLanguage: "typescriptreact")
        let canonical = RecommendedLanguageCatalog.entry(forLanguage: "typescript")
        #expect(alias != nil)
        #expect(canonical != nil)
        #expect(alias!.resolvedRecipes == canonical!.resolvedRecipes)
    }

    @Test("javascript and javascriptreact alias to typescript")
    func jsAliases() {
        for lang in ["javascript", "javascriptreact"] {
            let entry = RecommendedLanguageCatalog.entry(forLanguage: lang)
            #expect(entry?.resolvedRecipes.first?.installer == .brew)
            #expect(entry?.resolvedRecipes.first?.package == "typescript-language-server")
        }
    }

    @Test("jsonc aliases to json")
    func jsoncAlias() {
        let entry = RecommendedLanguageCatalog.entry(forLanguage: "jsonc")
        #expect(entry?.resolvedRecipes.first?.package == "vscode-langservers-extracted")
    }

    @Test("cpp aliases to c (clangd)")
    func cppAlias() {
        let entry = RecommendedLanguageCatalog.entry(forLanguage: "cpp")
        #expect(entry?.resolvedRecipes.first?.installer == .brew)
        // clangd ships in the llvm formula on macOS
        #expect(entry?.resolvedRecipes.first?.package == "llvm")
    }

    @Test("unknown language returns nil")
    func unknownLanguage() {
        #expect(RecommendedLanguageCatalog.entry(forLanguage: "elvish") == nil)
    }

    @Test("every catalog entry resolves to a LanguageServerRegistry built-in")
    func driftGuard() {
        let registryLanguages = Set(LanguageServerRegistry.builtIns.map(\.language))
        for entry in RecommendedLanguageCatalog.allEntries {
            #expect(
                registryLanguages.contains(entry.language),
                "Catalog has '\(entry.language)' but LanguageServerRegistry.builtIns does not"
            )
        }
    }

    @Test("core mainstream languages are present")
    func coreMainstreamPresent() {
        for lang in ["swift", "rust", "typescript", "python", "go", "c", "cpp", "ruby", "bash", "lua", "markdown", "json", "kotlin"] {
            #expect(
                RecommendedLanguageCatalog.entry(forLanguage: lang) != nil,
                "Missing catalog entry for \(lang)"
            )
        }
    }

    @Test("alias entries carry empty own recipes")
    func aliasOwnRecipesEmpty() {
        let alias = RecommendedLanguageCatalog.allEntries.first(where: { $0.language == "typescriptreact" })
        #expect(alias?.aliasOf == "typescript")
        #expect(alias?.recipes.isEmpty == true)
    }

    @Test("swift entry has no install recipes (xcrun-bundled)")
    func swiftHasNoRecipes() {
        let entry = RecommendedLanguageCatalog.entry(forLanguage: "swift")
        #expect(entry != nil)
        #expect(entry!.resolvedRecipes.isEmpty)
    }

    @Test("go entry uses correct gopls module path")
    func goRecipes() {
        let entry = RecommendedLanguageCatalog.entry(forLanguage: "go")
        let goRecipe = entry?.resolvedRecipes.first(where: { $0.installer == .go })
        #expect(goRecipe?.package == "golang.org/x/tools/gopls")
    }
}
