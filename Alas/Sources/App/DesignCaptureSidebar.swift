#if DEBUG
import Foundation

/// Design-capture targets for the sidebar's peer pages. The scripted peers of
/// `DesignCaptureDemoPeer` are installed with their sidebar-only rows (an offline
/// Mac, a failed and an in-flight host operation, an archived worktree, an
/// "Other sessions" bucket, an empty project, an overflowing tab row) and the
/// Studio's page is opened. Debug builds only, and only on a capture profile.
///
/// - peers: the Studio's page, with a worktree selected.
/// - peers-rename: the same with the peer worktree rename sheet open.
/// - live-activity: the demo project's rows with scripted VMs, devices, stack
///   ships and shepherds (`DesignCaptureLiveActivity`).
/// - badge-hover: the hover card of the selected row's first agent badge, held
///   open in its real panel (`DesignCaptureAgentBadges.Hover`).
@MainActor
enum DesignCaptureSidebar {
    static let targets: Set<String> = ["peers", "peers-rename", "live-activity", "badge-hover"]

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
            if target == "badge-hover" {
                @MainActor func firstBadge() -> String? {
                    state.selectedWorktreeId.flatMap { state.harnessBadges(forWorktree: $0).first?.id }
                }
                guard await eventually({ firstBadge() != nil }) else { return }
                DesignCaptureAgentBadges.Hover.shared.sessionId = firstBadge()
                return
            }
            if target == "live-activity" {
                DesignCaptureLiveActivity.shared.byBranch = DesignCaptureLiveActivity.demo
                return
            }
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
            if let invoice = repos(studio).flatMap(\.worktrees).first(where: { $0.title == "feat/invoice-export" }) {
                client.selectWorktree(NativePeerWorktreeSelection(serverId: studio, worktreeId: invoice.id))
            } else {
                client.openPeer(serverId: studio)
            }
            if target == "peers-rename",
               let host = repos(studio).flatMap(\.worktrees).first(where: { $0.title == "fix/retry-backoff-jitter" })?.host {
                model.renamingBranch = NativePeerBranchRename(
                    worktree: host, serverId: studio, peerName: DesignCaptureDemoPeer.studio.name)
            }
        }
    }
}

/// Scripted live activity for the demo profile's rows, keyed by branch. Nil
/// outside the live-activity capture, so `SidebarView` resolves the real one.
@MainActor
@Observable
final class DesignCaptureLiveActivity {
    static let shared = DesignCaptureLiveActivity()

    var byBranch: [String: WorktreeRowPresentation.LiveActivity]?

    typealias Presentation = WorktreeRowPresentation
    typealias Device = WorktreeRowPresentation.OwnedDevice

    private static func shepherd(_ number: String, _ note: String?, loud: Bool = false, stack: Bool = false)
        -> Presentation.ShepherdNote {
        Presentation.ShepherdNote(
            number: number, note: note, isLoud: loud,
            tooltip: "Shepherding \(number)" + (note.map { ": \($0)" } ?? ""),
            sessionID: "demo", replacesStackChip: stack
        )
    }

    static let demo: [String: Presentation.LiveActivity] = [
        // The selected row: a ship mid-lint, beside a running macOS VM.
        "nacho/refactor-transcript-scroller-row-height-cache": Presentation.LiveActivity(
            glyphs: Presentation.resourceGlyphs(vms: [.macOS: .running], devices: []),
            ship: Presentation.shipLine(.running(
                sessionID: "demo", progress: StackShipProgress(phase: .linting, position: 2, totalEntries: 4)
            )),
            shepherd: nil
        ),
        "feat/invoice-export": Presentation.LiveActivity(
            glyphs: Presentation.resourceGlyphs(
                vms: [.macOS: .running, .linux: .starting],
                devices: [Device(id: "sim", name: "iPhone 17 Pro", isAndroid: false, isEmulator: false, state: .on)]
            ),
            ship: nil,
            shepherd: shepherd("#2601", nil)
        ),
        "feat/team-invites": Presentation.LiveActivity(
            glyphs: Presentation.resourceGlyphs(
                vms: [:],
                devices: [Device(id: "avd:Pixel_9", name: "Pixel 9", isAndroid: true, isEmulator: true, state: .starting)]
            ),
            ship: nil,
            shepherd: shepherd("#2604", "agent fixing")
        ),
        "feat/usage-charts": Presentation.LiveActivity(
            glyphs: [],
            ship: Presentation.shipLine(.failed(
                sessionID: "demo", message: "gg sync failed: remote rejected feat/usage-charts\nhint: fetch first"
            )),
            shepherd: nil
        ),
        "fix/retry-backoff-jitter": Presentation.LiveActivity(
            glyphs: [], ship: nil, shepherd: shepherd("#2611", "needs you", loud: true)
        ),
        "refactor/job-queue": Presentation.LiveActivity(
            glyphs: [], ship: nil, shepherd: shepherd("4 PRs", "1 merged", stack: true)
        ),
    ]
}
#endif
