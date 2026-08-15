import Foundation

struct LanguageServerConfig: Codable, Equatable, Identifiable, Sendable {
    var id: String { language }
    var language: String
    var extensions: [String]
    var command: String
    var args: [String]
    var env: [String: String]
    var rootMarkers: [String]
    var gatekeeperHelpers: [String]
    var gatekeeperRemediationRootMarkers: [String]
    var enabled: Bool

    init(
        language: String,
        extensions: [String],
        command: String,
        args: [String],
        env: [String: String],
        rootMarkers: [String],
        gatekeeperHelpers: [String] = [],
        gatekeeperRemediationRootMarkers: [String] = [],
        enabled: Bool
    ) {
        self.language = language
        self.extensions = extensions
        self.command = command
        self.args = args
        self.env = env
        self.rootMarkers = rootMarkers
        self.gatekeeperHelpers = gatekeeperHelpers
        self.gatekeeperRemediationRootMarkers = gatekeeperRemediationRootMarkers
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case language, extensions, command, args, env, rootMarkers, gatekeeperHelpers, gatekeeperRemediationRootMarkers, enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = try container.decode(String.self, forKey: .language)
        extensions = try container.decode([String].self, forKey: .extensions)
        command = try container.decode(String.self, forKey: .command)
        args = try container.decode([String].self, forKey: .args)
        env = try container.decode([String: String].self, forKey: .env)
        rootMarkers = try container.decode([String].self, forKey: .rootMarkers)
        gatekeeperHelpers = try container.decodeIfPresent([String].self, forKey: .gatekeeperHelpers) ?? []
        gatekeeperRemediationRootMarkers = try container.decodeIfPresent(
            [String].self,
            forKey: .gatekeeperRemediationRootMarkers
        ) ?? []
        enabled = try container.decode(Bool.self, forKey: .enabled)
    }
}

struct LanguageServerRegistry {
    private let userDefined: [LanguageServerConfig]

