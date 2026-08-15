import Foundation

struct InstallNudgeOption: Identifiable {
    let package: MasonPackage
    let language: String
    let displayName: String
    let command: String
    let available: [(installer: DetectedInstaller, recipe: InstallRecipe)]

    var id: String { package.masonId }
}

struct InstallNudgeData {
    let language: String
    let displayName: String
    let command: String
    let available: [(installer: DetectedInstaller, recipe: InstallRecipe)]
    let dismissalKey: String
    let masonPackage: MasonPackage?
    let masonOptions: [InstallNudgeOption]

    func selectingMasonOption(id: String?) -> InstallNudgeData {
        guard let id,
              let option = masonOptions.first(where: { $0.id == id }) else {
            return self
        }
        return InstallNudgeData(
            language: option.language,
            displayName: option.displayName,
            command: option.command,
            available: option.available,
            dismissalKey: dismissalKey,
            masonPackage: option.package,
            masonOptions: masonOptions
        )
    }
}

@MainActor
struct InstallNudgeResolver {
    let registry: LanguageServerRegistry
    let userDefinedRecipes: [String: [InstallRecipe]]
    let dismissedInstallNudges: [String]
    let installerHost: InstallerHost
    let masonSnapshot: MasonSnapshot
    let availabilityStatus: (LanguageServerConfig) -> LanguageServerAvailability.Status

    init(
        registry: LanguageServerRegistry,
        userDefinedRecipes: [String: [InstallRecipe]],
        dismissedInstallNudges: [String],
        installerHost: InstallerHost,
        masonSnapshot: MasonSnapshot = .shared,
        availabilityStatus: @escaping (LanguageServerConfig) -> LanguageServerAvailability.Status = {
            LanguageServerAvailability().status(for: $0)
        }
    ) {
        self.registry = registry
        self.userDefinedRecipes = userDefinedRecipes
        self.dismissedInstallNudges = dismissedInstallNudges
        self.installerHost = installerHost
        self.masonSnapshot = masonSnapshot
        self.availabilityStatus = availabilityStatus
    }

    func nudgeData(forAbsolutePath absolutePath: String) -> InstallNudgeData? {
        let ext = LanguageServerRegistry.extensionKey(forPath: absolutePath)
        guard !ext.isEmpty else { return nil }

        if registry.language(forFileExtension: ext) != nil {
            return registryNudge(forExtension: ext)
        }

        return masonNudge(forExtension: ext)
    }

    private func registryNudge(forExtension ext: String) -> InstallNudgeData? {
        guard let language = registry.language(forFileExtension: ext) else { return nil }
        guard let entry = registry.allEntries().first(where: { $0.language == language }) else { return nil }
        guard availabilityStatus(entry) == .notInstalled else { return nil }

        let recipes = recipes(for: language)
        guard !recipes.isEmpty else { return nil }

        let available = installerHost.allAvailable(in: recipes)
        guard !available.isEmpty else { return nil }
        guard !dismissedInstallNudges.contains(language) else { return nil }

        let displayName = RecommendedLanguageCatalog.entry(forLanguage: language)?.displayName ?? language
        return InstallNudgeData(
            language: language,
            displayName: displayName,
            command: entry.command,
            available: available,
            dismissalKey: language,
            masonPackage: nil,
            masonOptions: []
        )
    }

    private func masonNudge(forExtension ext: String) -> InstallNudgeData? {
        let dismissalKey = "extension:\(ext)"
        guard !dismissedInstallNudges.contains(dismissalKey) else { return nil }
        guard !registry.disabledUserDefinedEntryClaims(fileExtension: ext) else { return nil }

        var options: [InstallNudgeOption] = []
        var seenPackageIds = Set<String>()
        options.reserveCapacity(MasonSnapshot.maxResults)
        for package in masonSnapshot.packages(forFileExtension: ext) {
            guard !package.recipes.isEmpty else { continue }
            let available = installerHost.allAvailable(in: package.recipes)
            guard !available.isEmpty else { continue }
            let config = LanguageServerConfig.prefilled(from: package)
            guard availabilityStatus(config) == .notInstalled else { continue }
            guard seenPackageIds.insert(package.masonId).inserted else { continue }
            options.append(InstallNudgeOption(
                package: package,
                language: config.language,
                displayName: package.displayName,
                command: config.command,
                available: available
            ))
            if options.count >= MasonSnapshot.maxResults { break }
        }
        guard let selected = options.first else { return nil }

        return InstallNudgeData(
            language: selected.language,
            displayName: selected.displayName,
            command: selected.command,
            available: selected.available,
            dismissalKey: dismissalKey,
            masonPackage: selected.package,
            masonOptions: options
        )
    }

    private func recipes(for language: String) -> [InstallRecipe] {
        if let user = userDefinedRecipes[language], !user.isEmpty {
            return user
        }
        if let curated = RecommendedLanguageCatalog.entry(forLanguage: language) {
            return curated.resolvedRecipes
        }
        return []
    }
}
