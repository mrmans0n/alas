import Foundation
import Testing
@testable import Alas

@Suite("Repo icon resolution")
struct RepoIconResolverTests {
    /// A throwaway checkout plus its own staging root, so nothing here reads or
    /// writes the user's real project-icon store. Removed when the test ends.
    private final class Fixture {
        let checkout: URL
        let staging: URL

        init() throws {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("alas-repo-icon-\(UUID().uuidString)", isDirectory: true)
            checkout = base.appendingPathComponent("checkout", isDirectory: true)
            staging = base.appendingPathComponent("staging", isDirectory: true)
            try FileManager.default.createDirectory(at: alas, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: checkout.deletingLastPathComponent())
        }

        var alas: URL { checkout.appendingPathComponent(".alas", isDirectory: true) }

        /// One level above the checkout, where an escaping `..` path would land.
        var container: URL { checkout.deletingLastPathComponent() }

        func writeIcon(_ name: String, bytes: Data) throws {
            try bytes.write(to: alas.appendingPathComponent(name), options: .atomic)
        }

        /// Past the staging limit, with PNG magic bytes so only its size can
        /// rule it out — the bytes themselves are readable and stageable.
        func writeOversizedIcon(_ name: String) throws {
            var bytes = RepoIconResolverTests.pngBytes
            bytes.append(Data(repeating: 0, count: ProjectIconImageStaging.maxBytes))
            try writeIcon(name, bytes: bytes)
        }

