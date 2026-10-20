import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

/// Creating and removing worktrees on disk, locally or over SSH, independent
/// of any UI.
public enum WorktreeLifecycle {
    /// The worktree's content changed after the user confirmed its deletion.
    public struct DeleteContentFingerprintMismatch: Error {}

    /// Removes the worktree and, when asked, its merged branch. A local
    /// worktree is moved aside and staged for background cleanup when it can
    /// be; `authorizedDeleteContentFingerprint` refuses the removal if the
    /// content changed since it was taken.
    public static func performRemoveWorktree(
        repoPath: URL,
        worktree: Worktree,
        deleteBranchIfMerged: Bool,
        force: Bool,
        verifiedMergedBranchSHA: String? = nil,
        authorizedDeleteContentFingerprint: String? = nil
    ) async throws -> WorktreeRemovalOutcome {
        try await Task.detached {
            if let authorizedDeleteContentFingerprint {
                let currentFingerprint = try await WorktreeService.worktreeDeleteContentFingerprint(
                    worktreePath: worktree.path
                )
                guard currentFingerprint == authorizedDeleteContentFingerprint else {
                    throw DeleteContentFingerprintMismatch()
                }
            }

            if worktree.path.isRemoteAlasPath {
                try await WorktreeService().remove(
                    repoPath: repoPath,
                    worktree: worktree,
                    deleteBranchIfMerged: deleteBranchIfMerged,
                    force: force,
                    verifiedMergedBranchSHA: verifiedMergedBranchSHA
                )
                return .synchronous
            }
            return try await WorktreeService().removeFastLocal(
                repoPath: repoPath,
                worktree: worktree,
                deleteBranchIfMerged: deleteBranchIfMerged,
                force: force,
                verifiedMergedBranchSHA: verifiedMergedBranchSHA,
                authorizedDeleteContentFingerprint: authorizedDeleteContentFingerprint
            )
        }.value
    }

    public static func performCreateWorktree(
        repoPath: URL,
        base: String,
        branch: String,
        destination: URL,
        projectId: String,
        requiresNewBranch: Bool = false
    ) async throws -> Worktree {
        try await ProjectMutationGate.shared.withMutation(projectID: projectId) {
            try await Task.detached {
                if !repoPath.isRemoteAlasPath {
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                }
                return try await WorktreeService().add(
                    repoPath: repoPath,
                    base: base,
                    branch: branch,
                    destination: destination,
                    projectId: projectId,
                    requiresNewBranch: requiresNewBranch
                )
            }.value
        }
    }

    public static func preparedCreateWorktreeDestination(repoPath: URL, destination: URL) async throws -> URL {
        let isRemote = repoPath.isRemoteAlasPath
        let preparedDestination: URL
        if isRemote,
           let host = RemoteHostRegistry.shared.host(forPath: repoPath.path) {
            let remoteHome = try await Self.remoteHomeDirectory(host: host)
            // The home swap works on the real remote path; the result goes back
            // to the virtual form the rest of the app keys worktrees by.
            preparedDestination = try await RemotePath.resolvedWorktreeDestination(
                Self.destinationPathReplacingLocalHome(destination.path, remoteHome: remoteHome),
                anchor: repoPath.path,
                runCommand: { command in
                    try await RemoteExec.run(host: host, cwd: nil, command: command, timeout: 10)
                }
            )
        } else {
            guard !RemotePath.isReserved(destination.path) else { throw RemotePath.reservedForRemoteError(destination.path) }
            preparedDestination = destination
        }
        if isRemote {
            return preparedDestination
        }
        return preparedDestination
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(preparedDestination.lastPathComponent)
    }

    /// The destination persisted for a `.new` delegation, in the form the
    /// created worktree's path will have so startup recovery can find it:
    /// virtual for remote projects, parent-symlink-resolved for local ones.
    /// The remote home swap needs an ssh round trip and is not applied here.
    public static func delegatedWorktreeDestination(rendered: URL, projectPath: String) -> URL {
        guard !URL(fileURLWithPath: projectPath).isRemoteAlasPath else {
            return URL(fileURLWithPath: RemotePath.virtualizing(rendered.path, like: projectPath))
        }
        return rendered
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(rendered.lastPathComponent)
    }

    public static func destinationPathReplacingLocalHome(
        _ path: String,
        localHome: String = NSHomeDirectory(),
        remoteHome: String
    ) -> String {
        let normalizedLocalHome = localHome.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let localHomePath = "/\(normalizedLocalHome)"
        guard path == localHomePath || path.hasPrefix("\(localHomePath)/") else { return path }
        let suffix = path.dropFirst(localHomePath.count)
        return remoteHome.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            ? path
            : "/\(remoteHome.trimmingCharacters(in: CharacterSet(charactersIn: "/")))\(suffix)"
    }

    public static func remoteHomeDirectory(host: String) async throws -> String {
        let result = try await RemoteExec.run(
            host: host,
            cwd: nil,
            command: "printf '%s' \"$HOME\"",
            timeout: 10
        )
        let home = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !home.isEmpty else {
            throw NSError(
                domain: "RemoteHomeDirectory",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: "Could not resolve remote home directory for \(host)."]
            )
        }
        return home
    }
}