    // Plain command name; PATH resolves it. We used to xcrun-find sourcekit-lsp
    // here, but that ran Process.waitUntilExit() inside the static initializer,
    // which pumps the main runloop and let SwiftUI re-enter Self.builtIns —
    // libdispatch traps the recursive dispatch_once. Static let initializers
    // must not pump the runloop.
    static let builtIns: [LanguageServerConfig] = [
        LanguageServerConfig(
            language: "swift",
            extensions: ["swift"],
            command: "sourcekit-lsp",
            args: [],
            env: [:],
            rootMarkers: ["Package.swift", "*.xcodeproj", ".git"],
            enabled: true
        ),
        LanguageServerConfig(
            language: "rust",
            extensions: ["rs"],
            command: "rust-analyzer",
            args: [],
            env: [:],
            rootMarkers: ["Cargo.toml", "rust-project.json", ".git"],
            enabled: true
        ),
        // JetBrains kotlin-lsp uses pull-based diagnostics
        // (`textDocument/diagnostic`). The client now supports both push
        // and pull models, so the preset is enabled by default.
        LanguageServerConfig(
            language: "kotlin",
            extensions: ["kt", "kts"],
            command: "kotlin-lsp",
            args: ["--stdio"],
            env: [:],
            rootMarkers: [
                "build.gradle.kts", "build.gradle",
                "settings.gradle.kts", "settings.gradle",
                "pom.xml", ".git"
            ],
            gatekeeperHelpers: ["intellij-server"],
            gatekeeperRemediationRootMarkers: ["product-info.json"],
            enabled: true
        ),
        LanguageServerConfig(
            language: "markdown",
            extensions: ["md", "markdown"],
            command: "marksman",
            args: ["server"],
            env: [:],
            rootMarkers: [".marksman.toml", ".git"],
            enabled: true
        ),
        // typescript-language-server distinguishes typescript /
        // typescriptreact / javascript / javascriptreact in
        // `mode2ScriptKind` and never re-derives the mode from the file
        // extension, so TSX/JSX files opened with `languageId: "typescript"`
        // get parsed as plain TS. Each LSP language ID needs its own
        // registry entry; they all spawn the same binary.
        LanguageServerConfig(
            language: "typescript",
            extensions: ["ts", "mts", "cts"],
            command: "typescript-language-server",
            args: ["--stdio"],
            env: [:],
            rootMarkers: ["tsconfig.json", "jsconfig.json", "package.json", ".git"],
            enabled: true
        ),
        LanguageServerConfig(
            language: "typescriptreact",
            extensions: ["tsx"],
            command: "typescript-language-server",
            args: ["--stdio"],
            env: [:],
            rootMarkers: ["tsconfig.json", "jsconfig.json", "package.json", ".git"],
            enabled: true
        ),
        LanguageServerConfig(
            language: "javascript",
            extensions: ["js", "mjs", "cjs"],
            command: "typescript-language-server",
            args: ["--stdio"],
            env: [:],
            rootMarkers: ["tsconfig.json", "jsconfig.json", "package.json", ".git"],
            enabled: true
        ),
        LanguageServerConfig(
            language: "javascriptreact",
            extensions: ["jsx"],
            command: "typescript-language-server",
            args: ["--stdio"],
            env: [:],
            rootMarkers: ["tsconfig.json", "jsconfig.json", "package.json", ".git"],
            enabled: true
        ),
        LanguageServerConfig(
            language: "json",
            extensions: ["json"],
            command: "vscode-json-language-server",
            args: ["--stdio"],
            env: [:],
            rootMarkers: ["package.json", ".git"],
            enabled: true
        ),
        // vscode-json-languageserver only allows comments when the document
        // languageId is "jsonc"; opening a .jsonc as "json" gets the strict
        // parser and bogus diagnostics on every comment.
        LanguageServerConfig(
            language: "jsonc",
            extensions: ["jsonc"],
            command: "vscode-json-language-server",
            args: ["--stdio"],
            env: [:],
            rootMarkers: ["package.json", ".git"],
            enabled: true
        ),
        LanguageServerConfig(
            language: "python",
            extensions: ["py", "pyi"],
            command: "pyright-langserver",
            args: ["--stdio"],
            env: [:],
            rootMarkers: ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", ".git"],
            enabled: true
        ),
        LanguageServerConfig(
            language: "shellscript",
            extensions: ["sh", "bash", "zsh"],
            command: "bash-language-server",
            args: ["start"],
            env: [:],
            rootMarkers: [".git"],
            enabled: true
        ),
        LanguageServerConfig(
            language: "go",
            extensions: ["go"],
            command: "gopls",
            args: [],
            env: [:],
            rootMarkers: ["go.mod", "go.sum", ".git"],
            enabled: true
        ),
        LanguageServerConfig(
            language: "c",
            extensions: ["c", "h"],
            command: "clangd",
            args: [],
            env: [:],
            rootMarkers: ["compile_commands.json", "CMakeLists.txt", "Makefile", ".git"],
            enabled: true
        ),
        LanguageServerConfig(
            language: "cpp",
            extensions: ["cc", "cpp", "cxx", "hh", "hpp", "hxx"],
            command: "clangd",
            args: [],
            env: [:],
            rootMarkers: ["compile_commands.json", "CMakeLists.txt", "Makefile", ".git"],
            enabled: true
        ),
        LanguageServerConfig(
            language: "ruby",
            extensions: ["rb"],
            command: "ruby-lsp",
            args: [],
            env: [:],
            rootMarkers: ["Gemfile", ".ruby-version", ".git"],
            enabled: true
        ),
        LanguageServerConfig(
            language: "lua",
            extensions: ["lua"],
            command: "lua-language-server",
            args: [],
            env: [:],
            rootMarkers: [".luarc.json", ".luarc.jsonc", "stylua.toml", ".git"],
            enabled: true
        ),
        // clangd already ships with the Xcode command line tools and is
        // already the C/C++ preset, so Objective-C costs no new dependency.
        // The LSP spec's IDs are `objective-c` / `objective-cpp`; clangd
        // switches dialect on them, so `.mm` must not be folded into the
        // `objective-c` entry.
        LanguageServerConfig(
            language: "objective-c",
            extensions: ["m"],
            command: "clangd",
            args: [],
            env: [:],
            rootMarkers: ["compile_commands.json", "CMakeLists.txt", "Makefile", ".git"],
            enabled: true
        ),
        LanguageServerConfig(
            language: "objective-cpp",
            extensions: ["mm"],
            command: "clangd",
            args: [],
            env: [:],
            rootMarkers: ["compile_commands.json", "CMakeLists.txt", "Makefile", ".git"],
            enabled: true
        ),
        // CSS/SCSS/HTML all come from vscode-langservers-extracted, which is
        // already the recommended install for the JSON preset above — so for
        // anyone who took that nudge these light up with nothing further to
        // install. The CSS server handles both dialects but keys off the
        // document's languageId, so `scss` needs its own entry rather than
        // being an extension on the `css` one.
        LanguageServerConfig(
            language: "css",
            extensions: ["css"],
            command: "vscode-css-language-server",
            args: ["--stdio"],
            env: [:],
            rootMarkers: ["package.json", ".git"],
            enabled: true
        ),
        LanguageServerConfig(
            language: "scss",
            extensions: ["scss"],
            command: "vscode-css-language-server",
            args: ["--stdio"],
            env: [:],
            rootMarkers: ["package.json", ".git"],
            enabled: true
        ),
        LanguageServerConfig(
            language: "html",
            extensions: ["html", "htm"],
            command: "vscode-html-language-server",
            args: ["--stdio"],
            env: [:],
            rootMarkers: ["package.json", ".git"],
            enabled: true
        ),
        LanguageServerConfig(
            language: "scala",
            extensions: ["scala", "sbt", "sc"],
            command: "metals",
            args: [],
            env: [:],
            rootMarkers: ["build.sbt", "build.sc", "build.gradle", "pom.xml", ".git"],
            enabled: true
        ),
        LanguageServerConfig(
            language: "clojure",
            extensions: ["clj", "cljs", "cljc", "edn"],
            command: "clojure-lsp",
            args: [],
            env: [:],
            rootMarkers: ["deps.edn", "project.clj", "shadow-cljs.edn", "bb.edn", ".git"],
            enabled: true
        ),
        LanguageServerConfig(
            language: "zig",
            extensions: ["zig"],
            command: "zls",
            args: [],
            env: [:],
            rootMarkers: ["build.zig", "build.zig.zon", ".git"],
            enabled: true
        ),
        LanguageServerConfig(
            language: "elixir",
            extensions: ["ex", "exs"],
            command: "elixir-ls",
            args: [],
            env: [:],
            rootMarkers: ["mix.exs", ".git"],
            enabled: true
        ),
        LanguageServerConfig(
            language: "cmake",
            extensions: ["cmake"],
            command: "cmake-language-server",
            args: [],
            env: [:],
            rootMarkers: ["CMakeLists.txt", ".git"],
            enabled: true
        ),
        // The LSP is a subcommand of the Dart SDK's own driver rather than a
        // standalone binary, and it speaks the legacy analysis-server
        // protocol unless `--protocol=lsp` is passed.
        LanguageServerConfig(
            language: "dart",
            extensions: ["dart"],
            command: "dart",
            args: ["language-server", "--protocol=lsp"],
            env: [:],
            rootMarkers: ["pubspec.yaml", ".git"],
            enabled: true
        ),
        // `haskell-language-server-wrapper`, not `haskell-language-server`:
        // Homebrew ships only GHC-version-suffixed binaries
        // (`haskell-language-server-9.12`, `-9.14`, …) plus this wrapper,
        // which picks the one matching the project's GHC. There is no
        // unsuffixed binary, so the obvious command name would resolve to
        // nothing and report "not installed" forever.
        LanguageServerConfig(
            language: "haskell",
            extensions: ["hs", "lhs"],
            command: "haskell-language-server-wrapper",
            args: ["--lsp"],
            env: [:],
            rootMarkers: ["*.cabal", "stack.yaml", "cabal.project", "package.yaml", ".git"],
            enabled: true
        )
    ]

