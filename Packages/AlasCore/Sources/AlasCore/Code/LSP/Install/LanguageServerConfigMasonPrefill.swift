import Foundation

extension LanguageServerConfig {
    public static func prefilled(from package: MasonPackage) -> LanguageServerConfig {
        let language = package.languageId.isEmpty ? package.masonId.lowercased() : package.languageId
        return LanguageServerConfig(
            language: language,
            extensions: package.extensions,
            command: package.command,
            args: package.args,
            env: [:],
            rootMarkers: [".git"],
            enabled: true
        )
    }

    public func normalizedForSettingsSave() -> LanguageServerConfig {
        var normalized = self
        normalized.language = language.trimmingCharacters(in: .whitespaces)
        normalized.command = command.trimmingCharacters(in: .whitespaces)
        normalized.args = args
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        normalized.rootMarkers = rootMarkers
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return normalized
    }
}

extension AppConfig.Code {
    public mutating func saveLanguageServerConfig(
        originalLanguage: String?,
        _ entry: LanguageServerConfig,
        recipes: [InstallRecipe]?
    ) {
        let entry = entry.normalizedForSettingsSave()
        var list = languageServers
        let lookupKey = originalLanguage ?? entry.language
        if let i = list.firstIndex(where: { $0.language == lookupKey }) {
            list[i] = entry
        } else {
            list.append(entry)
        }
        languageServers = list

        if let original = originalLanguage, original != entry.language {
            let override = inlayHintsByLanguage.removeValue(forKey: original)
            inlayHintsByLanguage[entry.language] = override
        }

        if let recipes, !recipes.isEmpty {
            userDefinedRecipes[entry.language] = recipes
        } else if let original = originalLanguage, original != entry.language {
            if let existing = userDefinedRecipes.removeValue(forKey: original) {
                userDefinedRecipes[entry.language] = existing
            }
        }
    }
}

extension AppConfig.Code {
    /// YAML used to have no built-in server, so its files went through the
    /// Mason install nudge, which ranked gh-actions-language-server first.
    /// Accepting it persisted a user `yaml` server whose command its
    /// `@actions/languageserver` package never provides, and dismissing it
    /// persisted an `extension:` key the built-in nudge doesn't read.
    public mutating func migrateLegacyYAMLNudgeState() {
        let legacyServer = LanguageServerConfig(
            language: "yaml",
            extensions: ["yaml", "yml"],
            command: "gh-actions-language-server",
            args: ["--stdio"],
            env: [:],
            rootMarkers: [".git"],
            enabled: true
        )
        let legacyRecipes = [InstallRecipe(installer: .npm, package: "@actions/languageserver")]
        // Only the untouched nudge entry is removed: a user who disabled or
        // edited it made a choice the built-in must not silently override.
        if userDefinedRecipes["yaml"] == legacyRecipes,
           let index = languageServers.firstIndex(of: legacyServer) {
            languageServers.remove(at: index)
            userDefinedRecipes["yaml"] = nil
        }

        if !dismissedInstallNudges.contains("yaml"),
           dismissedInstallNudges.contains(where: { $0 == "extension:yaml" || $0 == "extension:yml" }) {
            dismissedInstallNudges.append("yaml")
        }
    }
}
