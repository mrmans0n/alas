import Foundation
import Testing
@testable import Alas

@MainActor
struct CheckpointDiffTabTests {
    @Test func stateBuildsStableIdentityAndReadOnlyTabPresentation() throws {
        let checkpointID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000115"))
        let groupID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000910"))

        let state = CheckpointDiffTabState(
            worktreeID: "wt-1",
            checkpointID: checkpointID,
            groupID: groupID,
            primaryPath: "Sources/App/Main.swift",
            checkpointLabel: "Before navigation refactor"
        )
        let tab = Tab.checkpointDiff(state)

        #expect(state.id == "checkpoint-diff:wt-1:\(checkpointID.uuidString):\(groupID.uuidString)")
        #expect(state.title == "Main.swift @ Before navigation refactor")
        #expect(tab.id == state.id)
        #expect(tab.title == state.title)
        #expect(tab.iconName == "clock.arrow.circlepath")
        #expect(tab.relativeFilePath == "Sources/App/Main.swift")
        #expect(!tab.supportsSystemOpenActions)

        let decoded = try JSONDecoder().decode(Tab.self, from: JSONEncoder().encode(tab))
        #expect(decoded == tab)
    }

    @Test func appendCheckpointDiffPersistsStableTabState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-checkpoint-diff-tabs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpointID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000116"))
        let groupID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000911"))
        let worktreeID = "wt-checkpoint-diff"
        let manager = TabsManager(store: PersistenceStore(), tabsDirectory: directory)

        let tab = manager.appendCheckpointDiff(
            worktreeID: worktreeID,
            checkpointID: checkpointID,
            groupID: groupID,
            primaryPath: "Assets/icon.png",
            checkpointLabel: "Before icons"
        )

        #expect(manager.activeTabId(forWorktree: worktreeID) == tab.id)
        #expect(manager.tabs(forWorktree: worktreeID) == [tab])

        let reloaded = TabsManager(store: PersistenceStore(), tabsDirectory: directory)
        reloaded.loadAll(worktreeIds: [worktreeID])
        #expect(reloaded.tabs(forWorktree: worktreeID) == [tab])
        #expect(reloaded.activeTabId(forWorktree: worktreeID) == tab.id)
    }

    @Test func appStateReusesExistingCheckpointDiffTabForSameGroup() throws {
        let checkpointID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000117"))
        let groupID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000912"))
        let worktreeID = "wt-checkpoint-diff-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeID)) }
        let state = AppState()
        let worktree = Worktree(
            id: worktreeID,
            projectId: "project",
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/tmp/repo"),
            status: .clean,
            lastActivity: Date()
        )

        state.openCheckpointDiffTab(
            worktree: worktree,
            checkpointID: checkpointID,
            groupID: groupID,
            primaryPath: "Sources/App.swift",
            checkpointLabel: "Before app"
        )
        state.openCheckpointDiffTab(
            worktree: worktree,
            checkpointID: checkpointID,
            groupID: groupID,
            primaryPath: "Sources/App.swift",
            checkpointLabel: "Before app"
        )

        let tabs = state.tabs.tabs(forWorktree: worktreeID).compactMap { tab -> CheckpointDiffTabState? in
            if case .checkpointDiff(let checkpoint) = tab { return checkpoint }
            return nil
        }
        #expect(tabs.count == 1)
        #expect(state.tabs.activeTabId(forWorktree: worktreeID) == tabs.first?.id)
    }

    @Test func appStateKeepsDifferentCheckpointGroupsDistinct() throws {
        let checkpointID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000118"))
        let firstGroupID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000913"))
        let secondGroupID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000914"))
        let worktreeID = "wt-checkpoint-diff-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeID)) }
        let state = AppState()
        let worktree = Worktree(
            id: worktreeID,
            projectId: "project",
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/tmp/repo"),
            status: .clean,
            lastActivity: Date()
        )

        state.openCheckpointDiffTab(
            worktree: worktree,
            checkpointID: checkpointID,
            groupID: firstGroupID,
            primaryPath: "Sources/App.swift",
            checkpointLabel: "Before app"
        )
        state.openCheckpointDiffTab(
            worktree: worktree,
            checkpointID: checkpointID,
            groupID: secondGroupID,
            primaryPath: "Sources/Other.swift",
            checkpointLabel: "Before app"
        )

        let tabs = state.tabs.tabs(forWorktree: worktreeID).compactMap { tab -> CheckpointDiffTabState? in
            if case .checkpointDiff(let checkpoint) = tab { return checkpoint }
            return nil
        }
        #expect(tabs.map(\.groupID) == [firstGroupID, secondGroupID])
    }

    @Test func contentPresentationRoutesTextImageBinaryAndUnavailable() {
        let text = CheckpointDiffTabPresentation.route(.text(.init(hunks: [])))
        let image = CheckpointDiffTabPresentation.route(.image(.failedLoading()))
        let binary = CheckpointDiffTabPresentation.route(.binary(beforeByteCount: 12, afterByteCount: nil))
        let unavailable = CheckpointDiffTabPresentation.route(.unavailable("Lineage changed."))

        #expect(text == .text)
        #expect(image == .image)
        #expect(binary == .binary(message: "Binary file changed. Checkpoint: 12 bytes · Current: missing"))
        #expect(unavailable == .unavailable("Lineage changed."))
    }

    @Test func emptyTextDiffMessagePrefersMetadataSummary() {
        let metadataOnly = ParsedDiff(
            hunks: [],
            metadataSummary: "File mode changed from 100644 to 100755 — no content changes."
        )
        let empty = ParsedDiff(hunks: [])

        #expect(CheckpointDiffTabPresentation.emptyTextDiffMessage(metadataOnly, path: "Script.sh") == "File mode changed from 100644 to 100755 — no content changes.")
        #expect(CheckpointDiffTabPresentation.emptyTextDiffMessage(empty, path: "Script.sh") == "No changes for Script.sh")
    }

    @Test func loadKeyChangesWhenCurrentWorktreeGenerationChanges() {
        let state = CheckpointDiffTabState(
            worktreeID: "wt-1",
            checkpointID: UUID(uuidString: "00000000-0000-0000-0000-000000000119")!,
            groupID: UUID(uuidString: "00000000-0000-0000-0000-000000000915")!,
            primaryPath: "Sources/App.swift",
            checkpointLabel: "Before app"
        )

        let initial = CheckpointDiffLoadKey.fingerprint(
            state: state,
            lineageID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            retryGeneration: 0,
            currentGeneration: 1
        )
        let changedCurrent = CheckpointDiffLoadKey.fingerprint(
            state: state,
            lineageID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            retryGeneration: 0,
            currentGeneration: 2
        )
        let retried = CheckpointDiffLoadKey.fingerprint(
            state: state,
            lineageID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            retryGeneration: 1,
            currentGeneration: 1
        )

        #expect(initial != changedCurrent)
        #expect(initial != retried)
    }
}
