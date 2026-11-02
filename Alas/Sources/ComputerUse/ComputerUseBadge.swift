import AlasComputerUseKit
import SwiftUI

/// Toolbar badge shown while this session drives an app (on the desktop or in its VM), waits for
/// its VM to start, has had its VM taken over by the user, or is stopped.
struct ComputerUseBadge: View {
    let sessionID: String
    let state: AppState
    @Environment(\.theme) private var theme

    struct Label: Equatable {
        let text: String
        /// Accent while the session acts or waits to; dim otherwise.
        let accent: Bool
    }

    /// The badge's label, or nil when it hides. `drivingApp` is the desktop app the session drives.
    nonisolated static func label(
        drivingApp: String?, drivingVM: Bool, stopped: Bool, vmStarting: Bool, waitingForSlot: Bool, userDriving: Bool
    ) -> Label? {
        if stopped { return Label(text: "Computer use stopped", accent: false) }
        if userDriving { return Label(text: "You're driving the VM", accent: false) }
        if waitingForSlot { return Label(text: "Waiting for a VM slot", accent: true) }
        if vmStarting { return Label(text: "Starting the VM", accent: true) }
        if drivingVM { return Label(text: "Using the VM", accent: true) }
        if let drivingApp { return Label(text: "Using \(drivingApp)", accent: true) }
        return nil
    }

    var body: some View {
        let coordinator = state.computerUse
        let stopped = coordinator.isStopped(sessionID: sessionID) || state.vmStoppedSessions.contains(sessionID)
        let label = Self.label(
            drivingApp: coordinator.driver?.sessionID == sessionID ? coordinator.driver?.app.name ?? "" : nil,
            drivingVM: state.isDrivingVM(sessionID: sessionID),
            stopped: stopped,
            vmStarting: state.vmAutoStarter.isWaitingOnBoot(sessionID: sessionID),
            waitingForSlot: state.vmSlotRequests.contains { $0.sessionID == sessionID },
            userDriving: state.isUserDrivingVM(ofSession: sessionID)
        )
        if let label {
            Menu {
                if stopped {
                    Button("Resume computer use") { state.resumeComputerUse(sessionID: sessionID) }
                } else {
                    Button("Stop computer use") { Task { await state.stopComputerUse(sessionID: sessionID) } }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cursorarrow.rays").font(.system(size: 10))
                    Text(label.text)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(theme.color(label.accent ? "accent" : "fg-dim"))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}
