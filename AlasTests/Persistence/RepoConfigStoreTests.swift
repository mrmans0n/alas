import Foundation
import Testing
@testable import Alas

@Suite("Repo config store")
struct RepoConfigStoreTests {
    /// A throwaway checkout root with a `.alas/` directory that removes itself
    /// when the test ends. Nothing here touches the user's real
    /// application-support directories.
    private final class WorktreeFixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("alas-repo-config-store-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: alas, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        var alas: URL { root.appendingPathComponent(".alas", isDirectory: true) }
        var configFile: URL { root.appendingPathComponent(RepoConfig.relativePath) }

        func writeConfig(_ json: String) throws {
            try Data(json.utf8).write(to: configFile, options: .atomic)
        }

        func removeConfig() throws {
            try FileManager.default.removeItem(at: configFile)
        }
    }

    @Test func loadsConfigWhenPresent() throws {
        let worktree = try WorktreeFixture()
        try worktree.writeConfig(#"{"version": 1, "defaultAgent": "pi"}"#)

        let result = RepoConfigStore().load(worktreeRoot: worktree.root)

        #expect(result == .loaded(RepoConfig(defaultAgent: "pi")))
    }

    @Test func missingFileIsMissing() throws {
        let worktree = try WorktreeFixture()
        let store = RepoConfigStore()

        #expect(store.load(worktreeRoot: worktree.root) == .missing)
        #expect(store.config(worktreeRoot: worktree.root) == nil)
    }

    @Test func malformedFileIsMalformedAndContributesNoConfig() throws {
        let worktree = try WorktreeFixture()
        let store = RepoConfigStore()

        try worktree.writeConfig("this is not json")
        #expect(store.load(worktreeRoot: worktree.root) == .malformed)
        #expect(store.config(worktreeRoot: worktree.root) == nil)

        // A wrong version is malformed too, not silently "loaded and empty".
        try worktree.writeConfig(#"{"version": 7, "defaultAgent": "pi"}"#)
        #expect(store.load(worktreeRoot: worktree.root) == .malformed)
    }

    @Test func unreadableConfigIsMalformedNotMissing() throws {
        // Root ignores file permissions, so the condition cannot be created.
        guard getuid() != 0 else { return }

        let worktree = try WorktreeFixture()
        try worktree.writeConfig(#"{"version": 1, "defaultAgent": "pi"}"#)
        let fileManager = FileManager.default
        try fileManager.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: worktree.configFile.path
        )
        defer {
            // Restore so the fixture's cleanup can delete the file.
            try? fileManager.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: worktree.configFile.path
            )
        }

        let store = RepoConfigStore()

        #expect(store.load(worktreeRoot: worktree.root) == .malformed)
        #expect(store.config(worktreeRoot: worktree.root) == nil)
    }

    @Test func symlinkedConfigOutsideTheCheckoutIsRefused() throws {
        let worktree = try WorktreeFixture()
        let outside = worktree.root.deletingLastPathComponent()
            .appendingPathComponent("outside-config.json")
        try Data(#"{"version": 1, "defaultAgent": "pi"}"#.utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            atPath: worktree.configFile.path,
            withDestinationPath: outside.path
        )
        defer { try? FileManager.default.removeItem(at: outside) }

        // The read must not follow the link out of the repo, even though the
        // target is a perfectly loadable config: confinement is by location,
        // not by what happens to be at the destination.
        let store = RepoConfigStore()
        #expect(store.load(worktreeRoot: worktree.root) == .malformed)
        #expect(store.config(worktreeRoot: worktree.root) == nil)
    }

    @Test func symlinkedConfigInsideTheAlasDirectoryIsFollowed() throws {
        let worktree = try WorktreeFixture()
        let real = worktree.alas.appendingPathComponent("config-real.json")
        try Data(#"{"version": 1, "defaultAgent": "pi"}"#.utf8).write(to: real)
        try FileManager.default.createSymbolicLink(
            atPath: worktree.configFile.path,
            withDestinationPath: real.path
        )

        // A link that stays inside the repo is a normal way to organize
        // config files and keeps working.
        let store = RepoConfigStore()
        #expect(store.load(worktreeRoot: worktree.root) == .loaded(RepoConfig(jsonData: Data(#"{"version": 1, "defaultAgent": "pi"}"#.utf8))!))
    }

    @Test func configPointingAtACharacterDeviceIsRefused() throws {
        // /dev/zero exists on macOS and Linux CI alike; reading it never
        // returns, so the confinement must reject the target before any read.
        guard FileManager.default.fileExists(atPath: "/dev/zero") else { return }

        let worktree = try WorktreeFixture()
        try FileManager.default.createSymbolicLink(
            atPath: worktree.configFile.path,
            withDestinationPath: "/dev/zero"
        )

        let store = RepoConfigStore()
        #expect(store.load(worktreeRoot: worktree.root) == .malformed)
        #expect(store.config(worktreeRoot: worktree.root) == nil)
    }

    @Test func configAccessorReturnsLoadedConfig() throws {
        let worktree = try WorktreeFixture()
        try worktree.writeConfig(#"{"version": 1, "icon": {"image": "logo.png"}}"#)

        #expect(RepoConfigStore().config(worktreeRoot: worktree.root)?.icon?.image == "logo.png")
    }

    @Test func picksUpAFileThatAppearsLater() throws {
        let worktree = try WorktreeFixture()
        let store = RepoConfigStore()
        #expect(store.load(worktreeRoot: worktree.root) == .missing)

        try worktree.writeConfig(#"{"version": 1, "defaultAgent": "pi"}"#)

        #expect(store.config(worktreeRoot: worktree.root)?.defaultAgent == "pi")
    }

    @Test func reloadsWhenTheContentChanges() throws {
        let worktree = try WorktreeFixture()
        let store = RepoConfigStore()
        try worktree.writeConfig(#"{"version": 1, "defaultAgent": "pi"}"#)
        #expect(store.config(worktreeRoot: worktree.root)?.defaultAgent == "pi")

        // Different content *and* a different size, so the cache cannot read a
        // same-second rewrite as unchanged even before the timestamp moves.
        Thread.sleep(forTimeInterval: 0.05)
        try worktree.writeConfig(#"{"version": 1, "defaultAgent": "claude-code"}"#)

        #expect(store.config(worktreeRoot: worktree.root)?.defaultAgent == "claude-code")
    }

    @Test func reloadsWhenOnlyTheModificationDateChanges() throws {
        let worktree = try WorktreeFixture()
        let store = RepoConfigStore()
        try worktree.writeConfig(#"{"version": 1, "defaultAgent": "pi"}"#)
        #expect(store.config(worktreeRoot: worktree.root)?.defaultAgent == "pi")

        // Same byte length as the first write, so only the modification date
        // can reveal this rewrite: a size-only cache would serve "pi".
        Thread.sleep(forTimeInterval: 0.05)
        try worktree.writeConfig(#"{"version": 1, "defaultAgent": "ab"}"#)

        #expect(store.config(worktreeRoot: worktree.root)?.defaultAgent == "ab")
    }

    @Test func reloadsWhenASymlinkIsRepointedBetweenEqualFiles() throws {
        let worktree = try WorktreeFixture()
        let first = worktree.alas.appendingPathComponent("config-a.json")
        let second = worktree.alas.appendingPathComponent("config-b.json")
        // Byte-identical length, different content; both stamped to the same
        // modification date so only the resolved target path distinguishes
        // them in the cache.
        try Data(#"{"version": 1, "defaultAgent": "a"}"#.utf8).write(to: first)
        try Data(#"{"version": 1, "defaultAgent": "b"}"#.utf8).write(to: second)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        for file in [first, second] {
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        }
        try FileManager.default.createSymbolicLink(
            atPath: worktree.configFile.path,
            withDestinationPath: first.path
        )

        let store = RepoConfigStore()
        #expect(store.config(worktreeRoot: worktree.root)?.defaultAgent == "a")

        // Repoint the symlink at an equal-stamp, different-content file.
        try FileManager.default.removeItem(at: worktree.configFile)
        try FileManager.default.createSymbolicLink(
            atPath: worktree.configFile.path,
            withDestinationPath: second.path
        )

        #expect(store.config(worktreeRoot: worktree.root)?.defaultAgent == "b")
    }

    @Test func reloadsFromMalformedToLoaded() throws {
        let worktree = try WorktreeFixture()
        let store = RepoConfigStore()
        try worktree.writeConfig("broken")
        #expect(store.load(worktreeRoot: worktree.root) == .malformed)

        Thread.sleep(forTimeInterval: 0.05)
        try worktree.writeConfig(#"{"version": 1, "defaultAgent": "pi"}"#)

        #expect(store.config(worktreeRoot: worktree.root)?.defaultAgent == "pi")
    }

    @Test func reloadsFromLoadedToMalformed() throws {
        let worktree = try WorktreeFixture()
        let store = RepoConfigStore()
        try worktree.writeConfig(#"{"version": 1, "defaultAgent": "pi"}"#)
        #expect(store.load(worktreeRoot: worktree.root) == .loaded(RepoConfig(defaultAgent: "pi")))

        Thread.sleep(forTimeInterval: 0.05)
        try worktree.writeConfig("no longer json")

        #expect(store.load(worktreeRoot: worktree.root) == .malformed)
        #expect(store.config(worktreeRoot: worktree.root) == nil)
    }

    @Test func reloadsWhenTheFileDisappears() throws {
        let worktree = try WorktreeFixture()
        let store = RepoConfigStore()
        try worktree.writeConfig(#"{"version": 1, "defaultAgent": "pi"}"#)
        #expect(store.load(worktreeRoot: worktree.root) == .loaded(RepoConfig(defaultAgent: "pi")))

        try worktree.removeConfig()

        #expect(store.load(worktreeRoot: worktree.root) == .missing)
    }

    @Test func reloadsFromMalformedToDeleted() throws {
        let worktree = try WorktreeFixture()
        let store = RepoConfigStore()
        try worktree.writeConfig("broken")
        #expect(store.load(worktreeRoot: worktree.root) == .malformed)

        try worktree.removeConfig()

        #expect(store.load(worktreeRoot: worktree.root) == .missing)
    }

    @Test func cachesPerWorktree() throws {
        let first = try WorktreeFixture()
        let second = try WorktreeFixture()
        try first.writeConfig(#"{"version": 1, "defaultAgent": "pi"}"#)
        try second.writeConfig(#"{"version": 1, "defaultAgent": "claude-code"}"#)

        let store = RepoConfigStore()

        #expect(store.config(worktreeRoot: first.root)?.defaultAgent == "pi")
        #expect(store.config(worktreeRoot: second.root)?.defaultAgent == "claude-code")
    }

    @Test func discoversNoIconWhenNoneExists() throws {
        let worktree = try WorktreeFixture()

        #expect(RepoConfigStore.discoveredIconCandidates(worktreeRoot: worktree.root).isEmpty)
    }

    @Test func discoversIconsInExtensionOrder() throws {
        let worktree = try WorktreeFixture()

        #expect(RepoConfigStore.discoveredIconExtensions == ["png", "jpg", "jpeg", "gif", "webp"])

        try Data([0x00]).write(to: worktree.alas.appendingPathComponent("icon.webp"))
        #expect(RepoConfigStore.discoveredIconCandidates(worktreeRoot: worktree.root) == [
            worktree.alas.appendingPathComponent("icon.webp")
        ])

        try Data([0x00]).write(to: worktree.alas.appendingPathComponent("icon.jpg"))
        // Extension order wins: jpg sorts before webp in the result.
        #expect(RepoConfigStore.discoveredIconCandidates(worktreeRoot: worktree.root) == [
            worktree.alas.appendingPathComponent("icon.jpg"),
            worktree.alas.appendingPathComponent("icon.webp"),
        ])

        try Data([0x00]).write(to: worktree.alas.appendingPathComponent("icon.png"))
        #expect(RepoConfigStore.discoveredIconCandidates(worktreeRoot: worktree.root).first?.lastPathComponent == "icon.png")
    }

    @Test func discoversEveryConventionalIconNotJustTheFirst() throws {
        let worktree = try WorktreeFixture()
        try Data([0x00]).write(to: worktree.alas.appendingPathComponent("icon.png"))
        try Data([0x00]).write(to: worktree.alas.appendingPathComponent("icon.jpg"))

        // A broken or oversized head entry is skipped by the resolver, so the
        // store must still name the later candidates instead of hiding them.
        let discovered = RepoConfigStore.discoveredIconCandidates(worktreeRoot: worktree.root)
        #expect(discovered.map(\.lastPathComponent) == ["icon.png", "icon.jpg"])
    }

    @Test func discoversIconUnderTheWorktreeRoot() throws {
        let worktree = try WorktreeFixture()
        try Data([0x00]).write(to: worktree.alas.appendingPathComponent("icon.png"))

        #expect(
            RepoConfigStore.discoveredIconCandidates(worktreeRoot: worktree.root).first
                == worktree.alas.appendingPathComponent("icon.png")
        )
    }
}
