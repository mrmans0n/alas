import Foundation
import Testing
@testable import Alas

@Suite("RecommendedLanguageCatalog")
struct RecommendedLanguageCatalogTests {
    @Test("rust entry exists with rustup → brew order (no cargo)")
    func rustRecipes() {
        let entry = RecommendedLanguageCatalog.entry(forLanguage: "rust")
        #expect(entry != nil)
        let installers = entry!.resolvedRecipes.map(\.installer)
        // `cargo install rust-analyzer` is a no-op (crates.io name is reserved),
        // so we don't offer it as a recipe even when cargo is detected.
        #expect(installers == [.rustup, .brew])
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

    @Test("cpp aliases to c (clangd; no installable recipe)")
    func cppAlias() {
        let entry = RecommendedLanguageCatalog.entry(forLanguage: "cpp")
        #expect(entry?.aliasOf == "c")
        // c has empty recipes — brew install llvm is keg-only and would not
        // make clangd discoverable on PATH (see RecommendedLanguageCatalog).
        #expect(entry?.resolvedRecipes.isEmpty == true)
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
        for lang in ["swift", "rust", "typescript", "python", "go", "c", "cpp", "ruby", "shellscript", "lua", "markdown", "json", "kotlin"] {
            #expect(
                RecommendedLanguageCatalog.entry(forLanguage: lang) != nil,
                "Missing catalog entry for \(lang)"
            )
        }
    }

    @Test("objective-c and objective-cpp alias to c (clangd)")
    func objectiveCAliases() {
        for lang in ["objective-c", "objective-cpp"] {
            let entry = RecommendedLanguageCatalog.entry(forLanguage: lang)
            #expect(entry?.aliasOf == "c", "\(lang) should alias to c")
            // Inherits c's deliberately empty recipes (keg-only llvm).
            #expect(entry?.resolvedRecipes.isEmpty == true)
        }
    }

    @Test("scss aliases to css; both install vscode-langservers-extracted")
    func scssAliasesToCSS() {
        let scss = RecommendedLanguageCatalog.entry(forLanguage: "scss")
        #expect(scss?.aliasOf == "css")
        // Same package the JSON entry installs, so one install covers
        // JSON + CSS + SCSS + HTML.
        for lang in ["css", "scss", "html"] {
            let entry = RecommendedLanguageCatalog.entry(forLanguage: lang)
            #expect(entry?.resolvedRecipes.first?.package == "vscode-langservers-extracted",
                    "\(lang) should install vscode-langservers-extracted")
        }
    }

    @Test("brew-core presets name a real formula")
    func brewCorePresets() {
        let expected: [String: String] = [
            "scala": "metals",
            "clojure": "clojure-lsp",
            "zig": "zls",
            "elixir": "elixir-ls",
            "cmake": "cmake-language-server",
            "dart": "dart-sdk",
            "haskell": "haskell-language-server",
        ]
        for (lang, formula) in expected {
            let entry = RecommendedLanguageCatalog.entry(forLanguage: lang)
            #expect(entry != nil, "missing catalog entry for \(lang)")
            let brew = entry?.resolvedRecipes.first(where: { $0.installer == .brew })
            #expect(brew?.package == formula, "\(lang) should brew-install \(formula)")
        }
    }

    @Test("one install's languages are grouped together for reopen")
    func aliasGroupSpansSharedInstalls() {
        // vscode-langservers-extracted ships the JSON, CSS and HTML servers
        // in one package, so installing it from any one of their banners has
        // to revive open tabs in all of them — they are equally un-blocked.
        for entryPoint in ["css", "scss", "html", "json", "jsonc"] {
            let group = Set(RecommendedLanguageCatalog.aliasGroup(forLanguage: entryPoint))
            for expected in ["css", "scss", "html", "json", "jsonc"] {
                #expect(group.contains(expected),
                        "installing from \(entryPoint) should also refresh \(expected)")
            }
        }
    }

    @Test("shared-install grouping does not merge unrelated languages")
    func aliasGroupDoesNotOvermerge() {
        // Languages with no recipes at all (bundled or unprovisionable) must
        // not collapse into one group on the strength of being equally empty.
        let swift = Set(RecommendedLanguageCatalog.aliasGroup(forLanguage: "swift"))
        #expect(swift == ["swift"])

        let c = Set(RecommendedLanguageCatalog.aliasGroup(forLanguage: "c"))
        #expect(c.contains("c") && c.contains("cpp"))
        #expect(c.contains("objective-c") && c.contains("objective-cpp"))
        #expect(!c.contains("swift"))

        // Distinct packages stay distinct.
        let rust = Set(RecommendedLanguageCatalog.aliasGroup(forLanguage: "rust"))
        #expect(rust == ["rust"])
        let scala = Set(RecommendedLanguageCatalog.aliasGroup(forLanguage: "scala"))
        #expect(scala == ["scala"])
    }

    @Test("typescript family still groups as before")
    func typescriptGroupUnchanged() {
        let group = Set(RecommendedLanguageCatalog.aliasGroup(forLanguage: "typescript"))
        #expect(group == ["typescript", "typescriptreact", "javascript", "javascriptreact"])
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

    @Test("kotlin entry installs JetBrains kotlin-lsp with Homebrew")
    func kotlinRecipe() {
        let entry = RecommendedLanguageCatalog.entry(forLanguage: "kotlin")
        #expect(entry?.resolvedRecipes == [
            InstallRecipe(installer: .brew, package: "JetBrains/utils/kotlin-lsp"),
        ])
    }
}
