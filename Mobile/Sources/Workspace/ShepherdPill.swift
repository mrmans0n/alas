import AlasRemoteKit
import SwiftUI

/// The session's pull request pill, as on the Mac: Ship with agent without a shepherd, else its
/// number and state, with what the host lets the phone do about it.
struct ShepherdPill: View {
    let workspace: SessionWorkspace
    let isBusy: Bool
    @State private var error: String?

    var body: some View {
        let shepherd = workspace.shepherd
        let badge = shepherd?.badge ?? "noRequest"
        Menu {
            if let shepherd {
                Text(shepherd.tooltip)
            }
            ForEach(RemoteShepherd.offered(for: shepherd), id: \.self) { action in
                Button(Self.title(action), systemImage: Self.symbol(action)) { run(action) }
            }
            if let shepherd, !shepherd.isFinished {
                if let autoFix = shepherd.autoFix {
                    Toggle("Auto-fix", systemImage: "wrench.and.screwdriver", isOn: Binding(
                        get: { autoFix }, set: { run($0 ? .enableAutoFix : .disableAutoFix) }))
                }
                if let autoMerge = shepherd.autoMerge {
                    Toggle("Auto-merge", systemImage: "arrow.triangle.merge", isOn: Binding(
                        get: { autoMerge }, set: { run($0 ? .enableAutoMerge : .disableAutoMerge) }))
                }
            }
        } label: {
            if workspace.shepherdRunning != nil {
                ProgressView()
            } else {
                label(shepherd: shepherd, badge: badge)
            }
        }
        .disabled(workspace.shepherdRunning != nil)
        .accessibilityLabel("Pull request")
        .accessibilityValue(accessibilityValue(shepherd))
        .alert("Couldn't Do That", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    /// The Mac pill invites a Ship while there is no shepherd and the agent is free to be asked.
    static func invitesShip(shepherd: RemoteShepherd?, isBusy: Bool) -> Bool {
        shepherd == nil && !isBusy
    }

    private func label(shepherd: RemoteShepherd?, badge: String) -> some View {
        let stackShip = workspace.shipsStack && shepherd == nil
        let invites = Self.invitesShip(shepherd: shepherd, isBusy: isBusy)
        let tint = invites ? Color.green : Self.color(badge)
        let active = badge == "fixing" || badge == "merging"
        return Label {
            Text(shepherd?.number ?? (workspace.shipsStack ? "Ship stack" : "Ship"))
        } icon: {
            Image(systemName: stackShip ? "square.stack.3d.up.fill" : Self.badgeSymbol(badge))
                .symbolEffect(.pulse, isActive: active)
        }
        .labelStyle(.titleAndIcon)
        .fontWeight(invites ? .semibold : nil)
        .foregroundStyle(tint)
        .padding(.horizontal, invites ? 8 : 0)
        .padding(.vertical, invites ? 3 : 0)
        .background {
            if invites {
                Capsule().fill(Color.green.opacity(0.15))
                Capsule().strokeBorder(Color.green.opacity(0.5), lineWidth: 0.5)
            }
        }
    }

    private func accessibilityValue(_ shepherd: RemoteShepherd?) -> String {
        if let shepherd { return shepherd.tooltip }
        return isBusy ? "Ship with agent after the current turn" : "Ship with agent"
    }

    private func run(_ action: RemoteShepherdAction) {
        Task { error = await workspace.shepherd(action) }
    }

    private static func title(_ action: RemoteShepherdAction) -> String {
        switch action {
        case .ship: "Ship with Agent"
        case .resume: "Resume"
        case .stop: "Stop Shepherding"
        case .enableAutoFix, .disableAutoFix: "Auto-fix"
        case .enableAutoMerge, .disableAutoMerge: "Auto-merge"
        }
    }

    private static func symbol(_ action: RemoteShepherdAction) -> String {
        switch action {
        case .ship: "paperplane"
        case .resume: "play"
        case .stop: "stop"
        case .enableAutoFix, .disableAutoFix: "wrench.and.screwdriver"
        case .enableAutoMerge, .disableAutoMerge: "arrow.triangle.merge"
        }
    }

    /// The Mac pill's symbols and colors, by `ShepherdBadgeState` raw value.
    static func badgeSymbol(_ badge: String) -> String {
        switch badge {
        case "unshepherded": "arrow.triangle.pull"
        case "waiting": "clock.fill"
        case "fixing": "sparkles"
        case "ready", "merging": "arrow.triangle.merge"
        case "queued": "list.bullet.rectangle"
        case "attention": "exclamationmark.triangle.fill"
        case "merged": "checkmark.circle.fill"
        case "closed": "xmark.circle"
        default: "paperplane.fill"
        }
    }

    static func color(_ badge: String) -> Color {
        switch badge {
        case "waiting": .yellow
        case "fixing": .accentColor
        case "ready", "merging", "queued": .green
        case "attention": .red
        case "merged": .purple
        default: .secondary
        }
    }
}
