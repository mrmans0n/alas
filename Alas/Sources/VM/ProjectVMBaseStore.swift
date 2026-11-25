import AlasCore
import CryptoKit
import Darwin
import Foundation

/// The state file is the only selection point. A complete but unselected generation cannot boot.
struct ProjectVMBaseStore: Sendable {
    struct Provenance: Codable, Equatable, Sendable {
        let sharedBuild: String
        let sharedSealedAt: Date
        let scriptHash: String?
    }

    struct Base: Codable, Equatable, Sendable {
        let id: UUID
        let savedAt: Date
        let provenance: Provenance
    }

    enum Setup: Codable, Equatable, Sendable {
        case pending
        case failed(exitCode: Int32?)
        case ready
    }

    struct Draft: Codable, Equatable, Sendable {
        let id: UUID
        let createdAt: Date
        let provenance: Provenance
        let script: String?
        var setup: Setup
    }

    struct State: Codable, Equatable, Sendable {
        let projectID: String
        var base: Base?
        var draft: Draft?
    }

    struct Entry: Sendable {
        let state: State
        let baseURL: URL?
        let draftURL: URL?
    }

    enum DraftSource {
        case saved
        case shared(bundle: VMBundle, provenance: Provenance, script: String?)
    }

    enum Failure: LocalizedError, Equatable {
        case changed, notReady, hasDraft, invalidSelection

        var errorDescription: String? {
            switch self {
            case .changed: "The project base or draft changed. Refresh and try again."
            case .notReady: "The guest setup script must succeed before saving this draft."
            case .hasDraft: "Save or discard the draft before removing the project base."
            case .invalidSelection: "The saved project VM state could not be read."
            }
        }
    }

    private let directory: URL
    private let writeSelection: @Sendable (Data, URL) throws -> Void

    init(root: URL, writeSelection: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        directory = root.appendingPathComponent("project-bases", isDirectory: true)
        self.writeSelection = writeSelection
    }

    func status(projectID: String) throws -> State {
        let state = try Self.readState(in: slot(projectID)) ?? State(projectID: projectID)
        guard state.projectID == projectID else { throw Failure.invalidSelection }
        return state
    }

    /// Only a caller holding the registry lock may supply a recovery callback.
    func list(recoveringUnselected recover: ((URL, UUID?) -> Void)? = nil) throws -> [Entry] {
        guard try Self.fileType(at: directory) != nil else { return [] }
        return try withLock {
            var entries: [Entry] = []
            var unreadable: (any Error)?
            for slot in try Self.subdirectories(in: directory) {
                let name = slot.lastPathComponent.utf8
                guard name.count == 64, name.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
                do {
                    let state = try Self.readState(in: slot)
                    if let state {
                        guard slot.lastPathComponent == self.slot(state.projectID).lastPathComponent else { throw Failure.invalidSelection }
                        entries.append(Entry(state: state,
                            baseURL: state.base.map { Self.baseURL(in: slot, id: $0.id) },
                            draftURL: state.draft.map { Self.draftURL(in: slot, id: $0.id) }))
                    }
                    if let recover { try Self.visitUnselected(in: slot, state: state, recover) }
                } catch {
                    // Unreadable selection is not an empty selection. Leave this slot alone.
                    if recover == nil { throw error }
                    if unreadable == nil { unreadable = error }
                }
            }
            if let unreadable { throw unreadable }
            return entries
        }
    }

