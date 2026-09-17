import Foundation
import Testing
@testable import Alas

@Suite("AppState repo icons")
@MainActor
struct AppStateRepoIconTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    /// PNG magic bytes are all the staging pipeline inspects, so these stand in
    /// for a real image while staying obviously not one.
    private static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// A throwaway checkout plus its own staging root, so nothing here reads or
    /// writes the user's real project-icon store. Removed when the test ends.
    private final class Fixture {
        let checkout: URL
        let staging: URL

        init() throws {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("alas-repo-icon-state-\(UUID().uuidString)", isDirectory: true)
            checkout = base.appendingPathComponent("checkout", isDirectory: true)
            staging = base.appendingPathComponent("staging", isDirectory: true)
            try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: checkout.deletingLastPathComponent())
        }

        var alas: URL { checkout.appendingPathComponent(".alas", isDirectory: true) }

        func writeIcon(_ name: String, bytes: Data) throws {
            try FileManager.default.createDirectory(at: alas, withIntermediateDirectories: true)
            try bytes.write(to: alas.appendingPathComponent(name), options: .atomic)
        }

        func writeConfig(_ json: String) throws {
            let config = checkout.appendingPathComponent(RepoConfig.relativePath)
            try FileManager.default.createDirectory(
                at: config.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(json.utf8).write(to: config, options: .atomic)
        }
    }

    private func state(staging: URL) -> AppState {
        let state = AppState(store: MemoryStore())
        state.repoIconStagingRoot = staging
        return state
    }

    private func project(
        path: String,
        host: String? = nil,
        icon: ProjectIcon = .default(color: "#112233")
    ) -> ProjectConfig {
        ProjectConfig(
            id: "project-1",
            name: "Sample",
            path: path,
            color: icon.color,
            addedAt: Date(timeIntervalSince1970: 0),
            icon: icon,
            host: host
        )
    }

    @Test func remoteProjectsKeepTheirAppIcon() throws {
        let fixture = try Fixture()
        let state = state(staging: fixture.staging)
        let remote = project(path: fixture.checkout.path, host: "user@example.com")

        #expect(state.effectiveIcon(for: remote) == remote.icon)
    }

    @Test func projectsWithoutARepoIconKeepTheirAppIcon() throws {
        let fixture = try Fixture()
        let state = state(staging: fixture.staging)
        let local = project(path: fixture.checkout.path)

        #expect(state.effectiveIcon(for: local) == local.icon)
        #expect(state.repoIconDisplayCache.storedEntryCount == 0)
    }

    @Test func repoIconIsResolvedAndThenServedFromCache() throws {
        let fixture = try Fixture()
        try fixture.writeIcon("icon.png", bytes: Self.pngBytes)
        let state = state(staging: fixture.staging)
        let local = project(path: fixture.checkout.path)

        let resolved = state.effectiveIcon(for: local)

        #expect(resolved.mode == .image)
        #expect(resolved.imagePath?.hasPrefix("project-1/") == true)
        #expect(resolved.color == "#112233")
        #expect(state.repoIconDisplayCache.storedEntryCount == 1)
        #expect(state.effectiveIcon(for: local) == resolved)
    }

    @Test func cacheHitDoesNoStagingWork() throws {
        let fixture = try Fixture()
        try fixture.writeIcon("icon.png", bytes: Self.pngBytes)
        let state = state(staging: fixture.staging)
        let local = project(path: fixture.checkout.path)

        let resolved = state.effectiveIcon(for: local)
        let stagedPath = try #require(resolved.imagePath)
        let stagedFile = fixture.staging.appendingPathComponent(stagedPath)
        #expect(FileManager.default.fileExists(atPath: stagedFile.path))

        // Remove the staged copy. A lookup that runs before resolving answers
        // from memory and leaves it gone (the staged file is the visible trace
        // of the read + hash + write work resolve does). A lookup that runs
        // after resolving re-stages the image on every render, which is exactly
        // the per-render work the cache exists to avoid.
        try FileManager.default.removeItem(at: stagedFile)

        #expect(state.effectiveIcon(for: local) == resolved)
        #expect(!FileManager.default.fileExists(atPath: stagedFile.path))
    }

    @Test func unreadableRepoFileStillShowsTheStagedIcon() throws {
        // Root ignores file permissions, so the condition cannot be created.
        guard getuid() != 0 else { return }

        let fixture = try Fixture()
        try fixture.writeIcon("icon.png", bytes: Self.pngBytes)
        let state = state(staging: fixture.staging)
        let local = project(path: fixture.checkout.path)

        let resolved = state.effectiveIcon(for: local)
        #expect(resolved.mode == .image)

        // Make the repo file unreadable without moving its identity stamp:
        // chmod changes ctime, never mtime or size. The staged icon stays the
        // answer, so an unreadable file never regresses what is displayed.
        // (This holds whether the cache is consulted before or after resolving,
        // so it is an invariant rather than a guard on the lookup order.)
        let iconFile = fixture.alas.appendingPathComponent("icon.png")
        let before = try iconFile.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: iconFile.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: iconFile.path)
        }
        let after = try iconFile.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        #expect(after.contentModificationDate == before.contentModificationDate)
        #expect(after.fileSize == before.fileSize)

        #expect(state.effectiveIcon(for: local) == resolved)
    }

    @Test func appIconPreferencesAreReflectedWithoutWaitingForTheFileToChange() throws {
        let fixture = try Fixture()
        try fixture.writeIcon("icon.png", bytes: Self.pngBytes)
        let state = state(staging: fixture.staging)

        let blue = state.effectiveIcon(for: project(path: fixture.checkout.path))
        let recoloured = state.effectiveIcon(
            for: project(path: fixture.checkout.path, icon: .default(color: "#ff0000"))
        )

        #expect(blue.color == "#112233")
        #expect(recoloured.mode == .image)
        #expect(recoloured.color == "#ff0000")
    }

    @Test func replacedRepoIconIsPickedUp() throws {
        let fixture = try Fixture()
        try fixture.writeIcon("icon.png", bytes: Self.pngBytes)
        let state = state(staging: fixture.staging)
        let local = project(path: fixture.checkout.path)

        let first = state.effectiveIcon(for: local)
        try fixture.writeIcon("icon.png", bytes: Self.pngBytes + Data([0x00]))
        let replaced = state.effectiveIcon(for: local)

        #expect(replaced.mode == .image)
        #expect(replaced.imagePath != first.imagePath)
    }

    @Test func fallbackIconEditsAreNotMaskedByABrokenConfiguredFile() throws {
        // A configured icon that exists but cannot be used (here: not an
        // image) makes resolve fall through to the discovered icon.png. The
        // cache key covers the whole candidate chain, so editing or deleting
        // that fallback must show up even while the broken configured file is
        // unchanged — keying only on the fallback's own identity would too,
        // but keying on the broken head alone would keep the stale image.
        let fixture = try Fixture()
        try fixture.writeConfig(#"{"version": 1, "icon": {"image": "logo.svg"}}"#)
        try fixture.writeIcon("icon.png", bytes: Self.pngBytes)
        let state = state(staging: fixture.staging)
        let local = project(path: fixture.checkout.path)

        let first = state.effectiveIcon(for: local)
        #expect(first.mode == .image)

        try fixture.writeIcon("icon.png", bytes: Self.pngBytes + Data([0x00]))
        let second = state.effectiveIcon(for: local)
        #expect(second.imagePath != first.imagePath)
    }

    @Test("an unknown repo default agent falls through to the global one")
    func unknownRepoDefaultAgentFallsThroughToGlobal() throws {
        let fixture = try Fixture()
        try fixture.writeConfig(#"{"version": 1, "defaultAgent": "unknown-agent"}"#)
        let local = project(path: fixture.checkout.path)
        let state = AppState(store: SeededStore(projects: ProjectsFile(projects: [local])))
        state.repoIconStagingRoot = fixture.staging
        state.config.agents.worktreeAutoLaunch.agentId = "global-agent"

        #expect(
            state.defaultAgentID(projectId: local.id, worktreeRoot: fixture.checkout) == "global-agent"
        )
    }

    /// Store stub whose read returns the seeded projects file, so an
    /// AppState boots with the projects under test without touching disk.
    private struct SeededStore: PersistenceStoreProtocol {
        let projects: ProjectsFile

        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_ type: T.Type, from _: URL) throws -> T? {
            type == ProjectsFile.self ? (projects as? T) : nil
        }
    }
}
