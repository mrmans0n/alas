import Foundation

/// The Workspace checkout a session works in: a directory holding one git
/// worktree per member repository, itself no git repository. A session row
/// carries it so a client can reach the code of each member.
public struct RemoteSessionCheckout: Codable, Equatable, Sendable {
    /// The checkout's id.
    public let id: String
    /// The Workspace's name, or the name it had when the Workspace is gone.
    public let name: String
    public let branch: String
    /// The checkout's root in the form member worktree paths take: `host:/path`
    /// for an SSH checkout, an absolute path for a local one.
    public let rootPath: String
    /// The members that are available and listed as worktrees.
    public let members: [Member]

    public struct Member: Codable, Equatable, Sendable, Identifiable {
        /// The checkout member's id.
        public let id: String
        /// The member's project name.
        public let name: String
        public let projectId: String
        public let worktreeId: String
        public let worktree: RemoteWorktreeSummary

        public init(id: String, name: String, projectId: String, worktreeId: String, worktree: RemoteWorktreeSummary) {
            self.id = id
            self.name = name
            self.projectId = projectId
            self.worktreeId = worktreeId
            self.worktree = worktree
        }
    }

    public init(id: String, name: String, branch: String, rootPath: String, members: [Member]) {
        self.id = id
        self.name = name
        self.branch = branch
        self.rootPath = rootPath
        self.members = members
    }

    /// The member whose worktree holds `absolutePath`, and the path relative
    /// to that worktree. The deepest worktree wins when one nests in another;
    /// nil when no member holds the path.
    public func member(containing absolutePath: String) -> (member: Member, relativePath: String)? {
        members
            .compactMap { member -> (member: Member, relativePath: String)? in
                let root = member.worktree.path
                if absolutePath == root { return (member, "") }
                let prefix = root.hasSuffix("/") ? root : root + "/"
                guard absolutePath.hasPrefix(prefix) else { return nil }
                return (member, String(absolutePath.dropFirst(prefix.count)))
            }
            .max { $0.member.worktree.path.count < $1.member.worktree.path.count }
    }

    /// The member and member-relative file for `path`, a file relative to the checkout's root, which is
    /// where the agent's relative links start. Nil when no member holds it, or it names a member's root.
    public func memberFile(atRootRelative path: String) -> (member: Member, relativePath: String)? {
        let root = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        guard let match = member(containing: root + "/" + path), !match.relativePath.isEmpty else { return nil }
        return match
    }
}
