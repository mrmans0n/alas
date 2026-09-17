import Foundation
import Testing
@testable import Alas

@Suite("Repo config store")
struct RepoConfigStoreTests {
    /// A throwaway checkout root with a `.alas/` directory. Nothing here touches
    /// the user's real application-support directories.
    private func makeWorktree() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-repo-config-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".alas", isDirectory: true),
            withIntermediateDirectories: true
        )
        return url
    }

    private func writeConfig(_ json: String, to worktree: URL) throws {
        try Data(json.utf8).write(
            to: worktree.appendingPathComponent(RepoConfig.relativePath),
            options: .atomic
        )
    }

    @Test func loadsConfigWhenPresent() throws {
        let worktree = try makeWorktree()
        try writeConfig(#"{"version": 1, "defaultAgent": "pi"}"#, to: worktree)

        let result = RepoConfigStore().load(worktreeRoot: worktree)

        #expect(result == .loaded(RepoConfig(defaultAgent: "pi")))
    }

    @Test func missingFileIsMissing() throws {
        let worktree = try makeWorktree()
        let store = RepoConfigStore()

        #expect(store.load(worktreeRoot: worktree) == .missing)
        #expect(store.config(worktreeRoot: worktree) == nil)
    }

    @Test func malformedFileIsMalformedAndContributesNoConfig() throws {
        let worktree = try makeWorktree()
        let store = RepoConfigStore()

        try writeConfig("this is not json", to: worktree)
        #expect(store.load(worktreeRoot: worktree) == .malformed)
        #expect(store.config(worktreeRoot: worktree) == nil)

        // A wrong version is malformed too, not silently "loaded and empty".
        try writeConfig(#"{"version": 7, "defaultAgent": "pi"}"#, to: worktree)
        #expect(store.load(worktreeRoot: worktree) == .malformed)
    }

    @Test func configAccessorReturnsLoadedConfig() throws {
        let worktree = try makeWorktree()
        try writeConfig(#"{"version": 1, "icon": {"image": "logo.png"}}"#, to: worktree)

        #expect(RepoConfigStore().config(worktreeRoot: worktree)?.icon?.image == "logo.png")
    }

    @Test func picksUpAFileThatAppearsLater() throws {
        let worktree = try makeWorktree()
        let store = RepoConfigStore()
        #expect(store.load(worktreeRoot: worktree) == .missing)

        try writeConfig(#"{"version": 1, "defaultAgent": "pi"}"#, to: worktree)

        #expect(store.config(worktreeRoot: worktree)?.defaultAgent == "pi")
    }

    @Test func reloadsWhenTheFileChanges() throws {
        let worktree = try makeWorktree()
        let store = RepoConfigStore()
        try writeConfig(#"{"version": 1, "defaultAgent": "pi"}"#, to: worktree)
        #expect(store.config(worktreeRoot: worktree)?.defaultAgent == "pi")

        // Different content *and* a different size, so the cache cannot read a
        // same-second rewrite as unchanged even before the timestamp moves.
        Thread.sleep(forTimeInterval: 0.05)
        try writeConfig(#"{"version": 1, "defaultAgent": "claude-code"}"#, to: worktree)

        #expect(store.config(worktreeRoot: worktree)?.defaultAgent == "claude-code")
    }

    @Test func reloadsFromMalformedToLoaded() throws {
        let worktree = try makeWorktree()
        let store = RepoConfigStore()
        try writeConfig("broken", to: worktree)
        #expect(store.load(worktreeRoot: worktree) == .malformed)

        Thread.sleep(forTimeInterval: 0.05)
        try writeConfig(#"{"version": 1, "defaultAgent": "pi"}"#, to: worktree)

        #expect(store.config(worktreeRoot: worktree)?.defaultAgent == "pi")
    }

    @Test func reloadsWhenTheFileDisappears() throws {
        let worktree = try makeWorktree()
        let store = RepoConfigStore()
        try writeConfig(#"{"version": 1, "defaultAgent": "pi"}"#, to: worktree)
        #expect(store.load(worktreeRoot: worktree) == .loaded(RepoConfig(defaultAgent: "pi")))

        try FileManager.default.removeItem(
            at: worktree.appendingPathComponent(RepoConfig.relativePath)
        )

        #expect(store.load(worktreeRoot: worktree) == .missing)
    }

    @Test func cachesPerWorktree() throws {
        let first = try makeWorktree()
        let second = try makeWorktree()
        try writeConfig(#"{"version": 1, "defaultAgent": "pi"}"#, to: first)
        try writeConfig(#"{"version": 1, "defaultAgent": "claude-code"}"#, to: second)

        let store = RepoConfigStore()

        #expect(store.config(worktreeRoot: first)?.defaultAgent == "pi")
        #expect(store.config(worktreeRoot: second)?.defaultAgent == "claude-code")
    }

    @Test func discoversNoIconWhenNoneExists() throws {
        let worktree = try makeWorktree()

        #expect(RepoConfigStore().discoveredIconURL(worktreeRoot: worktree) == nil)
    }

    @Test func discoversIconInExtensionOrder() throws {
        let worktree = try makeWorktree()
        let store = RepoConfigStore()
        let alas = worktree.appendingPathComponent(".alas", isDirectory: true)

        #expect(RepoConfigStore.discoveredIconExtensions == ["png", "jpg", "jpeg", "gif", "webp"])

        try Data([0x00]).write(to: alas.appendingPathComponent("icon.webp"))
        #expect(store.discoveredIconURL(worktreeRoot: worktree)?.lastPathComponent == "icon.webp")

        try Data([0x00]).write(to: alas.appendingPathComponent("icon.jpg"))
        #expect(store.discoveredIconURL(worktreeRoot: worktree)?.lastPathComponent == "icon.jpg")

        try Data([0x00]).write(to: alas.appendingPathComponent("icon.png"))
        #expect(store.discoveredIconURL(worktreeRoot: worktree)?.lastPathComponent == "icon.png")
    }

    @Test func discoveredIconIsScopedToTheWorktree() throws {
        let worktree = try makeWorktree()
        try Data([0x00]).write(
            to: worktree.appendingPathComponent(".alas/icon.png")
        )

        #expect(
            RepoConfigStore().discoveredIconURL(worktreeRoot: worktree)
                == worktree.appendingPathComponent(".alas/icon.png")
        )
    }
}
