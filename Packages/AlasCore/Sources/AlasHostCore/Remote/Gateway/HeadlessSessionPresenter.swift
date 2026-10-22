import Foundation
import os
import AlasFoundation
import AlasModel
import AlasAgents
import AlasSessions
import AlasACP

private let presenterLogger = Logger(subsystem: "io.nlopez.alas", category: "HeadlessSessionPresenter")

/// The sessions a headless host shows as open, keyed by the owning
/// worktree's `SessionOwnerID.storageKey`, in open order.
public struct HostOpenSessionsFile: Codable, Equatable {
    public var sessions: [String: [String]]
}

/// Stands in for the app's tabs on a headless host: paired clients only
/// select sessions reported open, so the host keeps its own persisted list.
/// Only worktree owners for now.
@_spi(AppHost) @MainActor
public final class HeadlessSessionPresenter: RemoteSessionPresenter {
    private let core: AlasCoreContext
    private let store: any PersistenceStoreProtocol
    private let fileURL: URL
    /// Open session ids by worktree id, which is that owner's storage key.
    private var open: [String: [String]] = [:]
    private var actionTails: [String: (token: UUID, done: Task<Void, Never>)] = [:]

    public let sessionListChanges: ChangeSignal<Void>? = ChangeSignal()
    public var peerConsoleHost: PeerConsoleHost? { nil }

    public init(core: AlasCoreContext, store: any PersistenceStoreProtocol = PersistenceStore(), fileURL: URL = Paths.hostOpenSessionsFile) {
        self.core = core
        self.store = store
        self.fileURL = fileURL
    }

    /// Loads the saved list, keeping only sessions whose worktree is still a
    /// configured local one and whose stored row is still there, unarchived.
    public func restore() async {
        let saved: [String: [String]]
        do {
            saved = try store.readIfExists(HostOpenSessionsFile.self, from: fileURL)?.sessions ?? [:]
        } catch {
            presenterLogger.error("Could not read open sessions: \(String(describing: error), privacy: .public)")
            return
        }
        var kept: [String: [String]] = [:]
        for (worktreeID, ids) in saved {
            guard let manager = localManager(worktreeID) else { continue }
            for id in ids {
                do {
                    guard let row = try await manager.persistence.loadSession(id: id), !row.archived else { continue }
                } catch {
                    // A read error keeps the entry; only a known-gone row drops it.
                }
                kept[worktreeID, default: []].append(id)
            }
        }
        open = kept
        if kept != saved { save() }
    }

    public func sessionTabIndex(_ id: String, owner: SessionOwnerID) -> Int? {
        open[owner.storageKey]?.firstIndex(of: id)
    }

    public func openSessionTab(for id: String) async -> RemoteSessionTabActionResult {
        await serialized(id) { await self.openNow(id) }
    }

    public func closeSessionTab(for id: String) async -> RemoteSessionTabActionResult {
        await serialized(id) { await self.closeNow(id) }
    }

    public func sessionRenamed(_ id: String, title: String) {}

    public func sessionCreated(_ id: String, worktreeID: String) {
        guard open[worktreeID]?.contains(id) != true else { return }
        open[worktreeID, default: []].append(id)
        save()
        sessionListChanges?.send()
    }

    /// Runs actions for one session one at a time, as the app's
    /// `serializedSessionTabAction` does, so a close cannot report success
    /// while an earlier open is still about to add the session.
    private func serialized(
        _ id: String,
        _ action: @escaping @MainActor () async -> RemoteSessionTabActionResult
    ) async -> RemoteSessionTabActionResult {
        let previous = actionTails[id]?.done
        let token = UUID()
        let run = Task { @MainActor in
            await previous?.value
            return await action()
        }
        actionTails[id] = (token, Task { _ = await run.value })
        let result = await run.value
        if actionTails[id]?.token == token { actionTails[id] = nil }
        return result
    }

    private func openNow(_ id: String) async -> RemoteSessionTabActionResult {
        guard let worktreeID = await worktreeID(of: id) else { return .failure("This session is no longer available.") }
        guard let manager = localManager(worktreeID) else {
            return .failure("This session's worktree is no longer available.")
        }
        // Only a fresh, unarchived stored row may be opened; queued writes
        // such as a new session's upsert land first.
        await manager.flushPersistence()
        let stored: ACPSessionRow?
        do {
            stored = try await manager.persistence.loadSession(id: id)
        } catch {
            return .failure("Could not read this session.")
        }
        // Checked even when it is open already: a session archived or
        // deleted since leaves the list instead of reopening.
        guard let stored, !stored.archived else {
            drop(id, from: worktreeID)
            return .failure(stored == nil ? "This session is no longer available." : "This session is archived.")
        }
        // Already open, or a `sessionCreated` added it during the awaits above.
        if open[worktreeID]?.contains(id) == true { return .success }
        open[worktreeID, default: []].append(id)
        save()
        sessionListChanges?.send()
        return .success
    }

    private func closeNow(_ id: String) async -> RemoteSessionTabActionResult {
        guard let worktreeID = open.first(where: { $0.value.contains(id) })?.key else { return .success }
        drop(id, from: worktreeID)
        // As the app's tab close: dispose the runner, keep the row in history.
        if let manager = core.sessionManagers[.worktree(worktreeID)], manager.liveSession(for: id) != nil {
            manager.flushPendingDraftWrite(forSession: id)
            do {
                try await manager.disposeSession(id: id)
            } catch {
                presenterLogger.error("Could not close session: \(String(describing: error), privacy: .public)")
            }
        }
        return .success
    }

    /// Takes `id` out of the worktree's open sessions, if it is there.
    private func drop(_ id: String, from worktreeID: String) {
        guard open[worktreeID]?.contains(id) == true else { return }
        open[worktreeID]?.removeAll { $0 == id }
        if open[worktreeID]?.isEmpty == true { open[worktreeID] = nil }
        save()
        sessionListChanges?.send()
    }

    /// The worktree whose sessions include `id`: one a loaded manager lists,
    /// else the first configured local worktree whose store has its row.
    private func worktreeID(of id: String) async -> String? {
        for (owner, manager) in core.sessionManagers {
            guard let worktreeID = owner.worktreeID else { continue }
            if manager.liveSession(for: id) != nil || manager.sessionRows.contains(where: { $0.id == id }) {
                return worktreeID
            }
        }
        for project in core.projects.projects where project.host == nil {
            for worktree in core.projects.worktrees(projectId: project.id) {
                // Skip worktrees with no sessions rather than load a manager for each.
                guard FileManager.default.fileExists(atPath: Paths.acpSessionsDB(for: .worktree(worktree.id)).path),
                      let manager = localManager(worktree.id),
                      (try? await manager.persistence.loadSession(id: id)) != nil
                else { continue }
                return worktree.id
            }
        }
        return nil
    }

    /// The session manager of a configured local worktree, created on first
    /// use. None for an archived worktree, whose sessions stay closed.
    private func localManager(_ worktreeID: String) -> ACPSessionManager? {
        guard let (project, worktree) = core.projectAndWorktree(withWorktreeId: worktreeID), project.host == nil,
              !core.projects.isWorktreeHidden(projectId: project.id, path: worktree.path)
        else { return nil }
        return try? core.sessionManager(for: worktree)
    }

    private func save() {
        do {
            try store.write(HostOpenSessionsFile(sessions: open), to: fileURL)
        } catch {
            presenterLogger.error("Could not save open sessions: \(String(describing: error), privacy: .public)")
        }
    }
}
