import AlasComputerUseKit
import SwiftUI

/// Toolbar badge shown while this session drives an app (on the desktop or in its VM) or is stopped.
struct ComputerUseBadge: View {
    let sessionID: String
    let state: AppState
    @Environment(\.theme) private var theme

    /// Visible when the session is the driver or has been stopped.
    static func isVisible(driving: Bool, stopped: Bool) -> Bool { driving || stopped }

    var body: some View {
        let coordinator = state.computerUse
        let drivingVM = state.isDrivingVM(sessionID: sessionID)
        let driving = coordinator.driver?.sessionID == sessionID || drivingVM
        let stopped = coordinator.isStopped(sessionID: sessionID) || state.vmStoppedSessions.contains(sessionID)
        if Self.isVisible(driving: driving, stopped: stopped) {
            Menu {
                if stopped {
                    Button("Resume computer use") { state.resumeComputerUse(sessionID: sessionID) }
                } else {
                    Button("Stop computer use") { Task { await state.stopComputerUse(sessionID: sessionID) } }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cursorarrow.rays").font(.system(size: 10))
                    Text(stopped ? "Computer use stopped" : drivingVM ? "Using the VM" : "Using \(coordinator.driver?.app.name ?? "")")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(stopped ? theme.color("fg-dim") : theme.color("accent"))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}
