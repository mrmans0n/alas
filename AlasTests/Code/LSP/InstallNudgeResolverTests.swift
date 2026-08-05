import Foundation
import Testing
@testable import Alas

@Suite("InstallNudgeResolver")
@MainActor
struct InstallNudgeResolverTests {
    @Test("unknown extension resolves to installable Mason package")
    func masonFallbackForUnknownExtension() {
        let resolver = InstallNudgeResolver(
            registry: LanguageServerRegistry(userDefined: []),
            userDefinedRecipes: [:],
            dismissedInstallNudges: [],
            installerHost: InstallerHost(detected: [.brew: DetectedInstaller(kind: .brew, executable: "/opt/homebrew/bin/brew")]),
            masonSnapshot: MasonSnapshot(packages: [
                package(id: "taplo", languageId: "toml", extensions: ["toml"], command: "taplo")
            ]),
            availabilityStatus: { _ in .notInstalled }
        )

        let nudge = resolver.nudgeData(forAbsolutePath: "/tmp/Config.toml")

        #expect(nudge?.language == "toml")
        #expect(nudge?.displayName == "taplo")
        #expect(nudge?.command == "taplo")
        #expect(nudge?.dismissalKey == "extension:toml")
        #expect(nudge?.masonPackage?.masonId == "taplo")
        #expect(nudge?.available.map(\.recipe.package) == ["taplo"])
    }

    @Test("Mason fallback skips dismissed extension key")
    func masonFallbackDismissedByExtension() {
        let resolver = InstallNudgeResolver(
            registry: LanguageServerRegistry(userDefined: []),
            userDefinedRecipes: [:],
            dismissedInstallNudges: ["extension:toml"],
            installerHost: InstallerHost(detected: [.brew: DetectedInstaller(kind: .brew, executable: "/opt/homebrew/bin/brew")]),
            masonSnapshot: MasonSnapshot(packages: [
                package(id: "taplo", languageId: "toml", extensions: ["toml"], command: "taplo")
            ]),
            availabilityStatus: { _ in .notInstalled }
        )

        #expect(resolver.nudgeData(forAbsolutePath: "/tmp/Config.toml") == nil)
    }

    @Test("Mason fallback skips already available server command")
    func masonFallbackSkipsAvailableServer() {
        let resolver = InstallNudgeResolver(
            registry: LanguageServerRegistry(userDefined: []),
            userDefinedRecipes: [:],
            dismissedInstallNudges: [],
            installerHost: InstallerHost(detected: [.brew: DetectedInstaller(kind: .brew, executable: "/opt/homebrew/bin/brew")]),
            masonSnapshot: MasonSnapshot(packages: [
                package(id: "taplo", languageId: "toml", extensions: ["toml"], command: "taplo")
            ]),
            availabilityStatus: { entry in
                entry.command == "taplo" ? .available : .notInstalled
            }
        )

        #expect(resolver.nudgeData(forAbsolutePath: "/tmp/Config.toml") == nil)
    }

    @Test("Mason fallback skips user-disabled registry extension")
    func masonFallbackSkipsUserDisabledRegistryEntry() {
        let disabled = LanguageServerConfig(
            language: "toml",
            extensions: ["toml"],
            command: "taplo",
            args: [],
            env: [:],
            rootMarkers: [".git"],
            enabled: false
        )
        let resolver = InstallNudgeResolver(
            registry: LanguageServerRegistry(userDefined: [disabled]),
            userDefinedRecipes: [:],
            dismissedInstallNudges: [],
            installerHost: InstallerHost(detected: [.brew: DetectedInstaller(kind: .brew, executable: "/opt/homebrew/bin/brew")]),
            masonSnapshot: MasonSnapshot(packages: [
                package(id: "taplo", languageId: "toml", extensions: ["toml"], command: "taplo")
            ]),
            availabilityStatus: { _ in .notInstalled }
        )

        #expect(resolver.nudgeData(forAbsolutePath: "/tmp/Config.toml") == nil)
    }

    @Test("Mason fallback does not run for enabled built-in without install recipe")
    func masonFallbackSkipsEnabledBuiltInWithoutInstallRecipe() {
        let resolver = InstallNudgeResolver(
            registry: LanguageServerRegistry(userDefined: []),
            userDefinedRecipes: [:],
            dismissedInstallNudges: [],
            installerHost: InstallerHost(detected: [.brew: DetectedInstaller(kind: .brew, executable: "/opt/homebrew/bin/brew")]),
            masonSnapshot: MasonSnapshot(packages: [
                package(id: "clangd", languageId: "c", extensions: ["c"], command: "clangd")
            ]),
            availabilityStatus: { _ in .notInstalled }
        )

        let nudge = resolver.nudgeData(forAbsolutePath: "/tmp/main.c")

        #expect(nudge == nil)
    }

    @Test("registry nudge keeps language dismissal key")
    func registryNudgeUsesLanguageDismissalKey() {
        let rust = LanguageServerConfig(
            language: "rust",
            extensions: ["rs"],
            command: "rust-analyzer",
            args: [],
            env: [:],
            rootMarkers: [".git"],
            enabled: true
        )
        let resolver = InstallNudgeResolver(
            registry: LanguageServerRegistry(userDefined: [rust]),
            userDefinedRecipes: [
                "rust": [InstallRecipe(installer: .brew, package: "rust-analyzer")]
            ],
            dismissedInstallNudges: [],
            installerHost: InstallerHost(detected: [.brew: DetectedInstaller(kind: .brew, executable: "/opt/homebrew/bin/brew")]),
            masonSnapshot: MasonSnapshot(packages: []),
            availabilityStatus: { _ in .notInstalled }
        )

        let nudge = resolver.nudgeData(forAbsolutePath: "/tmp/main.rs")

        #expect(nudge?.language == "rust")
        #expect(nudge?.dismissalKey == "rust")
        #expect(nudge?.masonPackage == nil)
    }

