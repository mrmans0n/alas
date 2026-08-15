import Foundation

/// Payload for a "this LSP is blocked by macOS Gatekeeper" banner.
struct BlockedNudgeData: Equatable {
    let language: String
    let displayName: String
    let command: String
    let realPath: String

    var dismissalKey: String { "blocked:\(realPath)" }
}

/// Resolves a file path to a `BlockedNudgeData` payload when the matching
/// LSP entry's binary is blocked by Gatekeeper and the user hasn't dismissed
/// the banner for that exact `realPath` yet.
///
/// Parallels `InstallNudgeResolver` — both feed the same banner host in
/// `EditorTabView` and read the same `dismissedInstallNudges` store; we
/// just namespace our keys with `blocked:` so they don't collide with the
/// install resolver's language-keyed entries.
@MainActor
struct BlockedLanguageServerNudgeResolver {
    let registry: LanguageServerRegistry
    let dismissedKeys: [String]
    let availabilityStatus: (LanguageServerConfig) -> LanguageServerAvailability.Status

    init(
        registry: LanguageServerRegistry,
        dismissedKeys: [String],
        availabilityStatus: @escaping (LanguageServerConfig) -> LanguageServerAvailability.Status = {
            LanguageServerAvailability().status(for: $0)
        }
    ) {
        self.registry = registry
        self.dismissedKeys = dismissedKeys
        self.availabilityStatus = availabilityStatus
    }

    func nudgeData(forAbsolutePath absolutePath: String) -> BlockedNudgeData? {
        let ext = LanguageServerRegistry.extensionKey(forPath: absolutePath)
        guard !ext.isEmpty else { return nil }
        guard let language = registry.language(forFileExtension: ext) else { return nil }
        guard let entry = registry.allEntries().first(where: { $0.language == language }) else { return nil }

        guard case .blockedByGatekeeper(let realPath) = availabilityStatus(entry) else { return nil }

        let key = "blocked:\(realPath)"
        guard !dismissedKeys.contains(key) else { return nil }

        let displayName = RecommendedLanguageCatalog.entry(forLanguage: language)?.displayName ?? language
        return BlockedNudgeData(
            language: language,
            displayName: displayName,
            command: entry.command,
            realPath: realPath
        )
    }
}