    /// The synchronous body holds the store lock through selection and any clone. A caller that
    /// also needs the VM registry must acquire it first. Never pass a Transaction out of the body.
    func withProject<T>(_ projectID: String, _ body: (inout Transaction) throws -> T) throws -> T {
        try withLock {
            var transaction = Transaction(state: try status(projectID: projectID), slot: slot(projectID), writeSelection: writeSelection)
            return try body(&transaction)
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent("state.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        return try body()
    }

    private func slot(_ projectID: String) -> URL {
        let name = SHA256.hash(data: Data(projectID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name, isDirectory: true)
    }

    private static func readState(in slot: URL) throws -> State? {
        guard let slotType = try fileType(at: slot) else { return nil }
        guard slotType == S_IFDIR else { throw Failure.invalidSelection }
        let file = slot.appendingPathComponent("state.json")
        guard let type = try fileType(at: file) else { return nil }
        guard type == S_IFREG else { throw Failure.invalidSelection }
        return try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
    }

    private static func fileType(at url: URL) throws -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            let error = errno
            if error == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        return info.st_mode & S_IFMT
    }

    private static func subdirectories(in parent: URL) throws -> [URL] {
        guard try fileType(at: parent) == S_IFDIR else { return [] }
        return try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .filter { try fileType(at: $0) == S_IFDIR }
    }

    private static func visitUnselected(in slot: URL, state: State?, _ body: (URL, UUID?) -> Void) throws {
        func visit(_ directory: String, selected: UUID?, drafts: Bool) throws {
            for url in try subdirectories(in: slot.appendingPathComponent(directory, isDirectory: true)) {
                let leaf = url.pathExtension == "partial" ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
                guard let id = UUID(uuidString: leaf), id != selected else { continue }
                body(url, drafts ? id : nil)
            }
        }
        try visit("bases", selected: state?.base?.id, drafts: false)
        try visit("drafts", selected: state?.draft?.id, drafts: true)
    }

    private static func baseURL(in slot: URL, id: UUID) -> URL {
        slot.appendingPathComponent("bases", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private static func draftURL(in slot: URL, id: UUID) -> URL {
        slot.appendingPathComponent("drafts", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    struct Transaction {
        private(set) var state: State
        fileprivate let slot: URL
        fileprivate let writeSelection: (Data, URL) throws -> Void

        func selectedDraftBundle(id: UUID) throws -> VMBundle {
            guard state.draft?.id == id else { throw Failure.changed }
            return VMBundle(url: ProjectVMBaseStore.draftURL(in: slot, id: id))
        }

        func cloneBase(to url: URL, identity: VMBundle.CloneIdentity) throws -> Base? {
            guard let base = state.base else { return nil }
            _ = try VMBundle.stageClone(from: baseBundle(base), to: url, identity: identity)
            return base
        }

        mutating func replaceDraft(expected: UUID?, source: DraftSource, identity: VMBundle.CloneIdentity) throws -> Draft {
            guard state.draft?.id == expected else { throw Failure.changed }
            let bundle: VMBundle
            let provenance: Provenance
            let script: String?
            switch source {
            case .saved:
                guard let base = state.base else { throw Failure.changed }
                bundle = try baseBundle(base)
                provenance = base.provenance
                script = nil
            case .shared(let source, let origin, let selectedScript):
                guard source.isSealed else { throw Failure.changed }
                bundle = source
                provenance = origin
                script = selectedScript
            }
            let draft = Draft(id: UUID(), createdAt: .now, provenance: provenance, script: script, setup: script == nil ? .ready : .pending)
            let destination = ProjectVMBaseStore.draftURL(in: slot, id: draft.id)
            try prepareSlot()
            _ = try VMBundle.stageClone(from: bundle, to: destination, identity: identity)
            do {
                var next = state
                next.draft = draft
                try commit(next)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            return draft
        }

        mutating func setDraftSetup(id: UUID, setup: Setup) throws {
            guard state.draft?.id == id else { throw Failure.changed }
            var next = state
            next.draft?.setup = setup
            try commit(next)
        }

        mutating func publish(expectedDraft: UUID, savedAt: Date) throws -> Base {
            guard let draft = state.draft, draft.id == expectedDraft else { throw Failure.changed }
            guard draft.setup == .ready else { throw Failure.notReady }
            let base = Base(id: UUID(), savedAt: savedAt, provenance: draft.provenance)
            let url = ProjectVMBaseStore.baseURL(in: slot, id: base.id)
            _ = try VMBundle.stageClone(from: selectedDraftBundle(id: draft.id), to: url, identity: nil)
            do {
                try JSONEncoder().encode(base).write(to: url.appendingPathComponent("base.json"))
                try commit(State(projectID: state.projectID, base: base, draft: nil))
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            return base
        }

        mutating func discard(expectedDraft: UUID) throws {
            guard state.draft?.id == expectedDraft else { throw Failure.changed }
            try commit(State(projectID: state.projectID, base: state.base, draft: nil))
        }

        mutating func removeBase(expectedBase: UUID) throws {
            guard state.base?.id == expectedBase else { throw Failure.changed }
            guard state.draft == nil else { throw Failure.hasDraft }
            try commit(State(projectID: state.projectID))
        }

        /// The caller holds the registry lock and decides which files are still referenced.
        func visitUnselected(_ body: (URL, UUID?) -> Void) throws {
            try ProjectVMBaseStore.visitUnselected(in: slot, state: state, body)
        }

        private func baseBundle(_ base: Base) throws -> VMBundle {
            let url = ProjectVMBaseStore.baseURL(in: slot, id: base.id)
            let metadata = try JSONDecoder().decode(Base.self, from: Data(contentsOf: url.appendingPathComponent("base.json")))
            guard metadata == base else { throw Failure.invalidSelection }
            return VMBundle(url: url)
        }

        private func prepareSlot() throws {
            try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        private mutating func commit(_ next: State) throws {
            try writeSelection(JSONEncoder().encode(next), slot.appendingPathComponent("state.json"))
            state = next
        }
    }
}