    init(userDefined: [LanguageServerConfig]) {
        self.userDefined = userDefined
    }

    func entry(forLanguage language: String) -> LanguageServerConfig? {
        let merged = mergedEntries
        return merged.first(where: { $0.language == language && $0.enabled })
    }

    /// Files whose *name* identifies the language, because their extension
    /// either doesn't exist or actively misleads. `CMakeLists.txt` is the
    /// motivating case: its `pathExtension` is `txt`, so extension-only
    /// lookup would never reach the `cmake` server for the one file every
    /// CMake project is guaranteed to have.
    ///
    /// Values are extension keys, not language IDs, so a filename resolves
    /// through exactly the same table as a normal extension.
    /// `LanguageRegistry.extensionsByFilename` is the highlighting side's
    /// equivalent; this one is deliberately narrower — it lists only
    /// filenames whose language has a built-in server.
    private static let extensionsByFilename: [String: String] = [
        "cmakelists.txt": "cmake"
    ]

    /// The extension key to look a path up by. Identical to `pathExtension`
    /// apart from the filenames above, so it is a safe drop-in wherever a
    /// path was previously reduced with `pathExtension`.
    static func extensionKey(forPath path: String) -> String {
        let filename = (path as NSString).lastPathComponent.lowercased()
        if let mapped = extensionsByFilename[filename] { return mapped }
        return (path as NSString).pathExtension.lowercased()
    }

    /// Language for `path`, honouring filename-identified files. Prefer this
    /// over `language(forFileExtension:)` whenever a full path is in hand.
    func language(forPath path: String) -> String? {
        language(forFileExtension: Self.extensionKey(forPath: path))
    }

    func language(forFileExtension ext: String) -> String? {
        let lower = ext.lowercased()
        // Skip disabled entries so a stale disabled config can't mask an
        // enabled one that claims the same extension. The Code pane has a
        // toggle but no delete action, so disabled entries can stick around.
        return mergedEntries.first(where: { $0.enabled && $0.extensions.contains(lower) })?.language
    }

    func allEntries() -> [LanguageServerConfig] { mergedEntries }

    func disabledUserDefinedEntryClaims(fileExtension ext: String) -> Bool {
        let lower = ext.lowercased()
        return userDefined.contains { entry in
            !entry.enabled && entry.extensions.contains(lower)
        }
    }

    private var mergedEntries: [LanguageServerConfig] {
        var byLang: [String: LanguageServerConfig] = [:]
        for b in Self.builtIns { byLang[b.language] = b }
        for u in userDefined { byLang[u.language] = u }
        return Array(byLang.values).sorted { $0.language < $1.language }
    }
}
