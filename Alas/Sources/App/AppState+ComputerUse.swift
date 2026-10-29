import AlasComputerUseKit
import AppKit
import Darwin
import Foundation
import Observation

/// Lets objects built before `AppState` finishes initializing call back into it.
@MainActor
final class AppStateLink {
    weak var state: AppState?
}

extension AppState {
    static func makeComputerUse(link: AppStateLink) -> ComputerUseCoordinator {
        let access = ComputerUseAccess(hostPID: getpid(), alwaysAllowed: {
            Set(link.state?.config.computerUse.alwaysAllowedApps ?? [])
        })
        // One overlay for the app's lifetime: the coordinator's cursor closures keep it, and
        // dismiss it whenever the session that showed it ends.
        // One system for both: the overlay looks windows up through it, and its drags look through
        // the overlay. `overlayRef` is set once, here, before any call can reach a drag.
        nonisolated(unsafe) var overlayRef: ComputerUseCursorOverlay?
        let system = ComputerUseSystem.live(cursorWindowIDs: { overlayRef?.windowIDs ?? [] })
        let overlay = ComputerUseCursorOverlay(window: system.window)
        overlayRef = overlay
        let cursor = ComputerUseCursor(
            present: { overlay.present(over: $0) },
            perform: { await overlay.perform($0) },
            dismiss: { overlay.dismiss() }
        )
        let coordinator = ComputerUseCoordinator(
            system: system,
            access: access,
            readiness: {
                ComputerUseReadiness.evaluate(
                    enabled: link.state?.config.computerUse.enabled ?? false,
                    granted: ComputerUsePlatform.shared.grantedPermissions()
                )
            },
            sessionLabel: { link.state?.computerUseSessionLabel($0) ?? $0 },
            persistAlwaysAllowed: { link.state?.persistComputerUseAlwaysAllowed($0) },
            interrupt: { sessionID in
                try? await link.state?.host.sessions.stop(sessionID, caller: .app)
            },
            cursor: cursor,
            // Only bounces the Dock icon while Alas isn't the active app.
            attention: { _ = NSApp.requestUserAttention(.informationalRequest) },
            appIsActive: { NSApp.isActive }
        )
        coordinator.transcript = { link.state?.session(for: $0)?.transcript }
        coordinator.autoRun = { link.state?.session(for: $0)?.autoRunEnabled ?? false }
        coordinator.autoRunAllowed = { sessionID, app in
            let notice = ComputerUseCoordinator.autoRunNotice(appName: app.name)
            // Through the session's runner, so the line is persisted and survives a reload.
            link.state?.acpManager(forSession: sessionID)?.runners[sessionID]?.appendAndPersistSystemNotice(notice)
        }
        return coordinator
    }

    /// "<Agent display name> · <session title>", or the id when the session is gone.
    func computerUseSessionLabel(_ sessionID: String) -> String {
        guard let session = session(for: sessionID) else { return sessionID }
        let agent = agent(id: session.agentId)?.displayName ?? session.agentId
        return "\(agent) · \(session.title)"
    }

    func persistComputerUseAlwaysAllowed(_ bundleID: String) {
        guard !config.computerUse.alwaysAllowedApps.contains(bundleID) else { return }
        config.computerUse.alwaysAllowedApps.append(bundleID)
        saveConfig()
    }

    /// Installs the menu-bar item that follows `computerUse.driver`.
    func startComputerUseStatusItem() {
        let item = ComputerUseStatusItem(
            coordinator: computerUse,
            agentName: { [weak self] id in
                guard let self, let session = self.session(for: id) else { return "An agent" }
                return self.agent(id: session.agentId)?.displayName ?? session.agentId
            },
            showSession: { [weak self] in self?.showComputerUseSession($0) },
            stopShortcutWarning: { [weak self] in self?.computerUseStopHotKey?.unavailableReason },
            retryStopShortcut: { [weak self] in self?.computerUseStopHotKey?.retryIfTaken() },
            stopShortcut: { [weak self] in self?.binding(for: .stopComputerUse) }
        )
        computerUseStatusItem = item
        item.start()
    }

    /// Installs the system-wide Stop Computer Use shortcut, live only while an agent drives.
    func startComputerUseStopHotKey() {
        computerUseStopHotKey = ComputerUseStopHotKey { [weak self] in
            // Same as the status item's Stop: the session driving right now.
            guard let self, let sessionID = self.computerUse.driver?.sessionID else { return }
            Task { await self.computerUse.stop(sessionID: sessionID) }
        }
        // Once per registration request (`ComputerUseStopHotKey.update`), which is once per drive
        // unless the binding changes mid-drive; retries never post.
        computerUseStopHotKey?.onTaken = { [weak self] binding in
            guard let self, let sessionID = self.computerUse.driver?.sessionID else { return }
            self.acpManager(forSession: sessionID)?.runners[sessionID]?
                .appendAndPersistSystemNotice(ComputerUseStopHotKey.takenNotice(binding))
        }
        syncComputerUseStopHotKey()
    }

