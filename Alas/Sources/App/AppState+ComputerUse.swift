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
        switch vmRoute(worktreeID: worktreeID, requested: command.vm) {
        case .desktop:
            return await computerUse.perform(command, sessionID: sessionID)
        case .ambiguous:
            return .error(VMComputerUseRoute.vmAmbiguousMessage)
        case .vmMissing(let guest):
            return .error(VMComputerUseRoute.vmMissingMessage(for: guest))
        case .vmNotRunning(_, let guest):
            // A VM record on Intel came with data migrated from Apple silicon; it can't run here.
            guard WorktreeVMManager.isSupported else { return .error(VMComputerUseRoute.vmUnsupportedMessage) }
            return .error(guest == .linux ? VMComputerUseRoute.linuxVMNotRunningMessage : VMComputerUseRoute.vmNotRunningMessage)
        case .vmStateUnreadable:
            return .error(VMComputerUseRoute.vmStateUnreadableMessage)
        case .guest(let worktreeID, let guest):
            if vmStoppedSessions.contains(sessionID) || computerUse.isStopped(sessionID: sessionID) {
                return .error(ComputerUseCoordinator.stoppedMessage)
            }
            guard let client = vmManager.guestClient(for: worktreeID, guest: guest) else {
                return .error(guest == .linux ? VMComputerUseRoute.linuxVMNotRunningMessage : VMComputerUseRoute.vmNotRunningMessage)
            }
            if guest == .linux {
                // A helper from before computer use only runs commands; its hello says so.
                do {
                    let hello = try await client.hello()
                    if let refusal = VMComputerUseRoute.linuxComputerUse(capabilities: hello.capabilities).refusal {
                        return .error(refusal)
                    }
                } catch {
                    return .error((error as? VMGuestClient.Failure ?? .stopped).message(for: .linux))
                }
            }
            vmComputerUseSessions[sessionID] = VMIdentity.recordID(worktree: worktreeID, guest: guest)
            if vmPendingResumes.contains(sessionID) {
                // Connects first, so the resume goes out ahead of the call on the same connection.
                _ = try? await client.hello()
                if await client.lifecycle(.resume, sessionID: sessionID) { vmPendingResumes.remove(sessionID) }
            }
            // Awaited in the request's own task, so a client disconnect cancels it and the
            // client tells the guest to cancel the call.
            let response = await client.perform(command, sessionID: sessionID, guest: guest)
            // The badge shows a session using its VM only once the guest has done something for
            // it, and not again for a session the user stopped during the call.
            let failed = if case .error = response { true } else { false }
            if command.action != .cancel, !failed, !vmStoppedSessions.contains(sessionID) {
                vmDrivingSessions.insert(sessionID)
            }
            return response
        }
    }

    /// The route a VM tool call takes: a running VM of the named guest answers without touching
    /// the registry, otherwise one lockless registry read.
    private func vmRoute(worktreeID: String?, requested: VMGuestOS?) -> VMComputerUseRoute {
        VMComputerUseRoute.resolve(
            worktreeID: worktreeID,
            kinds: worktreeID.flatMap { vmManager.vmKinds(forWorktree: $0) },
            requested: requested,
            runningHere: { [vmManager] guest in worktreeID.map { vmManager.running($0, guest: guest) != nil } ?? false }
        )
    }

    /// `vm_run`: runs a shell command in the guest of the session's worktree VM. A session the
    /// user stopped can't use it until resumed, like the computer tools.
    func performVMRun(
        _ command: String, timeoutSeconds: Int, vm: VMGuestOS?, sessionID: String, worktreeID: String?
    ) async -> AlasCLIResponse {
        guard WorktreeVMManager.isSupported else { return .error(VMComputerUseRoute.vmUnsupportedMessage) }
        switch vmRoute(worktreeID: worktreeID, requested: vm) {
        case .desktop:
            return .error(VMComputerUseRoute.vmMissingMessage)
        case .vmMissing(let guest):
            return .error(VMComputerUseRoute.vmMissingMessage(for: guest))
        case .ambiguous:
            return .error(VMComputerUseRoute.vmAmbiguousMessage)
        case .vmNotRunning(_, let guest):
            return .error(guest == .linux ? VMComputerUseRoute.linuxVMNotRunningMessage : VMComputerUseRoute.vmNotRunningMessage)
        case .vmStateUnreadable:
            return .error(VMComputerUseRoute.vmStateUnreadableMessage)
        case .guest(let worktreeID, let guest):
            if vmStoppedSessions.contains(sessionID) || computerUse.isStopped(sessionID: sessionID) {
                return .error(ComputerUseCoordinator.stoppedMessage)
            }
            guard let client = vmManager.guestClient(for: worktreeID, guest: guest) else {
                return .error(guest == .linux ? VMComputerUseRoute.linuxVMNotRunningMessage : VMComputerUseRoute.vmNotRunningMessage)
            }
            // Awaited in the request's own task, so a client disconnect cancels the guest call.
            do {
                return .text([VMComputerUseRoute.runReply(try await client.run(command, timeoutSeconds: timeoutSeconds))])
            } catch {
                return .error((error as? VMGuestClient.Failure ?? .stopped).message(for: guest))
            }
        }
    }

    /// `vm_status`: whether the session's worktree has a VM, whether it runs here, its guest
    /// helper (or why it doesn't answer), and the transfer folder. With both VMs and no `vm`
    /// named, one such status per VM under `vms`.
    func vmStatus(worktreeID: String?, vm: VMGuestOS?) async -> AlasCLIResponse {
        guard WorktreeVMManager.isSupported else { return .error(VMComputerUseRoute.vmUnsupportedMessage) }
        switch vmRoute(worktreeID: worktreeID, requested: vm) {
        case .vmMissing(let guest):
            return .error(VMComputerUseRoute.vmMissingMessage(for: guest))
        case .ambiguous:
            var vms: [VMComputerUseRoute.VMStatusEntry] = []
            for guest in [VMGuestOS.macOS, .linux] {
                let route = vmRoute(worktreeID: worktreeID, requested: guest)
                vms.append((guest, route, await vmHelperStatus(route), vmTransferHostPath(route)))
            }
            return .text([VMComputerUseRoute.statusReply(vms: vms)])
        case let route:
            return .text([VMComputerUseRoute.statusReply(
                route: route, helper: await vmHelperStatus(route), transferHostPath: vmTransferHostPath(route)
            )])
        }
    }

    /// The guest helper's hello for a VM running here, or why it doesn't answer.
    private func vmHelperStatus(_ route: VMComputerUseRoute) async -> Result<VMGuestHello, VMGuestClient.Failure>? {
        guard case .guest(let id, let guest) = route, let client = vmManager.guestClient(for: id, guest: guest) else {
            return nil
        }
        let helper: Result<VMGuestHello, VMGuestClient.Failure>
        do {
            helper = .success(try await client.status())
        } catch {
            helper = .failure(error as? VMGuestClient.Failure ?? .stopped)
        }
        // The VM tab offers Update helper for an outdated one. A missing
        // one may still be starting: the tab's own check waits for it.
        if case .success(let hello) = helper {
            vmManager.noteHelperCheck(VMIdentity.recordID(worktree: id, guest: guest), .success(hello))
        }
        return helper
    }

    /// The host side of the transfer folder of a VM known to exist; empty otherwise.
    private func vmTransferHostPath(_ route: VMComputerUseRoute) -> String {
        switch route {
        case .guest(let id, let guest), .vmNotRunning(let id, let guest):
            // Made at VM start; made here too so a copy before the first start lands.
            let directory = vmManager.transferDirectory(forWorktree: id, guest: guest)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.path
        case .desktop, .vmStateUnreadable, .vmMissing, .ambiguous:
            return ""
        }
    }

    /// Whether the badge shows a session as driving its VM.
    func isDrivingVM(sessionID: String) -> Bool { vmDrivingSessions.contains(sessionID) }

    /// The badge's Stop: a VM session stops in its guest, the rest on the host.
    func stopComputerUse(sessionID: String) async {
        guard vmDrivingSessions.contains(sessionID), let recordID = vmComputerUseSessions[sessionID] else {
            await computerUse.stop(sessionID: sessionID)
            return
        }
        vmStoppedSessions.insert(sessionID)
        vmDrivingSessions.remove(sessionID)
        vmPendingResumes.remove(sessionID)
        let vm = VMIdentity.parse(recordID: recordID)
        await vmManager.guestClient(for: vm.worktree, guest: vm.guest)?.lifecycle(.stop, sessionID: sessionID)
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
        guard let recordID = vmComputerUseSessions[sessionID],
              let client = vmManager.existingGuestClient(for: recordID) else { return }
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
        guard case .worktree(let worktreeID) = owner, let recordID = vmComputerUseSessions[sessionID],
              VMIdentity.parse(recordID: recordID).worktree == worktreeID,
              let client = vmManager.existingGuestClient(for: recordID) else { return }
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
