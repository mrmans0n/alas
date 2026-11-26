import AlasCore
import Foundation
import Testing
@testable import Alas

struct ProjectVMBaseStoreTests: Sendable {
    private struct FailedWrite: Error {}
    private let project = "project"
    private let root: URL
    private let shared: VMBundle
    private let store: ProjectVMBaseStore
    private let provenance = ProjectVMBaseStore.Provenance(
        sharedBuild: "25A1", sharedSealedAt: Date(timeIntervalSince1970: 100), scriptHash: nil)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("project-vm-base-\(UUID())")
        shared = VMBundle(url: root.appendingPathComponent("shared"))
        store = ProjectVMBaseStore(root: root)
        try FileManager.default.createDirectory(at: shared.url, withIntermediateDirectories: true)
        for (url, value) in [(shared.diskImage, "old-disk"), (shared.auxiliaryStorage, "old-aux"), (shared.hardwareModel, "old-hw")] {
            try Data(value.utf8).write(to: url)
        }
        try Data().write(to: shared.sealedMarker)
    }

    @Test func failedStateSwitchLeavesOldBaseAndDraftSelected() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try publish(makeDraft(from: .shared(bundle: shared, provenance: provenance, script: nil)))
        let draft = try makeDraft(from: .saved)
        try changeDraft()
        let failing = ProjectVMBaseStore(root: root, writeSelection: { _, _ in throw FailedWrite() })
        #expect(throws: FailedWrite.self) {
            try failing.withProject(project) { try $0.publish(expectedDraft: draft.id, savedAt: .now) }
        }
        let reopened = ProjectVMBaseStore(root: root)
        let state = try reopened.status(projectID: project)
        #expect(state.base?.id == old.id)
        #expect(state.draft?.id == draft.id)
        #expect(try inspectClone(from: reopened, leaf: "before") == ["old-disk", "old-aux", "old-hw"])
        _ = try publish(draft)
        #expect(try inspectClone(from: reopened, leaf: "after") == ["new-disk", "new-aux", "new-hw"])
    }

    @Test func publishConsumesDraftEvenWithRetiredFilesOnDisk() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try publish(makeDraft(from: .shared(bundle: shared, provenance: provenance, script: nil)))
        let draft = try makeDraft(from: .saved)
        try changeDraft()
        let saved = try publish(draft)
        // The store committed the selection; draft retirement has not run yet.
        let reopened = ProjectVMBaseStore(root: root)
        let entry = try #require(reopened.list().first)
        #expect(entry.state.base?.id == saved.id)
        #expect(entry.state.base?.id != old.id)
        #expect(entry.state.draft == nil)
        #expect(try inspectClone(from: reopened, leaf: "reopened") == ["new-disk", "new-aux", "new-hw"])
        let base = VMBundle(url: try #require(entry.baseURL))
        #expect(!FileManager.default.fileExists(atPath: base.machineIdentifier.path))
        #expect(!FileManager.default.fileExists(atPath: base.macAddress.path))
        #expect(!FileManager.default.fileExists(atPath: base.url.appendingPathComponent("state.vzvmsave").path))
    }

    @Test func aCloneRacingPublicationGetsOneCompleteGeneration() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try publish(makeDraft(from: .shared(bundle: shared, provenance: provenance, script: nil)))
        let draft = try makeDraft(from: .saved)
        try changeDraft()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writer = ProjectVMBaseStore(root: root, writeSelection: { data, url in
            entered.signal()
            guard release.wait(timeout: .now() + 30) == .success else { throw FailedWrite() }
            try data.write(to: url, options: .atomic)
        })
        let publication = Task {
            try await onQueue { try writer.withProject(self.project) { try $0.publish(expectedDraft: draft.id, savedAt: .now) } }
        }
        let staged = try await onQueue { entered.wait(timeout: .now() + 30) == .success }
        let selectedDuringStaging = Result { try store.status(projectID: project).base?.id }
        let cloneStarted = DispatchSemaphore(value: 0)
        let clone = Task {
            try await onQueue {
                cloneStarted.signal()
                return try self.inspectClone(from: ProjectVMBaseStore(root: self.root), leaf: "racing")
            }
        }
        let racing = try await onQueue { cloneStarted.wait(timeout: .now() + 30) == .success }
        release.signal()
        _ = try await publication.value
        let files = try await clone.value
        #expect(staged && racing)
        #expect(try selectedDuringStaging.get() == old.id)
        #expect(files == ["new-disk", "new-aux", "new-hw"])
    }

    private func onQueue<T: Sendable>(_ run: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(with: Result(catching: run)) }
        }
    }

    @Test func missingActiveHardwareIsNotTreatedAsAnUnsetBase() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try publish(makeDraft(from: .shared(bundle: shared, provenance: provenance, script: nil)))
        let baseURL = try #require(store.list().first?.baseURL)
        try FileManager.default.removeItem(at: VMBundle(url: baseURL).hardwareModel)
        #expect(throws: (any Error).self) { _ = try inspectClone(from: store, leaf: "missing-hardware") }
    }

    private func makeDraft(from source: ProjectVMBaseStore.DraftSource) throws -> ProjectVMBaseStore.Draft {
        try store.withProject(project) { try $0.replaceDraft(expected: nil, source: source, identity: identity("draft")) }
    }

    private func publish(_ draft: ProjectVMBaseStore.Draft) throws -> ProjectVMBaseStore.Base {
        try store.withProject(project) { try $0.publish(expectedDraft: draft.id, savedAt: .now) }
    }
    private func changeDraft() throws {
        let bundle = VMBundle(url: try #require(store.list().first?.draftURL))
        for (file, value) in [(bundle.diskImage, "new-disk"), (bundle.auxiliaryStorage, "new-aux"), (bundle.hardwareModel, "new-hw"),
                              (bundle.url.appendingPathComponent("state.vzvmsave"), "memory")] {
            try Data(value.utf8).write(to: file)
        }
    }

    private func inspectClone(from store: ProjectVMBaseStore, leaf: String) throws -> [String] {
        let url = root.appendingPathComponent(leaf)
        let identity = identity(leaf)
        let base = try store.withProject(project) { try $0.cloneBase(to: url, identity: identity) }
        _ = try #require(base)
        let clone = VMBundle(url: url)
        #expect(try Data(contentsOf: clone.machineIdentifier) == identity.machineIdentifier)
        #expect(try String(contentsOf: clone.macAddress, encoding: .utf8) == identity.macAddress)
        return try [clone.diskImage, clone.auxiliaryStorage, clone.hardwareModel].map { try String(contentsOf: $0, encoding: .utf8) }
    }

    private func identity(_ name: String) -> VMBundle.CloneIdentity {
        .init(machineIdentifier: Data(name.utf8), macAddress: name)
    }
}