    /// Follows the driver and the user's binding; re-arms observation on every change.
    private func syncComputerUseStopHotKey() {
        let registration = withObservationTracking {
            ComputerUseStopShortcut.registration(
                binding: binding(for: .stopComputerUse),
                driverActive: computerUse.driver != nil
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.syncComputerUseStopHotKey() }
        }
        computerUseStopHotKey?.update(registration)
    }

    // MARK: - VM sessions

    /// Routes one call: a session whose worktree has a VM talks to its guest and never reaches
    /// the host coordinator, so no host readiness, approvals, driver lock, or overlay apply.
    func performComputerUse(_ command: ComputerUseCommand, sessionID: String, worktreeID: String?) async -> AlasCLIResponse {
        // A running VM answers without a registry read.
        let runningHere = worktreeID.map { vmManager.running($0) != nil } ?? false
        let hasVM = runningHere || (worktreeID.map(vmManager.hasVM) ?? false)
        switch VMComputerUseRoute.resolve(worktreeID: worktreeID, hasVM: hasVM, runningHere: runningHere) {
        case .desktop:
            return await computerUse.perform(command, sessionID: sessionID)
        case .vmNotRunning:
            return .error(VMComputerUseRoute.vmNotRunningMessage)
        case .guest(let worktreeID):
            if vmStoppedSessions.contains(sessionID) || computerUse.isStopped(sessionID: sessionID) {
                return .error(ComputerUseCoordinator.stoppedMessage)
            }
            guard let client = vmManager.guestClient(for: worktreeID) else {
                return .error(VMComputerUseRoute.vmNotRunningMessage)
            }
            if command.action != .cancel { vmComputerUseSessions[sessionID] = worktreeID }
            // Awaited in the request's own task, so a client disconnect cancels it and the
            // client tells the guest to cancel the call.
            return await client.perform(command, sessionID: sessionID)
        }
    }

    /// Whether the badge shows a session as driving its VM.
    func isDrivingVM(sessionID: String) -> Bool { vmComputerUseSessions[sessionID] != nil }

    /// The badge's Stop: a VM session stops in its guest, the rest on the host.
    func stopComputerUse(sessionID: String) async {
        guard let worktreeID = vmComputerUseSessions[sessionID] else {
            await computerUse.stop(sessionID: sessionID)
            return
        }
        vmStoppedSessions.insert(sessionID)
        vmComputerUseSessions[sessionID] = nil
        await vmManager.guestClient(for: worktreeID)?.lifecycle(.stop, sessionID: sessionID)
        try? await host.sessions.stop(sessionID, caller: .app)
    }

    /// The badge's Resume, for whichever side stopped the session.
    func resumeComputerUse(sessionID: String) {
        computerUse.resume(sessionID: sessionID)
        guard vmStoppedSessions.remove(sessionID) != nil else { return }
        guard case .worktree(let worktreeID)? = host.callers.owner(ofSession: sessionID),
              let client = vmManager.guestClient(for: worktreeID) else { return }
        Task { await client.lifecycle(.resume, sessionID: sessionID) }
    }

    func computerUseTurnEnded(sessionID: String, owner: SessionOwnerID) {
        computerUse.turnEnded(sessionID: sessionID)
        vmComputerUseSessions[sessionID] = nil
        forwardVMLifecycle(.turnEnded, sessionID: sessionID, owner: owner)
    }

    func computerUseSessionEnded(sessionID: String, owner: SessionOwnerID) {
        computerUse.sessionEnded(sessionID: sessionID)
        vmComputerUseSessions[sessionID] = nil
        forwardVMLifecycle(.sessionEnded, sessionID: sessionID, owner: owner)
    }

    private func forwardVMLifecycle(_ event: VMGuestLifecycleEvent, sessionID: String, owner: SessionOwnerID) {
        guard case .worktree(let worktreeID) = owner, let client = vmManager.guestClient(for: worktreeID) else { return }
        Task { await client.lifecycle(event, sessionID: sessionID) }
    }

    func showComputerUseSession(_ sessionID: String) {
        guard let owner = acpOwner(forSession: sessionID) else { return }
        switch owner {
        case .worktree:
            guard let location = harnessSessionLocation(sessionId: sessionID) else { return }
            activateHarnessSession(projectId: location.projectId, worktreeId: location.worktreeId, sessionId: sessionID)
        case .workspaceCheckout:
            activateHarnessSession(owner: owner, sessionId: sessionID)
        }
    }
}
