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

    static let builtIns: [LanguageServerConfig] = [
        LanguageServerConfig(
            language: "swift",
            extensions: ["swift"],
            command: resolveSwiftCommand(),
            args: [],
            env: [:],
            rootMarkers: ["Package.swift", "*.xcodeproj", ".git"],
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
        return mergedEntries.first(where: { $0.extensions.contains(lower) })?.language
    }

    func allEntries() -> [LanguageServerConfig] { mergedEntries }

    private var mergedEntries: [LanguageServerConfig] {
        var byLang: [String: LanguageServerConfig] = [:]
        for b in Self.builtIns { byLang[b.language] = b }
        for u in userDefined { byLang[u.language] = u }
        return Array(byLang.values).sorted { $0.language < $1.language }
    }

    private static func resolveSwiftCommand() -> String {
        // Best-effort xcrun lookup; falls back to plain command name so PATH wins.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["--find", "sourcekit-lsp"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return s.isEmpty ? "sourcekit-lsp" : s
        } catch {
            return "sourcekit-lsp"
        }
    }
}
