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
            agentName: { [weak self] in self?.computerUseAgentName($0) ?? "An agent" },
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
    /// `autoStarted` is set on the pass after this call started its VM.
    func performComputerUse(
        _ command: ComputerUseCommand, sessionID: String, worktreeID: String?, autoStarted: Bool = false
    ) async -> AlasCLIResponse {
        switch vmRoute(worktreeID: worktreeID, requested: command.vm) {
        case .desktop:
            return await computerUse.perform(command, sessionID: sessionID)
        case .ambiguous:
            return .error(VMComputerUseRoute.vmAmbiguousMessage)
        case .vmMissing(let guest):
            return .error(VMComputerUseRoute.vmMissingMessage(for: guest))
        case .vmNotRunning(let worktreeID, let guest):
            // A VM record on Intel came with data migrated from Apple silicon; it can't run here.
            guard WorktreeVMManager.isSupported else { return .error(VMComputerUseRoute.vmUnsupportedMessage) }
            // A VM running in no Alas is started, then the call continues through the driver gate.
            if let refusal = await autoStartRefusal(
                worktreeID: worktreeID, guest: guest, sessionID: sessionID, call: .computer, autoStarted: autoStarted
            ) {
                return .error(refusal)
            }
            return await performComputerUse(command, sessionID: sessionID, worktreeID: worktreeID, autoStarted: true)
        case .vmStateUnreadable:
            return .error(VMComputerUseRoute.vmStateUnreadableMessage)
        case .guest(let worktreeID, let guest):
            if vmStoppedSessions.contains(sessionID) || computerUse.isStopped(sessionID: sessionID) {
                return .error(ComputerUseCoordinator.stoppedMessage)
            }
            let recordID = VMIdentity.recordID(worktree: worktreeID, guest: guest)
            if let refusal = await joinedStartRefusal(recordID: recordID, guest: guest, sessionID: sessionID, call: .computer) {
                return .error(refusal)
            }
            guard let client = vmManager.guestClient(for: worktreeID, guest: guest) else {
                return .error(guest == .linux ? VMComputerUseRoute.linuxVMNotRunningMessage : VMComputerUseRoute.vmNotRunningMessage)
            }
            if guest == .linux {
                // A helper from before computer use only runs commands; its hello says so.
                // A current one that can't yet may still be starting its driver, so it is asked again.
                do {
                    let hello = try await client.hello()
                    if let refusal = await VMComputerUseRoute.linuxComputerUseRefusal(
                        hello: hello, refresh: { try await client.status() }
                    ) {
                        return .error(refusal)
                    }
                } catch {
                    return .error((error as? VMGuestClient.Failure ?? .stopped).message(for: .linux))
                }
                // The user may have stopped the session while it waited.
                if vmStoppedSessions.contains(sessionID) || computerUse.isStopped(sessionID: sessionID) {
                    return .error(ComputerUseCoordinator.stoppedMessage)
                }
            }
            // A refused call didn't drive the VM, so it is neither recorded nor told about lifecycles.
            if let refusal = VMTakeOvers.refusal(action: command.action, driver: vmDriver(recordID: recordID)) {
                return .error(refusal)
            }
            if command.action != .cancel {
                vmLastAgentCall.begin(recordID, (sessionID, "computer_\(command.action.rawValue)", vmNow()))
            }
            // The VM shows the agent driving for the whole call, and the window after it ends.
            defer { if command.action != .cancel { vmLastAgentCall.end(recordID, at: vmNow()) } }
            vmComputerUseSessions[sessionID, default: []].insert(recordID)
            if vmPendingResumes[sessionID]?.contains(recordID) == true {
                // Connects first, so the resume goes out ahead of the call on the same connection.
                _ = try? await client.hello()
                // The user may have taken the VM over while it connected; a resume would undo the stop.
                if let refusal = VMTakeOvers.refusal(action: command.action, driver: vmDriver(recordID: recordID)) {
                    return .error(refusal)
                }
                if await client.lifecycle(.resume, sessionID: sessionID) { resumeTold(sessionID, recordID) }
            }
            // Nothing goes to a VM the user took over since the gate.
            if let refusal = VMTakeOvers.refusal(action: command.action, driver: vmDriver(recordID: recordID)) {
                return .error(refusal)
            }
            // Awaited in the request's own task, so a client disconnect cancels it and the
            // client tells the guest to cancel the call.
            let performed = await client.perform(command, sessionID: sessionID, guest: guest)
            let response = VMTakeOvers.afterCall(
                action: command.action, takenOver: vmTakenOver.contains(recordID), response: performed
            )
            // Taken over mid-call: the badge must not show the agent driving.
            if response != performed { return response }
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
        _ command: String, timeoutSeconds: Int, vm: VMGuestOS?, sessionID: String, worktreeID: String?,
        autoStarted: Bool = false
    ) async -> AlasCLIResponse {
        guard WorktreeVMManager.isSupported else { return .error(VMComputerUseRoute.vmUnsupportedMessage) }
        switch vmRoute(worktreeID: worktreeID, requested: vm) {
        case .desktop:
            return .error(VMComputerUseRoute.vmMissingMessage)
        case .vmMissing(let guest):
            return .error(VMComputerUseRoute.vmMissingMessage(for: guest))
        case .ambiguous:
            return .error(VMComputerUseRoute.vmAmbiguousMessage)
        case .vmNotRunning(let worktreeID, let guest):
            if let refusal = await autoStartRefusal(
                worktreeID: worktreeID, guest: guest, sessionID: sessionID,
                call: .vmRun(timeoutSeconds: timeoutSeconds), autoStarted: autoStarted
            ) {
                return .error(refusal)
            }
            return await performVMRun(
                command, timeoutSeconds: timeoutSeconds, vm: guest, sessionID: sessionID, worktreeID: worktreeID,
                autoStarted: true
            )
        case .vmStateUnreadable:
            return .error(VMComputerUseRoute.vmStateUnreadableMessage)
        case .guest(let worktreeID, let guest):
            if vmStoppedSessions.contains(sessionID) || computerUse.isStopped(sessionID: sessionID) {
                return .error(ComputerUseCoordinator.stoppedMessage)
            }
            let recordID = VMIdentity.recordID(worktree: worktreeID, guest: guest)
            if let refusal = await joinedStartRefusal(
                recordID: recordID, guest: guest, sessionID: sessionID, call: .vmRun(timeoutSeconds: timeoutSeconds)
            ) {
                return .error(refusal)
            }
            guard let client = vmManager.guestClient(for: worktreeID, guest: guest) else {
                return .error(guest == .linux ? VMComputerUseRoute.linuxVMNotRunningMessage : VMComputerUseRoute.vmNotRunningMessage)
            }
            if let refusal = VMTakeOvers.refusal(action: nil, driver: vmDriver(recordID: recordID)) {
                return .error(refusal)
            }
            vmLastAgentCall.begin(recordID, (sessionID, "vm_run", vmNow()))
            defer { vmLastAgentCall.end(recordID, at: vmNow()) }
            // Awaited in the request's own task, so a client disconnect cancels the guest call.
            do {
                return .text([VMComputerUseRoute.runReply(try await client.run(command, timeoutSeconds: timeoutSeconds))])
            } catch {
                return .error((error as? VMGuestClient.Failure ?? .stopped).message(for: guest))
            }
        }
    }

    // MARK: - Auto-start

    func makeVMAutoStarter() -> VMAutoStarter {
        VMAutoStarter(
            start: { [vmManager] in try await vmManager.startVM(worktreeID: $0, guest: $1) },
            startPausing: { [vmManager] in _ = try await vmManager.startVM(worktreeID: $0, pausing: $1) },
            isStarting: { [vmManager] in vmManager.isStarting($0) },
            isRunning: { [vmManager] in vmManager.running($0, guest: $1) != nil },
            helperAnswers: { [vmManager] worktreeID, guest in
                // A VM stopped meanwhile has nothing to wait for; the call then gets the stopped error.
                guard let client = vmManager.guestClient(for: worktreeID, guest: guest) else { return true }
                return (try? await client.hello()) != nil
            },
            candidateName: { [weak self] in self?.vmDisplayName(forRecordID: $0) ?? $0 }
        )
    }

    /// Why a call to a VM that isn't running here can't go on, or nil once this call started it.
    /// A VM another Alas runs keeps today's error, and so does one that stopped again while this
    /// call started it: a second start isn't tried.
    private func autoStartRefusal(
        worktreeID: String, guest: VMGuestOS, sessionID: String, call: VMAutoStartCall, autoStarted: Bool
    ) async -> String? {
        let notRunning = guest == .linux ? VMComputerUseRoute.linuxVMNotRunningMessage : VMComputerUseRoute.vmNotRunningMessage
        if autoStarted { return notRunning }
        if vmStoppedSessions.contains(sessionID) || computerUse.isStopped(sessionID: sessionID) {
            return ComputerUseCoordinator.stoppedMessage
        }
        let elsewhere = vmManager.recordStatus(worktreeID, guest: guest).runningElsewhere != nil
        switch VMStoppedDecision.decide(runningElsewhere: elsewhere) {
        case .runningElsewhere:
            return notRunning
        case .start:
            return await autoStart(
                recordID: VMIdentity.recordID(worktree: worktreeID, guest: guest), guest: guest, sessionID: sessionID, call: call
            ).refusal
        }
    }

    /// A VM an auto-start booted can run before its guest helper answers: a call reaching it then
    /// (an agent's retry after `starting`) joins that start and its wait, within its own budget,
    /// instead of failing on the helper. Nil when no start is under way, or once it is ready.
    private func joinedStartRefusal(
        recordID: String, guest: VMGuestOS, sessionID: String, call: VMAutoStartCall
    ) async -> String? {
        guard vmAutoStarter.starting.contains(recordID) else { return nil }
        return await autoStart(recordID: recordID, guest: guest, sessionID: sessionID, call: call).refusal
    }

    /// Starts VM `recordID` for a call of `sessionID`, or joins its start, and waits for it.
    func autoStart(recordID: String, guest: VMGuestOS, sessionID: String, call: VMAutoStartCall) async -> AutoStartResult {
        await vmAutoStarter.autoStart(
            worktreeID: VMIdentity.parse(recordID: recordID).worktree, guest: guest, sessionID: sessionID, call: call
        )
    }

    /// Slot cards waiting for the user's answer, at most one per (session, VM).
    var vmSlotRequests: [VMSlotRequest] { vmAutoStarter.slotRequests }

    /// The registry ids of the VMs starting for agent calls.
    var vmStarting: Set<String> { vmAutoStarter.starting }

    func answerVMSlot(requestID: UUID, choice: VMSlotChoice) {
        vmAutoStarter.answer(requestID: requestID, choice: choice)
    }

    /// How the user knows VM `recordID`: its worktree's title.
    func vmDisplayName(forRecordID id: String) -> String {
        if id.hasPrefix(WorktreeVMManager.goldenIDPrefix) { return "macOS setup VM" }
        let worktreeID = VMIdentity.parse(recordID: id).worktree
        return projectAndWorktree(withWorktreeId: worktreeID)?.worktree.title
            ?? URL(fileURLWithPath: worktreeID).lastPathComponent
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
            let driven = Set([VMGuestOS.macOS, .linux].filter { guest in
                worktreeID.map { vmTakenOver.contains(VMIdentity.recordID(worktree: $0, guest: guest)) } ?? false
            })
            return .text([VMComputerUseRoute.statusReply(vms: vms, userDriving: driven)])
        case let route:
            let userDriving = if case .guest(let id, let guest) = route {
                vmTakenOver.contains(VMIdentity.recordID(worktree: id, guest: guest))
            } else { false }
            return .text([VMComputerUseRoute.statusReply(
                route: route, helper: await vmHelperStatus(route), transferHostPath: vmTransferHostPath(route),
                userDriving: userDriving
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

    // MARK: - Take over

    /// Who drives VM `recordID` (`VMIdentity.recordID`) now.
    func vmDriver(recordID: String) -> VMDriver {
        VMDriver.current(
            lastAgentCall: vmLastAgentCall[recordID], inFlight: vmLastAgentCall.isInFlight(recordID),
            takenOver: vmTakenOver.contains(recordID), now: vmNow()
        )
    }

    /// Whether the user took over a VM this session was driving, which stopped it there.
    func isUserDrivingVM(ofSession sessionID: String) -> Bool { vmTakeOvers.holds(sessionID: sessionID) }

    /// The display name of the agent behind `sessionID`.
    func computerUseAgentName(_ sessionID: String) -> String {
        guard let session = session(for: sessionID) else { return "An agent" }
        return agent(id: session.agentId)?.displayName ?? session.agentId
    }

    /// The user takes VM `recordID` over: agent calls to it are refused from now on, and its guest
    /// stops each session driving it, which cancels their calls in flight. Other VMs those
    /// sessions drive are untouched.
    func takeOverVM(recordID: String) async {
        guard !vmTakenOver.contains(recordID) else { return }
        let stops = vmTakeOvers.takeOver(recordID, sessions: vmComputerUseSessions, userStopped: vmStoppedSessions)
        vmLastAgentCall[recordID] = nil
        let client = vmManager.existingGuestClient(for: recordID)
        for stop in stops {
            await client?.lifecycle(stop.event, sessionID: stop.sessionID)
        }
    }

    /// The user hands VM `recordID` back: its guest resumes the sessions the take over stopped,
    /// then ends every driver's turn, and the VM is idle. A resume the guest can't get now goes
    /// out before that session's next call in it.
    func handBackVM(recordID: String) {
        // Closing a VM tab hands back too; a VM the user never took over is left as it is.
        guard vmTakenOver.contains(recordID) else { return }
        let events = vmTakeOvers.handBack(recordID, sessions: vmComputerUseSessions, userStopped: vmStoppedSessions)
        vmLastAgentCall[recordID] = nil
        for message in events where message.event == .resume {
            vmPendingResumes[message.sessionID, default: []].insert(recordID)
        }
        let client = vmManager.existingGuestClient(for: recordID)
        // One task, so each session's resume reaches the guest before its turnEnded.
        Task {
            for message in events {
                let sent = await client?.lifecycle(message.event, sessionID: message.sessionID) ?? false
                if message.event == .resume, sent { resumeTold(message.sessionID, recordID) }
            }
        }
    }

    /// VM `recordID` stopped here: whoever drove it, it is idle now.
    func vmStopped(recordID: String) {
        vmTakeOvers.vmStopped(recordID)
        vmLastAgentCall[recordID] = nil
    }

    /// Whether the badge shows a session as driving its VM.
    func isDrivingVM(sessionID: String) -> Bool { vmDrivingSessions.contains(sessionID) }

    /// The badge's Stop: a VM session stops in its guest, the rest on the host.
    func stopComputerUse(sessionID: String) async {
        // A session waiting on its VM's start never drove it, so this comes before the checks below.
        vmAutoStarter.dismiss(sessionID: sessionID)
        let targets = VMComputerUseRoute.lifecycleTargets(vmComputerUseSessions[sessionID])
        guard vmDrivingSessions.contains(sessionID), !targets.isEmpty else {
            await computerUse.stop(sessionID: sessionID)
            return
        }
        vmStoppedSessions.insert(sessionID)
        vmDrivingSessions.remove(sessionID)
        vmPendingResumes[sessionID] = nil
        for recordID in targets {
            let vm = VMIdentity.parse(recordID: recordID)
            await vmManager.guestClient(for: vm.worktree, guest: vm.guest)?.lifecycle(.stop, sessionID: sessionID)
        }
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
        let targets = VMComputerUseRoute.lifecycleTargets(vmComputerUseSessions[sessionID])
        vmPendingResumes[sessionID] = Set(targets)
        for recordID in targets {
            guard let client = vmManager.existingGuestClient(for: recordID) else { continue }
            Task {
                if await client.lifecycle(.resume, sessionID: sessionID) { resumeTold(sessionID, recordID) }
            }
        }
    }

    /// The guest of VM `recordID` knows the session resumed.
    private func resumeTold(_ sessionID: String, _ recordID: String) {
        vmPendingResumes[sessionID]?.remove(recordID)
        if vmPendingResumes[sessionID]?.isEmpty == true { vmPendingResumes[sessionID] = nil }
    }

    func computerUseTurnEnded(sessionID: String, owner: SessionOwnerID) {
        computerUse.turnEnded(sessionID: sessionID)
        vmDrivingSessions.remove(sessionID)
        forwardVMLifecycle(.turnEnded, sessionID: sessionID, owner: owner)
    }

    func computerUseSessionEnded(sessionID: String, owner: SessionOwnerID) {
        vmAutoStarter.dismiss(sessionID: sessionID)
        computerUse.sessionEnded(sessionID: sessionID)
        vmDrivingSessions.remove(sessionID)
        forwardVMLifecycle(.sessionEnded, sessionID: sessionID, owner: owner)
        vmComputerUseSessions[sessionID] = nil
    }

    /// To each guest of this owner's VMs the session used, and only over a client that exists.
    private func forwardVMLifecycle(_ event: VMGuestLifecycleEvent, sessionID: String, owner: SessionOwnerID) {
        guard case .worktree(let worktreeID) = owner else { return }
        for recordID in VMComputerUseRoute.lifecycleTargets(vmComputerUseSessions[sessionID], worktreeID: worktreeID) {
            guard let client = vmManager.existingGuestClient(for: recordID) else { continue }
            Task { await client.lifecycle(event, sessionID: sessionID) }
        }
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

/// The last agent call forwarded to each VM, by registry id, and how many still run. Each VM's
/// entry is observed on its own: a view reading one VM's call redraws only when that VM is called.
@MainActor
final class VMLastAgentCalls {
    typealias Call = (sessionID: String, tool: String, at: Date)

    @MainActor
    @Observable
    fileprivate final class Entry {
        var call: Call?
        var inFlight = 0
    }

    /// Never removed, so a view that read an entry before its first call still sees it change.
    private var entries: [String: Entry] = [:]

    subscript(recordID: String) -> Call? {
        get { entry(recordID).call }
        set { entry(recordID).call = newValue }
    }

    /// Whether an agent call to VM `recordID` is still running.
    func isInFlight(_ recordID: String) -> Bool { entry(recordID).inFlight > 0 }

    /// An agent call to VM `recordID` begins; it drives the VM until `end` and the window after.
    func begin(_ recordID: String, _ call: Call) {
        let entry = entry(recordID)
        entry.call = call
        entry.inFlight += 1
    }

    /// The call `begin` started ended at `at`: the driving window counts from here. A call
    /// cleared meanwhile (take over, hand back, VM stopped) stays cleared.
    func end(_ recordID: String, at: Date) {
        let entry = entry(recordID)
        entry.inFlight -= 1
        entry.call?.at = at
    }

    private func entry(_ recordID: String) -> Entry {
        if let entry = entries[recordID] { return entry }
        let entry = Entry()
        entries[recordID] = entry
        return entry
    }
}
