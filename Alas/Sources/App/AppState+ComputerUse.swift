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