    @Test("Mason fallback does not run for enabled registry-owned extension")
    func masonFallbackSkipsEnabledRegistryExtension() {
        let javascript = LanguageServerConfig(
            language: "javascript",
            extensions: ["js"],
            command: "typescript-language-server",
            args: ["--stdio"],
            env: [:],
            rootMarkers: [".git"],
            enabled: true
        )
        let resolver = InstallNudgeResolver(
            registry: LanguageServerRegistry(userDefined: [javascript]),
            userDefinedRecipes: [:],
            dismissedInstallNudges: [],
            installerHost: InstallerHost(detected: [.brew: DetectedInstaller(kind: .brew, executable: "/opt/homebrew/bin/brew")]),
            masonSnapshot: MasonSnapshot(packages: [
                package(id: "unrelated-js-lsp", languageId: "unrelated", extensions: ["js"], command: "unrelated-js-lsp")
            ]),
            availabilityStatus: { entry in
                entry.language == "javascript" ? .available : .notInstalled
            }
        )

        #expect(resolver.nudgeData(forAbsolutePath: "/tmp/app.js") == nil)
    }

    @Test("Mason fallback scans past unavailable matches before selecting")
    func masonFallbackScansPastUnavailableMatchesBeforeSelecting() {
        let skipped = (0..<(MasonSnapshot.maxResults + 5)).map { idx in
            package(
                id: String(format: "a-skip-%02d", idx),
                languageId: "bar",
                extensions: ["foo"],
                command: String(format: "a-skip-%02d", idx)
            )
        }
        let installable = package(
            id: "z-installable",
            languageId: "bar",
            extensions: ["foo"],
            command: "z-installable"
        )
        let resolver = InstallNudgeResolver(
            registry: LanguageServerRegistry(userDefined: []),
            userDefinedRecipes: [:],
            dismissedInstallNudges: [],
            installerHost: InstallerHost(detected: [.brew: DetectedInstaller(kind: .brew, executable: "/opt/homebrew/bin/brew")]),
            masonSnapshot: MasonSnapshot(packages: skipped + [installable]),
            availabilityStatus: { config in
                config.command.hasPrefix("a-skip-") ? .available : .notInstalled
            }
        )

        let nudge = resolver.nudgeData(forAbsolutePath: "/tmp/file.foo")

        #expect(nudge?.masonPackage?.masonId == "z-installable")
    }

    @Test("Mason fallback caps installable options")
    func masonFallbackCapsInstallableOptions() {
        let packages = (0..<(MasonSnapshot.maxResults + 10)).map { idx in
            package(
                id: String(format: "pkg-%02d", idx),
                languageId: "bar",
                extensions: ["foo"],
                command: String(format: "pkg-%02d", idx)
            )
        }
        let resolver = InstallNudgeResolver(
            registry: LanguageServerRegistry(userDefined: []),
            userDefinedRecipes: [:],
            dismissedInstallNudges: [],
            installerHost: InstallerHost(detected: [.brew: DetectedInstaller(kind: .brew, executable: "/opt/homebrew/bin/brew")]),
            masonSnapshot: MasonSnapshot(packages: packages),
            availabilityStatus: { _ in .notInstalled }
        )

        let nudge = resolver.nudgeData(forAbsolutePath: "/tmp/file.foo")

        #expect(nudge?.masonOptions.count == MasonSnapshot.maxResults)
    }

    @Test("Mason fallback deduplicates after installability filtering")
    func masonFallbackDeduplicatesAfterInstallabilityFiltering() {
        let alreadyAvailable = package(
            id: "duplicate",
            languageId: "bar",
            extensions: ["foo"],
            command: "already-available"
        )
        let installable = package(
            id: "duplicate",
            languageId: "bar",
            extensions: ["foo"],
            command: "installable"
        )
        let resolver = InstallNudgeResolver(
            registry: LanguageServerRegistry(userDefined: []),
            userDefinedRecipes: [:],
            dismissedInstallNudges: [],
            installerHost: InstallerHost(detected: [.brew: DetectedInstaller(kind: .brew, executable: "/opt/homebrew/bin/brew")]),
            masonSnapshot: MasonSnapshot(packages: [alreadyAvailable, installable]),
            availabilityStatus: { config in
                config.command == "already-available" ? .available : .notInstalled
            }
        )

        let nudge = resolver.nudgeData(forAbsolutePath: "/tmp/file.foo")

        #expect(nudge?.command == "installable")
        #expect(nudge?.masonOptions.map(\.id) == ["duplicate"])
    }

    private func package(
        id: String,
        languageId: String,
        extensions: [String],
        command: String
    ) -> MasonPackage {
        MasonPackage(
            masonId: id,
            displayName: id,
            languageId: languageId,
            languages: languageId.isEmpty ? [] : [languageId],
            extensions: extensions,
            command: command,
            args: ["lsp", "stdio"],
            recipes: [InstallRecipe(installer: .brew, package: id)]
        )
    }
}
