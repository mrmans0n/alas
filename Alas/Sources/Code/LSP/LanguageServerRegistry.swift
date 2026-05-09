import Foundation

struct LanguageServerConfig: Codable, Equatable, Identifiable, Sendable {
    var id: String { language }
    var language: String
    var extensions: [String]
    var command: String
    var args: [String]
    var env: [String: String]
    var rootMarkers: [String]
    var enabled: Bool
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
        LanguageServerConfig(
            language: "typescript",
            extensions: ["ts", "tsx", "js", "jsx", "mjs", "cjs"],
            command: "typescript-language-server",
            args: ["--stdio"],
            env: [:],
            rootMarkers: ["tsconfig.json", "jsconfig.json", "package.json", ".git"],
            enabled: true
        ),
        LanguageServerConfig(
            language: "json",
            extensions: ["json", "jsonc"],
            command: "vscode-json-languageserver",
            args: ["--stdio"],
            env: [:],
            rootMarkers: ["package.json", ".git"],
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

    func language(forFileExtension ext: String) -> String? {
        let lower = ext.lowercased()
        // Skip disabled entries so a stale disabled config can't mask an
        // enabled one that claims the same extension. The Code pane has a
        // toggle but no delete action, so disabled entries can stick around.
        return mergedEntries.first(where: { $0.enabled && $0.extensions.contains(lower) })?.language
    }

    func allEntries() -> [LanguageServerConfig] { mergedEntries }

    private var mergedEntries: [LanguageServerConfig] {
        var byLang: [String: LanguageServerConfig] = [:]
        for b in Self.builtIns { byLang[b.language] = b }
        for u in userDefined { byLang[u.language] = u }
        return Array(byLang.values).sorted { $0.language < $1.language }
    }
}
