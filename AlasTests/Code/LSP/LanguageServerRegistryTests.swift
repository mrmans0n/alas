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
        #expect(r.language(forFileExtension: "kt") == nil)
        #expect(r.language(forFileExtension: "md") == "markdown")
        #expect(r.language(forFileExtension: "ts") == "typescript")
        #expect(r.language(forFileExtension: "mts") == "typescript")
        #expect(r.language(forFileExtension: "cts") == "typescript")
        #expect(r.language(forFileExtension: "tsx") == "typescriptreact")
        #expect(r.language(forFileExtension: "js") == "javascript")
        #expect(r.language(forFileExtension: "jsx") == "javascriptreact")
        #expect(r.language(forFileExtension: "json") == "json")
        #expect(r.language(forFileExtension: "jsonc") == "jsonc")
        #expect(r.language(forFileExtension: "xyz") == nil)
    }
}
