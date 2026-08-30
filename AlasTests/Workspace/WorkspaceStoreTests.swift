import Foundation
import Testing
@testable import Alas

@Suite("Workspace store")
struct WorkspaceStoreTests {
    @Test func missingStorageIsDistinctFromUnreadableStorage() async throws {
        let url = temporaryURL()
        defer { removeWorkspaceFiles(near: url) }
        let store = WorkspaceStore(url: url)

        #expect(await store.load() == .missing)

        try Data("not JSON".utf8).write(to: url)
        let unreadable = await store.load()
        guard case .unreadable(let recovery) = unreadable else {
            Issue.record("Expected an unreadable recovery result")
            return
        }
        #expect(FileManager.default.fileExists(atPath: try #require(recovery.quarantinedFileURL).path))
    }

    @Test func checkpointWritesRoundTripAtomically() async throws {
        let url = temporaryURL()
        defer { removeWorkspaceFiles(near: url) }
        let store = WorkspaceStore(url: url)
        let state = WorkspaceStateFile(workspaces: [
            Workspace(
                name: "Release train",
                executionLocation: .local,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                members: []
            )
        ])

        try await store.checkpoint(state)

        #expect(await store.load() == .loaded(state))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("tmp").path))
    }

    @Test func ordinaryCheckpointIsBlockedAfterUnreadableStorage() async throws {
        let url = temporaryURL()
        defer { removeWorkspaceFiles(near: url) }
        try Data("not JSON".utf8).write(to: url)
        let store = WorkspaceStore(url: url)

        guard case .unreadable = await store.load() else {
            Issue.record("Expected unreadable storage")
            return
        }

        await #expect(throws: WorkspaceStoreError.recoveryRequired) {
            try await store.checkpoint(WorkspaceStateFile())
        }
    }

    @Test func recoveryMarkerBlocksCheckpointAfterQuarantineAndStoreRestart() async throws {
        let url = temporaryURL()
        defer { removeWorkspaceFiles(near: url) }
        try Data("not JSON".utf8).write(to: url)
        let initialStore = WorkspaceStore(url: url)

        guard case .unreadable = await initialStore.load() else {
            Issue.record("Expected unreadable storage")
            return
        }

        let restartedStore = WorkspaceStore(url: url)
        await #expect(throws: WorkspaceStoreError.recoveryRequired) {
            try await restartedStore.checkpoint(WorkspaceStateFile())
        }
    }

    @Test func failedQuarantineReportsOriginalFileAsRetained() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-workspaces-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("workspaces.json")
        try Data("not JSON".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        let store = WorkspaceStore(url: url)
        let result = await store.load()

        guard case .unreadable(let recovery) = result else {
            Issue.record("Expected unreadable storage")
            return
        }
        #expect(recovery.quarantinedFileURL == nil)
        #expect(recovery.originalFileURL == url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        await #expect(throws: WorkspaceStoreError.recoveryRequired) {
            try await store.checkpoint(WorkspaceStateFile())
        }
    }

    @Test func unsupportedVersionIsQuarantinedAndBlocksCheckpoint() async throws {
        let url = temporaryURL()
        defer { removeWorkspaceFiles(near: url) }
        try Data("""
        {"version": 99, "workspaces": [], "checkouts": []}
        """.utf8).write(to: url)
        let store = WorkspaceStore(url: url)

        guard case .unreadable(let recovery) = await store.load() else {
            Issue.record("Expected unreadable storage")
            return
        }
        #expect(recovery.quarantinedFileURL != nil)
        await #expect(throws: WorkspaceStoreError.recoveryRequired) {
            try await store.checkpoint(WorkspaceStateFile())
        }
    }

    @Test func missingRecoverySidecarStillBlocksCheckpointFromQuarantineArtifact() async throws {
        let url = temporaryURL()
        defer { removeWorkspaceFiles(near: url) }
        try Data("not JSON".utf8).write(to: url)
        let store = WorkspaceStore(url: url)
        guard case .unreadable(let recovery) = await store.load() else {
            Issue.record("Expected unreadable storage")
            return
        }
        try FileManager.default.removeItem(at: url.appendingPathExtension("recovery"))
        #expect(FileManager.default.fileExists(atPath: try #require(recovery.quarantinedFileURL).path))

        let restartedStore = WorkspaceStore(url: url)
        guard case .unreadable = await restartedStore.load() else {
            Issue.record("Expected retained quarantine to remain blocking")
            return
        }
        await #expect(throws: WorkspaceStoreError.recoveryRequired) {
            try await restartedStore.checkpoint(WorkspaceStateFile())
        }
    }

    @Test func corruptRecoverySidecarRemainsBlocking() async throws {
        let url = temporaryURL()
        defer { removeWorkspaceFiles(near: url) }
        try Data("not JSON".utf8).write(to: url)
        let store = WorkspaceStore(url: url)
        guard case .unreadable = await store.load() else {
            Issue.record("Expected unreadable storage")
            return
        }
        try Data("not JSON".utf8).write(to: url.appendingPathExtension("recovery"))

        let restartedStore = WorkspaceStore(url: url)
        guard case .unreadable = await restartedStore.load() else {
            Issue.record("Expected corrupt marker to remain blocking")
            return
        }
        await #expect(throws: WorkspaceStoreError.recoveryRequired) {
            try await restartedStore.checkpoint(WorkspaceStateFile())
        }
    }

    @Test func unversionedStateIsQuarantinedAndBlocksCheckpoint() async throws {
        let url = temporaryURL()
        defer { removeWorkspaceFiles(near: url) }
        try Data("{}".utf8).write(to: url)
        let store = WorkspaceStore(url: url)

        guard case .unreadable = await store.load() else {
            Issue.record("Expected an unversioned state to be unreadable")
            return
        }
        await #expect(throws: WorkspaceStoreError.recoveryRequired) {
            try await store.checkpoint(WorkspaceStateFile())
        }
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-workspaces-\(UUID().uuidString).json")
    }

    private func removeWorkspaceFiles(near url: URL) {
        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent
        for entry in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            where entry.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
