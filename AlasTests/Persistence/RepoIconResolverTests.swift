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

        func writeIcon(_ name: String, bytes: Data) throws {
            try bytes.write(to: alas.appendingPathComponent(name), options: .atomic)
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
        RepoIconResolver.effectiveIcon(
            appIcon: appIcon,
            projectID: Self.projectID,
            repoConfig: repoConfig,
            primaryCheckout: fixture.checkout,
            store: RepoConfigStore(),
            stagingRoot: fixture.staging
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
}
