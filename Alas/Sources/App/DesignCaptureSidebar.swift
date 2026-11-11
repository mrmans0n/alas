#if DEBUG
import Foundation

/// Design-capture targets for the sidebar's Peers section. The scripted peers of
/// `DesignCaptureDemoPeer` are installed with their sidebar-only rows (an offline
/// Mac, a failed and an in-flight host operation, an archived worktree, an
/// "Other sessions" bucket, an empty project, an overflowing tab row), both
/// online Macs are expanded and the local projects are collapsed so the whole
/// section fits the window. Debug builds only, and only on a capture profile.
///
/// - peers: the expanded section.
/// - peers-hover: the same with the section header hovered, so the "+" pair-a-peer control shows.
/// - peers-rename: the same with the peer worktree rename sheet open.
@MainActor
enum DesignCaptureSidebar {
    static let targets: Set<String> = ["peers", "peers-hover", "peers-rename"]

    /// Registered by `SidebarView` when it appears; the model lives in its `@State`.
    static weak var peerModel: NativePeerSidebarModel?

    /// Only an instance capture.sh launched on a demo profile may change state; another Debug
    /// instance also receives the distributed capture notification and must ignore it.
    private static var isCaptureInstance: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["ALAS_DESIGN_CAPTURE"] == "1" && env["ALAS_APP_SUPPORT_DIR"] != nil
    }

    static func open(_ target: String, state: AppState) {
        guard isCaptureInstance else { return }
        Task { @MainActor in
            @MainActor func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
                let limit = Date().addingTimeInterval(30)
                while !condition(), Date() < limit { try? await Task.sleep(for: .milliseconds(200)) }
                return condition()
            }
            guard await eventually({ !state.projects.isEmpty }) else { return }
            DesignCaptureBridge.installDemoPeer(state: state, sidebarVariants: true)
            guard let client = state.nativePeerSessions else { return }
            // Every row variant needs the host snapshot, the sessions and the consoles to have landed.
            let studio = DesignCaptureDemoPeer.studio.serverId
            let air = DesignCaptureDemoPeer.air.serverId
            @MainActor func repos(_ id: String) -> [NativePeerRepoGroup] {
                client.snapshot.groups.first { $0.id == id }?.repos(ordering: state.config.worktrees.defaultOrdering) ?? []
            }
            let loaded = await eventually {
                client.snapshot.groups.count == 3 && peerModel != nil
                    && repos(studio).flatMap(\.worktrees).contains { $0.host != nil && $0.sessions.count >= 1 }
                    && repos(air).flatMap(\.worktrees).count >= 3
                    && !(client.consoles?.consoles[studio]?.isEmpty ?? true)
                    && !((client.hosts?.archivedWorktrees[studio] ?? []).isEmpty)
            }
            guard loaded, let model = peerModel else { return }
            state.config.collapsedProjectIds = state.projects.map(\.id).sorted()
            model.expandedPeerIDs = [studio, air]
            if let invoice = repos(studio).flatMap(\.worktrees).first(where: { $0.title == "feat/invoice-export" }) {
                client.selectWorktree(NativePeerWorktreeSelection(serverId: studio, worktreeId: invoice.id))
            }
            switch target {
            case "peers-hover":
                model.headerHovering = true
                model.plusHovering = true
            case "peers-rename":
                if let host = repos(studio).flatMap(\.worktrees).first(where: { $0.title == "fix/retry-backoff-jitter" })?.host {
                    model.renamingBranch = NativePeerBranchRename(
                        worktree: host, serverId: studio, peerName: DesignCaptureDemoPeer.studio.name)
                }
            default:
                break
            }
        }
    }
}
#endif