        func stagedFileURLs() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        }
    }

    private static let projectID = "project-1"
    /// PNG magic bytes are all the staging pipeline inspects, so these stand in
    /// for real images while staying obviously not one.
    private static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    private static let otherPNGBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0B])

    private func resolve(
        appIcon: ProjectIcon,
        repoConfig: RepoConfig? = nil,
        in fixture: Fixture
    ) -> ProjectIcon {
        resolution(appIcon: appIcon, repoConfig: repoConfig, in: fixture).icon
    }

    private func resolution(
        appIcon: ProjectIcon,
        repoConfig: RepoConfig? = nil,
        in fixture: Fixture
    ) -> RepoIconResolver.RepoIconResolution {
        RepoIconResolver.resolve(
            appIcon: appIcon,
            projectID: Self.projectID,
            repoConfig: repoConfig,
            primaryCheckout: fixture.checkout,
            store: RepoConfigStore(),
            stagingRoot: fixture.staging
        )
    }

    private func probe(
        appIcon: ProjectIcon,
        repoConfig: RepoConfig? = nil,
        in fixture: Fixture
    ) -> RepoIconResolver.SourceIdentity? {
        RepoIconResolver.sourceIdentity(
            repoConfig: repoConfig,
            appIcon: appIcon,
            primaryCheckout: fixture.checkout,
            store: RepoConfigStore()
        )
    }

    @Test func discoveredIconIsStagedAndKeepsAppPreferences() throws {
        let fixture = try Fixture()
        try fixture.writeIcon("icon.png", bytes: Self.pngBytes)

        let appIcon = ProjectIcon(mode: .letter, color: "#112233", transparentBackground: true)
        let resolved = resolve(appIcon: appIcon, in: fixture)
        let expected = try ProjectIconImageStaging.stage(
            data: Self.pngBytes,
            projectId: Self.projectID,
            root: fixture.staging
        )

        #expect(resolved.mode == .image)
        #expect(resolved.imagePath == expected.imagePath)
        #expect(resolved.imagePath?.hasPrefix("\(Self.projectID)/") == true)
        #expect(resolved.color == "#112233")
        #expect(resolved.transparentBackground)
    }

    @Test func configIconBeatsDiscoveredFile() throws {
        let fixture = try Fixture()
        try fixture.writeIcon("icon.png", bytes: Self.pngBytes)
        try fixture.writeIcon("logo.png", bytes: Self.otherPNGBytes)

        let resolved = resolve(
            appIcon: .default(),
            repoConfig: RepoConfig(icon: .init(image: "logo.png")),
            in: fixture
        )
        let expected = try ProjectIconImageStaging.stage(
            data: Self.otherPNGBytes,
            projectId: Self.projectID,
            root: fixture.staging
        )

        #expect(resolved.imagePath == expected.imagePath)
    }

    @Test func missingConfigIconFallsBackToDiscoveredFile() throws {
        let fixture = try Fixture()
        try fixture.writeIcon("icon.png", bytes: Self.pngBytes)

        let resolved = resolve(
            appIcon: .default(),
            repoConfig: RepoConfig(icon: .init(image: "nope.png")),
            in: fixture
        )
        let expected = try ProjectIconImageStaging.stage(
            data: Self.pngBytes,
            projectId: Self.projectID,
            root: fixture.staging
        )

        #expect(resolved.imagePath == expected.imagePath)
    }

    @Test func unusableConfigIconFallsThroughToDiscoveredFile() throws {
        let fixture = try Fixture()
        try fixture.writeIcon("icon.png", bytes: Self.pngBytes)
        try fixture.writeIcon("broken.png", bytes: Data("not an image".utf8))

        let resolved = resolve(
            appIcon: .default(),
            repoConfig: RepoConfig(icon: .init(image: "broken.png")),
            in: fixture
        )
        let expected = try ProjectIconImageStaging.stage(
            data: Self.pngBytes,
            projectId: Self.projectID,
            root: fixture.staging
        )

        #expect(resolved.imagePath == expected.imagePath)
    }

    @Test func noRepoIconLeavesTheAppIconAlone() throws {
        let fixture = try Fixture()
        let appIcon = ProjectIcon(mode: .letter, color: "#112233")

        #expect(resolve(appIcon: appIcon, in: fixture) == appIcon)
    }

    @Test func undecodableIconFileFallsBackToAppIcon() throws {
        let fixture = try Fixture()
        try fixture.writeIcon("icon.png", bytes: Data("not an image".utf8))
        let appIcon = ProjectIcon(mode: .letter, color: "#112233")

        #expect(resolve(appIcon: appIcon, in: fixture) == appIcon)
    }

    @Test func stagedPathIsContentAddressed() throws {
        let fixture = try Fixture()
        try fixture.writeIcon("icon.png", bytes: Self.pngBytes)
        try fixture.writeIcon("logo.png", bytes: Self.otherPNGBytes)

        let fromDiscovery = resolve(appIcon: .default(), in: fixture)
        let fromConfig = resolve(
            appIcon: .default(),
            repoConfig: RepoConfig(icon: .init(image: "logo.png")),
            in: fixture
        )
        let stagedAgain = try ProjectIconImageStaging.stage(
            data: Self.pngBytes,
            projectId: Self.projectID,
            root: fixture.staging
        )

        // Same bytes resolve to the same staged file; different bytes do not.
        #expect(fromDiscovery.imagePath == stagedAgain.imagePath)
        #expect(fromDiscovery.imagePath != fromConfig.imagePath)
    }

    @Test func explicitAppIconsAlwaysWin() throws {
        let fixture = try Fixture()
        try fixture.writeIcon("icon.png", bytes: Self.pngBytes)

        let explicitIcons = [
            ProjectIcon(mode: .letter, color: "#112233", label: "AB"),
            ProjectIcon(mode: .symbol, color: "#112233", symbolName: "star"),
            ProjectIcon(mode: .emoji, color: "#112233", emoji: "🚀"),
            ProjectIcon(mode: .image, color: "#112233", imagePath: "project-1/chosen.png"),
        ]

        for icon in explicitIcons {
            #expect(resolve(appIcon: icon, in: fixture) == icon)
        }
    }

    @Test func colorPicksAreNotExplicit() {
        // A colour pick is cosmetic: it must not veto the repo's logo.
        #expect(RepoIconResolver.iconIsExplicit(.default()) == false)
        #expect(RepoIconResolver.iconIsExplicit(.default(color: "#ff0000")) == false)
    }

    @Test func chosenGlyphsAndLabelsAreExplicit() {
        #expect(RepoIconResolver.iconIsExplicit(.init(mode: .letter, color: "#5fb7c4", label: "AB")))
        #expect(RepoIconResolver.iconIsExplicit(.init(mode: .symbol, color: "#5fb7c4", symbolName: "star")))
        #expect(RepoIconResolver.iconIsExplicit(.init(mode: .emoji, color: "#5fb7c4", emoji: "🚀")))
        #expect(RepoIconResolver.iconIsExplicit(.init(mode: .image, color: "#5fb7c4", imagePath: "p/x.png")))
    }

    // MARK: - Resolution source

    @Test func resolveReportsTheDiscoveredFileAsTheSource() throws {
        let fixture = try Fixture()
        try fixture.writeIcon("icon.png", bytes: Self.pngBytes)

        let resolution = resolution(appIcon: .default(), in: fixture)
        let expected = try ProjectIconImageStaging.stage(
            data: Self.pngBytes,
            projectId: Self.projectID,
            root: fixture.staging
        )

        #expect(resolution.icon.imagePath == expected.imagePath)
        #expect(resolution.sourceURL == fixture.alas.appendingPathComponent("icon.png"))
        #expect(resolution.sourceModificationDate != nil)
        #expect(resolution.sourceFileSize == Self.pngBytes.count)
    }

    @Test func resolveReportsTheConfigKeyedFileAsTheSource() throws {
        let fixture = try Fixture()
        try fixture.writeIcon("icon.png", bytes: Self.pngBytes)
        try fixture.writeIcon("logo.png", bytes: Self.otherPNGBytes)

        let resolution = resolution(
            appIcon: .default(),
            repoConfig: RepoConfig(icon: .init(image: "logo.png")),
            in: fixture
        )

        #expect(resolution.sourceURL == fixture.alas.appendingPathComponent("logo.png"))
        #expect(resolution.sourceModificationDate != nil)
        #expect(resolution.sourceFileSize == Self.otherPNGBytes.count)
    }

    @Test func resolveReportsNoSourceWhenTheAppIconIsUsed() throws {
        let fixture = try Fixture()
        let appIcon = ProjectIcon(mode: .letter, color: "#112233")

        let noRepoIcon = resolution(appIcon: appIcon, in: fixture)
        #expect(noRepoIcon.icon == appIcon)
        #expect(noRepoIcon.sourceURL == nil)
        #expect(noRepoIcon.sourceModificationDate == nil)
        #expect(noRepoIcon.sourceFileSize == nil)

        // An explicit app icon wins without ever consulting a repo file, so it
        // has no source to cache on either.
        try fixture.writeIcon("icon.png", bytes: Self.pngBytes)
        let explicit = ProjectIcon(mode: .emoji, color: "#112233", emoji: "🚀")
        let explicitResolution = resolution(appIcon: explicit, in: fixture)
        #expect(explicitResolution.icon == explicit)
        #expect(explicitResolution.sourceURL == nil)
        #expect(explicitResolution.sourceModificationDate == nil)
        #expect(explicitResolution.sourceFileSize == nil)
    }

    @Test func effectiveIconReturnsWhatResolveReports() throws {
        let fixture = try Fixture()
        try fixture.writeIcon("icon.png", bytes: Self.pngBytes)
        let appIcon = ProjectIcon(mode: .letter, color: "#112233")

        let icon = RepoIconResolver.effectiveIcon(
            appIcon: appIcon,
            projectID: Self.projectID,
            repoConfig: nil,
            primaryCheckout: fixture.checkout,
            store: RepoConfigStore(),
            stagingRoot: fixture.staging
        )

        #expect(icon == resolution(appIcon: appIcon, in: fixture).icon)
        #expect(icon.mode == .image)
    }

    // MARK: - Stats-only probe

    @Test func probeReportsTheWinningFileWithoutStagingAnything() throws {
        let fixture = try Fixture()
        try fixture.writeIcon("icon.png", bytes: Self.pngBytes)

        let identity = probe(appIcon: .default(), in: fixture)

        #expect(identity?.url == fixture.alas.appendingPathComponent("icon.png"))
        #expect(identity?.modificationDate != nil)
        #expect(identity?.fileSize == Self.pngBytes.count)
        // Stats only: unlike a resolve of the same tree, nothing was staged.
        #expect(try fixture.stagedFileURLs().isEmpty)
    }

    @Test func probePrefersTheConfigKeyedFileAndAgreesWithResolve() throws {
        let fixture = try Fixture()
        try fixture.writeIcon("icon.png", bytes: Self.pngBytes)
        try fixture.writeIcon("logo.png", bytes: Self.otherPNGBytes)
        let config = RepoConfig(icon: .init(image: "logo.png"))

        let identity = probe(appIcon: .default(), repoConfig: config, in: fixture)
        let resolution = resolution(appIcon: .default(), repoConfig: config, in: fixture)

        // The probe mirrors resolve's candidate order, which is what lets a
        // caller cache on it and skip resolve entirely on a hit.
        #expect(identity?.url == fixture.alas.appendingPathComponent("logo.png"))
        #expect(identity == resolution.sourceIdentity)
    }

    @Test func probeIsNilWhenNothingUsableExists() throws {
        let fixture = try Fixture()
        #expect(probe(appIcon: .default(), in: fixture) == nil)

        try fixture.writeIcon("icon.png", bytes: Self.pngBytes)
        let explicit = ProjectIcon(mode: .emoji, color: "#112233", emoji: "🚀")
        #expect(probe(appIcon: explicit, in: fixture) == nil)
    }

    @Test func probeSkipsAnOversizedConfiguredIcon() throws {
        let fixture = try Fixture()
        try fixture.writeIcon("icon.png", bytes: Self.pngBytes)
        try fixture.writeOversizedIcon("huge.png")

        let identity = probe(
            appIcon: .default(),
            repoConfig: RepoConfig(icon: .init(image: "huge.png")),
            in: fixture
        )

        #expect(identity?.url == fixture.alas.appendingPathComponent("icon.png"))
    }

    @Test func oversizedConfiguredIconFallsThroughToTheDiscoveredFile() throws {
        let fixture = try Fixture()
        try fixture.writeIcon("icon.png", bytes: Self.pngBytes)
        try fixture.writeOversizedIcon("huge.png")

        let resolution = resolution(
            appIcon: .default(),
            repoConfig: RepoConfig(icon: .init(image: "huge.png")),
            in: fixture
        )
        let expected = try ProjectIconImageStaging.stage(
            data: Self.pngBytes,
            projectId: Self.projectID,
            root: fixture.staging
        )

        // The oversized file is refused on its size, so the smaller discovered
        // icon is what ends up staged.
        #expect(resolution.icon.imagePath == expected.imagePath)
        #expect(resolution.sourceURL == fixture.alas.appendingPathComponent("icon.png"))
        #expect(resolution.sourceIdentity == probe(
            appIcon: .default(),
            repoConfig: RepoConfig(icon: .init(image: "huge.png")),
            in: fixture
        ))
    }

    // MARK: - Containment

    @Test func unsafeConfigPathCannotEscapeTheCheckout() throws {
        let fixture = try Fixture()
        // A real PNG one level above the checkout, exactly where an escaping
        // path would resolve to.
        try Self.otherPNGBytes.write(to: fixture.container.appendingPathComponent("escape.png"))
        let appIcon = ProjectIcon(mode: .letter, color: "#112233")

        let resolution = resolution(
            appIcon: appIcon,
            repoConfig: RepoConfig(icon: .init(image: "../../escape.png")),
            in: fixture
        )

        #expect(resolution.icon == appIcon)
        #expect(resolution.icon.mode != .image)
        #expect(resolution.sourceURL == nil)
        // Nothing was read or staged, so the outside file was never touched.
        #expect(try fixture.stagedFileURLs().isEmpty)
    }

    @Test func unsafeConfigPathStillFallsThroughToTheDiscoveredIcon() throws {
        let fixture = try Fixture()
        try Self.otherPNGBytes.write(to: fixture.container.appendingPathComponent("escape.png"))
        try fixture.writeIcon("icon.png", bytes: Self.pngBytes)

        let resolution = resolution(
            appIcon: .default(),
            repoConfig: RepoConfig(icon: .init(image: "../../escape.png")),
            in: fixture
        )
        let expected = try ProjectIconImageStaging.stage(
            data: Self.pngBytes,
            projectId: Self.projectID,
            root: fixture.staging
        )

        #expect(resolution.icon.imagePath == expected.imagePath)
        #expect(resolution.sourceURL == fixture.alas.appendingPathComponent("icon.png"))
    }
}
