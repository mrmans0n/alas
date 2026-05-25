import Foundation
import Testing
@testable import Alas

@Suite("LanguageServerRegistry")
struct LanguageServerRegistryTests {
    @Test("built-in Swift entry exists")
    func swift() {
        let r = LanguageServerRegistry(userDefined: [])
        let entry = r.entry(forLanguage: "swift")
        #expect(entry != nil)
        #expect(entry?.extensions.contains("swift") == true)
    }

    @Test("user entry overrides built-in for same language")
    func userOverride() {
        let custom = LanguageServerConfig(
            language: "swift", extensions: ["swift"],
            command: "/custom/sourcekit-lsp", args: ["--debug"], env: [:],
            rootMarkers: ["Package.swift"], enabled: true
        )
        let r = LanguageServerRegistry(userDefined: [custom])
        let entry = r.entry(forLanguage: "swift")
        #expect(entry?.command == "/custom/sourcekit-lsp")
        #expect(entry?.args == ["--debug"])
    }

    @Test("disabled entry returns nil")
    func disabled() {
        let custom = LanguageServerConfig(
            language: "swift", extensions: ["swift"],
            command: "x", args: [], env: [:],
            rootMarkers: [], enabled: false
        )
        let r = LanguageServerRegistry(userDefined: [custom])
        #expect(r.entry(forLanguage: "swift") == nil)
    }

    @Test("language inferred from extension")
    func byExtension() {
        let r = LanguageServerRegistry(userDefined: [])
        #expect(r.language(forFileExtension: "swift") == "swift")
        #expect(r.language(forFileExtension: "rs") == "rust")
        #expect(r.language(forFileExtension: "kt") == "kotlin")
        #expect(r.language(forFileExtension: "md") == "markdown")
        #expect(r.language(forFileExtension: "ts") == "typescript")
        #expect(r.language(forFileExtension: "mts") == "typescript")
        #expect(r.language(forFileExtension: "cts") == "typescript")
        #expect(r.language(forFileExtension: "tsx") == "typescriptreact")
        #expect(r.language(forFileExtension: "js") == "javascript")
        #expect(r.language(forFileExtension: "jsx") == "javascriptreact")
        #expect(r.language(forFileExtension: "json") == "json")
        #expect(r.language(forFileExtension: "jsonc") == "jsonc")
        #expect(r.language(forFileExtension: "py") == "python")
        #expect(r.language(forFileExtension: "pyi") == "python")
        #expect(r.language(forFileExtension: "sh") == "shellscript")
        #expect(r.language(forFileExtension: "bash") == "shellscript")
        #expect(r.language(forFileExtension: "zsh") == "shellscript")
        #expect(r.language(forFileExtension: "xyz") == nil)
    }

    @Test("built-in Python entry exists")
    func python() {
        let r = LanguageServerRegistry(userDefined: [])
        let entry = r.entry(forLanguage: "python")
        #expect(entry != nil)
        #expect(entry?.command == "pyright-langserver")
        #expect(entry?.args == ["--stdio"])
        #expect(entry?.extensions == ["py", "pyi"])
    }

    @Test("built-in Shell entry exists")
    func shellscript() {
        let r = LanguageServerRegistry(userDefined: [])
        let entry = r.entry(forLanguage: "shellscript")
        #expect(entry != nil)
        #expect(entry?.command == "bash-language-server")
        #expect(entry?.args == ["start"])
        #expect(entry?.extensions == ["sh", "bash", "zsh"])
    }

    @Test("go built-in uses gopls")
    func goBuiltIn() {
        let entry = LanguageServerRegistry.builtIns.first(where: { $0.language == "go" })
        #expect(entry?.command == "gopls")
        #expect(entry?.extensions == ["go"])
    }

    @Test("c and cpp built-ins both use clangd")
    func cAndCppBuiltIns() {
        let c = LanguageServerRegistry.builtIns.first(where: { $0.language == "c" })
        let cpp = LanguageServerRegistry.builtIns.first(where: { $0.language == "cpp" })
        #expect(c?.command == "clangd")
        #expect(cpp?.command == "clangd")
        #expect(c?.extensions == ["c", "h"])
        #expect(cpp?.extensions == ["cc", "cpp", "cxx", "hh", "hpp", "hxx"])
    }

    @Test("ruby built-in uses ruby-lsp")
    func rubyBuiltIn() {
        let entry = LanguageServerRegistry.builtIns.first(where: { $0.language == "ruby" })
        #expect(entry?.command == "ruby-lsp")
        #expect(entry?.extensions == ["rb"])
    }

    @Test("lua built-in uses lua-language-server")
    func luaBuiltIn() {
        let entry = LanguageServerRegistry.builtIns.first(where: { $0.language == "lua" })
        #expect(entry?.command == "lua-language-server")
        #expect(entry?.extensions == ["lua"])
    }
}
