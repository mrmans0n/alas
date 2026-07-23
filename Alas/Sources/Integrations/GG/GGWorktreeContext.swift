import Foundation

enum GGWorktreeMode: String, Codable, Equatable, CaseIterable {
    case inherit
    case on
    case off
}

enum GGWorktreeInactiveReason: Equatable {
    case masterDisabled
    case cliMissing
    case remoteProject
    case policyOff
    case branchUsernameMissing
    case branchPrefixMismatch(expectedPrefix: String)
}

enum GGWorktreeContext: Equatable {
    case active(stackName: String)
    case inactive(reason: GGWorktreeInactiveReason)

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

enum GGWorktreeContextResolver {
    static func stackName(branch: String, username: String) -> String? {
        let prefix = "\(username)/"
        guard branch.hasPrefix(prefix) else { return nil }
        let name = String(branch.dropFirst(prefix.count))
        return name.isEmpty ? nil : name
    }

    static func isPolicyEnabled(
        projectMode: GGProjectMode,
        worktreeOverride: GGWorktreeMode,
        isMainWorktree: Bool,
        repoHasGGConfig: Bool
    ) -> Bool {
        switch worktreeOverride {
        case .on:
            return true
        case .off:
            return false
        case .inherit:
            if isMainWorktree { return false }
            switch projectMode {
            case .off: return false
            case .auto: return repoHasGGConfig
            case .on: return true
            }
        }
    }

    static func resolve(
        masterEnabled: Bool,
        ggInstalled: Bool,
        isRemoteProject: Bool,
        projectMode: GGProjectMode,
        worktreeOverride: GGWorktreeMode,
        isMainWorktree: Bool,
        repoHasGGConfig: Bool,
        branchUsername: String?,
        branch: String
    ) -> GGWorktreeContext {
        guard masterEnabled else { return .inactive(reason: .masterDisabled) }
        guard ggInstalled else { return .inactive(reason: .cliMissing) }
        guard !isRemoteProject else { return .inactive(reason: .remoteProject) }

        guard isPolicyEnabled(
            projectMode: projectMode,
            worktreeOverride: worktreeOverride,
            isMainWorktree: isMainWorktree,
            repoHasGGConfig: repoHasGGConfig
        ) else { return .inactive(reason: .policyOff) }

        guard let branchUsername, !branchUsername.isEmpty else {
            return .inactive(reason: .branchUsernameMissing)
        }
        guard let name = stackName(branch: branch, username: branchUsername) else {
            return .inactive(reason: .branchPrefixMismatch(expectedPrefix: "\(branchUsername)/"))
        }
        return .active(stackName: name)
    }
}
