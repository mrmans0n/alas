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
        switch vmRoute(worktreeID: worktreeID) {
        case .desktop:
            return await computerUse.perform(command, sessionID: sessionID)
        case .vmNotRunning:
            return .error(VMComputerUseRoute.vmNotRunningMessage)
        case .vmStateUnreadable:
            return .error(VMComputerUseRoute.vmStateUnreadableMessage)
        case .guest(let worktreeID):
            if vmStoppedSessions.contains(sessionID) || computerUse.isStopped(sessionID: sessionID) {
                return .error(ComputerUseCoordinator.stoppedMessage)
            }
            guard let client = vmManager.guestClient(for: worktreeID) else {
                return .error(VMComputerUseRoute.vmNotRunningMessage)
            }
            vmComputerUseSessions[sessionID] = worktreeID
            if vmPendingResumes.contains(sessionID) {
                // Connects first, so the resume goes out ahead of the call on the same connection.
                _ = try? await client.hello()
                if await client.lifecycle(.resume, sessionID: sessionID) { vmPendingResumes.remove(sessionID) }
            }
            // Awaited in the request's own task, so a client disconnect cancels it and the
            // client tells the guest to cancel the call.
            let response = await client.perform(command, sessionID: sessionID)
            // The badge shows a session using its VM only once the guest has done something for
            // it, and not again for a session the user stopped during the call.
            let failed = if case .error = response { true } else { false }
            if command.action != .cancel, !failed, !vmStoppedSessions.contains(sessionID) {
                vmDrivingSessions.insert(sessionID)
            }
            return response
        }
    }

    /// The route a VM tool call takes: a running VM answers without touching the registry,
    /// otherwise one lockless registry read.
    private func vmRoute(worktreeID: String?) -> VMComputerUseRoute {
        let runningHere = worktreeID.map { vmManager.running($0) != nil } ?? false
        let hasVM: Bool? = runningHere ? true : worktreeID.map(vmManager.hasVMRecord) ?? false
        return VMComputerUseRoute.resolve(worktreeID: worktreeID, hasVM: hasVM, runningHere: runningHere)
    }

    /// `vm_run`: runs a shell command in the guest of the session's worktree VM. A session the
    /// user stopped can't use it until resumed, like the computer tools.
    func performVMRun(_ command: String, timeoutSeconds: Int, sessionID: String, worktreeID: String?) async -> AlasCLIResponse {
        switch vmRoute(worktreeID: worktreeID) {
        case .desktop:
            return .error(VMComputerUseRoute.vmMissingMessage)
        case .vmNotRunning:
            return .error(VMComputerUseRoute.vmNotRunningMessage)
        case .vmStateUnreadable:
            return .error(VMComputerUseRoute.vmStateUnreadableMessage)
        case .guest(let worktreeID):
            if vmStoppedSessions.contains(sessionID) || computerUse.isStopped(sessionID: sessionID) {
                return .error(ComputerUseCoordinator.stoppedMessage)
            }
            guard let client = vmManager.guestClient(for: worktreeID) else {
                return .error(VMComputerUseRoute.vmNotRunningMessage)
            }
            // Awaited in the request's own task, so a client disconnect cancels the guest call.
            do {
                return .text([VMComputerUseRoute.runReply(try await client.run(command, timeoutSeconds: timeoutSeconds))])
            } catch {
                return .error((error as? VMGuestClient.Failure ?? .stopped).message)
            }
        }
    }

    /// `vm_status`: whether the session's worktree has a VM, whether it runs here, its guest
    /// helper (or why it doesn't answer), and the transfer folder.
    func vmStatus(worktreeID: String?) async -> AlasCLIResponse {
        let route = vmRoute(worktreeID: worktreeID)
        var helper: Result<VMGuestHello, VMGuestClient.Failure>?
        if case .guest(let id) = route, let client = vmManager.guestClient(for: id) {
            do {
                helper = .success(try await client.hello())
            } catch {
                helper = .failure(error as? VMGuestClient.Failure ?? .stopped)
            }
        }
        var transfer = ""
        switch route {
        case .guest(let id), .vmNotRunning(let id):
            // Made at VM start; made here too so a copy before the first start lands.
            let directory = vmManager.transferDirectory(forWorktree: id)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            transfer = directory.path
        case .desktop, .vmStateUnreadable:
            break
        }
        return .text([VMComputerUseRoute.statusReply(route: route, helper: helper, transferHostPath: transfer)])
    }

    /// Whether the badge shows a session as driving its VM.
    func isDrivingVM(sessionID: String) -> Bool { vmDrivingSessions.contains(sessionID) }

    /// The badge's Stop: a VM session stops in its guest, the rest on the host.
    func stopComputerUse(sessionID: String) async {
        guard vmDrivingSessions.contains(sessionID), let worktreeID = vmComputerUseSessions[sessionID] else {
            await computerUse.stop(sessionID: sessionID)
            return
        }
        vmStoppedSessions.insert(sessionID)
        vmDrivingSessions.remove(sessionID)
        vmPendingResumes.remove(sessionID)
        await vmManager.guestClient(for: worktreeID)?.lifecycle(.stop, sessionID: sessionID)
        if computerUse.driver?.sessionID == sessionID {
            // Also driving the desktop: the host's stop releases it and interrupts the session.
            await computerUse.stop(sessionID: sessionID)
        } else {
            try? await host.sessions.stop(sessionID, caller: .app)
        }
    }

    /// The badge's Resume, for whichever side stopped the session. A guest that can't be told
    /// now is told before the session's next guest call.
    func resumeComputerUse(sessionID: String) {
        computerUse.resume(sessionID: sessionID)
        guard vmStoppedSessions.remove(sessionID) != nil else { return }
        vmPendingResumes.insert(sessionID)
        guard let worktreeID = vmComputerUseSessions[sessionID],
              let client = vmManager.existingGuestClient(for: worktreeID) else { return }
        Task {
            if await client.lifecycle(.resume, sessionID: sessionID) { vmPendingResumes.remove(sessionID) }
        }
    }

    func computerUseTurnEnded(sessionID: String, owner: SessionOwnerID) {
        computerUse.turnEnded(sessionID: sessionID)
        vmDrivingSessions.remove(sessionID)
        forwardVMLifecycle(.turnEnded, sessionID: sessionID, owner: owner)
    }

    func computerUseSessionEnded(sessionID: String, owner: SessionOwnerID) {
        computerUse.sessionEnded(sessionID: sessionID)
        vmDrivingSessions.remove(sessionID)
        forwardVMLifecycle(.sessionEnded, sessionID: sessionID, owner: owner)
        vmComputerUseSessions[sessionID] = nil
    }

    /// Only for sessions that used the guest of this owner's VM, and only over a client that exists.
    private func forwardVMLifecycle(_ event: VMGuestLifecycleEvent, sessionID: String, owner: SessionOwnerID) {
        guard case .worktree(let worktreeID) = owner, vmComputerUseSessions[sessionID] == worktreeID,
              let client = vmManager.existingGuestClient(for: worktreeID) else { return }
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
