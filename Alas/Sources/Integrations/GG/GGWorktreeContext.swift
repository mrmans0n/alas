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

        let policyEnabled: Bool
        switch worktreeOverride {
        case .on:
            policyEnabled = true
        case .off:
            policyEnabled = false
        case .inherit:
            if isMainWorktree {
                policyEnabled = false
            } else {
                switch projectMode {
                case .off: policyEnabled = false
                case .auto: policyEnabled = repoHasGGConfig
                case .on: policyEnabled = true
                }
            }
        }
        guard policyEnabled else { return .inactive(reason: .policyOff) }

        guard let branchUsername, !branchUsername.isEmpty else {
            return .inactive(reason: .branchUsernameMissing)
        }
        guard let name = stackName(branch: branch, username: branchUsername) else {
            return .inactive(reason: .branchPrefixMismatch(expectedPrefix: "\(branchUsername)/"))
        }
        return .active(stackName: name)
    }
}
