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

    @Test("Kotlin built-in records intellij-server helper")
    func kotlinGatekeeperHelper() {
        let entry = LanguageServerRegistry.builtIns.first(where: { $0.language == "kotlin" })
        #expect(entry?.command == "kotlin-lsp")
        #expect(entry?.args == ["--stdio"])
        #expect(entry?.gatekeeperHelpers == ["intellij-server"])
    }

    @Test("LanguageServerConfig decodes legacy JSON without gatekeeper helpers")
    func legacyConfigDecodeDefaultsGatekeeperHelpers() throws {
        let json = """
        {
          "language": "kotlin",
          "extensions": ["kt", "kts"],
          "command": "kotlin-lsp",
          "args": ["--stdio"],
          "env": {},
          "rootMarkers": [".git"],
          "enabled": true
        }
        """

        let decoded = try JSONDecoder().decode(LanguageServerConfig.self, from: Data(json.utf8))

        #expect(decoded.language == "kotlin")
        #expect(decoded.gatekeeperHelpers == [])
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

    @Test("Objective-C built-ins reuse clangd with distinct language IDs")
    func objectiveCBuiltIns() {
        let m = LanguageServerRegistry.builtIns.first(where: { $0.language == "objective-c" })
        let mm = LanguageServerRegistry.builtIns.first(where: { $0.language == "objective-cpp" })
        #expect(m?.command == "clangd")
        #expect(mm?.command == "clangd")
        // clangd picks its dialect from the languageId, so `.mm` must not be
        // folded into the objective-c entry.
        #expect(m?.extensions == ["m"])
        #expect(mm?.extensions == ["mm"])
    }

    @Test("css, scss and html built-ins use the vscode-langservers binaries")
    func webBuiltIns() {
        let css = LanguageServerRegistry.builtIns.first(where: { $0.language == "css" })
        let scss = LanguageServerRegistry.builtIns.first(where: { $0.language == "scss" })
        let html = LanguageServerRegistry.builtIns.first(where: { $0.language == "html" })
        #expect(css?.command == "vscode-css-language-server")
        // One server, two languageIds: it keys off the document's languageId
        // rather than re-deriving the dialect from the extension.
        #expect(scss?.command == "vscode-css-language-server")
        #expect(html?.command == "vscode-html-language-server")
        for entry in [css, scss, html] {
            #expect(entry?.args == ["--stdio"])
        }
    }

    @Test("haskell built-in uses the wrapper binary, not the bare name")
    func haskellUsesWrapper() {
        let entry = LanguageServerRegistry.builtIns.first(where: { $0.language == "haskell" })
        // Homebrew ships only GHC-version-suffixed binaries plus this
        // wrapper — there is no plain `haskell-language-server` on PATH, so
        // the obvious name would report "not installed" forever.
        #expect(entry?.command == "haskell-language-server-wrapper")
        #expect(entry?.args == ["--lsp"])
    }

    @Test("dart built-in selects the LSP protocol explicitly")
    func dartBuiltIn() {
        let entry = LanguageServerRegistry.builtIns.first(where: { $0.language == "dart" })
        // The server is an SDK subcommand and speaks the legacy analysis
        // protocol without `--protocol=lsp`.
        #expect(entry?.command == "dart")
        #expect(entry?.args == ["language-server", "--protocol=lsp"])
    }

    @Test("new presets are reachable by extension")
    func newPresetsByExtension() {
        let r = LanguageServerRegistry(userDefined: [])
        let expected: [String: String] = [
            "m": "objective-c",
            "mm": "objective-cpp",
            "css": "css",
            "scss": "scss",
            "html": "html",
            "htm": "html",
            "scala": "scala",
            "sbt": "scala",
            "clj": "clojure",
            "edn": "clojure",
            "zig": "zig",
            "ex": "elixir",
            "exs": "elixir",
            "cmake": "cmake",
            "dart": "dart",
            "hs": "haskell",
            "lhs": "haskell",
        ]
        for (ext, language) in expected {
            #expect(r.language(forFileExtension: ext) == language,
                    "\(ext) should resolve to \(language)")
        }
    }

    @Test("CMakeLists.txt resolves to cmake despite its .txt extension")
    func cmakeListsResolvesByFilename() {
        let r = LanguageServerRegistry(userDefined: [])
        // The one file every CMake project has; extension-only lookup sees
        // "txt" and would never reach the cmake server.
        #expect(r.language(forPath: "/repo/CMakeLists.txt") == "cmake")
        #expect(r.language(forPath: "/repo/nested/CMakeLists.txt") == "cmake")
        #expect(LanguageServerRegistry.extensionKey(forPath: "/repo/CMakeLists.txt") == "cmake")
        // Case-insensitive, like every other lookup here.
        #expect(r.language(forPath: "/repo/cmakelists.txt") == "cmake")
    }

    @Test("extensionKey is a drop-in for pathExtension elsewhere")
    func extensionKeyMatchesPathExtension() {
        // Everything that is not a filename special case must behave exactly
        // as the `pathExtension` it replaced, or migrating the call sites
        // would have changed unrelated languages.
        for path in ["/a/b/App.swift", "/a/b/main.rs", "/a/b/notes.txt",
                     "/a/b/script.PY", "/a/b/no-extension", "/a/CMakeLists.txt.bak"] {
            let expected = (path as NSString).pathExtension.lowercased()
            #expect(LanguageServerRegistry.extensionKey(forPath: path) == expected,
                    "\(path) should reduce to \(expected)")
        }
    }

    @Test("a plain .txt file still resolves to no language")
    func plainTextStillUnmapped() {
        let r = LanguageServerRegistry(userDefined: [])
        // Guards against the filename table swallowing every .txt file.
        #expect(r.language(forPath: "/repo/notes.txt") == nil)
        #expect(r.language(forPath: "/repo/CMakeLists.txt.bak") == nil)
    }

    @MainActor
    @Test("DocumentFormatter's default routes filenames through the key")
    func documentFormatterDefaultResolvesFilenames() {
        // External tabs and formatAndSave reach the registry through this
        // protocol, and conformances implement only the extension-based
        // requirement — so the default has to do the filename normalisation
        // or those paths silently regress to a nil language.
        let formatter = RegistryBackedFormatter()
        #expect(formatter.language(forPath: "/repo/CMakeLists.txt") == "cmake")
        #expect(formatter.language(forPath: "/repo/App.swift") == "swift")
        #expect(formatter.language(forPath: "/repo/notes.txt") == nil)
    }

    @Test("no two built-ins claim the same extension")
    func builtInExtensionsAreDisjoint() {
        var owner: [String: String] = [:]
        for entry in LanguageServerRegistry.builtIns {
            for ext in entry.extensions {
                #expect(owner[ext] == nil,
                        "extension '\(ext)' claimed by both \(owner[ext] ?? "?") and \(entry.language)")
                owner[ext] = entry.language
            }
        }
    }
}

/// Implements only the extension-based requirement, exactly as the real
/// conformances and test fakes do, so `language(forPath:)` exercises the
/// protocol's default implementation rather than a bespoke override.
@MainActor
private final class RegistryBackedFormatter: DocumentFormatter, @unchecked Sendable {
    private let registry = LanguageServerRegistry(userDefined: [])

    func language(forFileExtension ext: String) -> String? {
        registry.language(forFileExtension: ext)
    }

    func formatting(for fileURL: URL, languageId: String, options: LSPFormattingOptions) async -> [LSPTextEdit]? {
        nil
    }

    func didChange(worktreeRoot: URL, fileURL: URL, languageId: String, text: String, edits: [EditorTextEdit]?) async {}
}
