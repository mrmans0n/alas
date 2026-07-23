import Foundation

/// Hard availability of GG creation in the new-worktree dialog. This controls
/// whether the picker is shown and whether GG branch naming has the required
/// username; effective On/Off policy is resolved separately by `createsStack`.
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
