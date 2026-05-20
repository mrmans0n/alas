import Foundation

extension LanguageServerConfig {
    static func prefilled(from package: MasonPackage) -> LanguageServerConfig {
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

    func normalizedForSettingsSave() -> LanguageServerConfig {
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
    mutating func saveLanguageServerConfig(
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

        if let recipes, !recipes.isEmpty {
            userDefinedRecipes[entry.language] = recipes
        } else if let original = originalLanguage, original != entry.language {
            if let existing = userDefinedRecipes.removeValue(forKey: original) {
                userDefinedRecipes[entry.language] = existing
            }
        }
    }
}
