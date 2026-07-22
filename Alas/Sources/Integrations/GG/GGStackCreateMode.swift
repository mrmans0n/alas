import Foundation

/// Availability of the "Create as gg stack" mode in the new-worktree
/// dialog. Hidden when the project isn't gg-gated; disabled (with a hint)
/// when gg's branch_username can't be resolved from config — we fail
/// closed rather than re-implementing gg's whoami resolution.
enum GGStackCreateMode {
    enum Availability: Equatable {
        case hidden
        case disabled(hint: String)
        case enabled(username: String)
    }

    static func availability(gatePassed: Bool, username: String?) -> Availability {
        guard gatePassed else { return .hidden }
        guard let username else {
            return .disabled(
                hint: "Set branch_username in gg config or run `gg co` once in this repo."
            )
        }
        return .enabled(username: username)
    }

    static func createsStack(
        masterEnabled: Bool,
        ggInstalled: Bool,
        isRemoteProject: Bool,
        projectMode: GGProjectMode,
        worktreeMode: GGWorktreeMode,
        repoHasGGConfig: Bool
    ) -> Bool {
        guard masterEnabled, ggInstalled, !isRemoteProject else { return false }
        return GGWorktreeContextResolver.isPolicyEnabled(
            projectMode: projectMode,
            worktreeOverride: worktreeMode,
            isMainWorktree: false,
            repoHasGGConfig: repoHasGGConfig
        )
    }
}
