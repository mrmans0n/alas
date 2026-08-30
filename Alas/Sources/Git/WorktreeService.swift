import CryptoKit
import Foundation

struct WorktreeDeletePreflight: Equatable {
    var requiresForce: Bool { reasons.isEmpty == false }
    var reasons: Set<WorktreeDeletePreflightReason>
    var submoduleLocalState: SubmoduleLocalState
}

enum WorktreeDeletePreflightReason: Equatable, Hashable {
    case dirty
    case containsInitializedSubmodules
}

enum SubmoduleLocalState: Equatable {
    case none
    case present
    case unknown
}

struct WorktreeService {
    enum WorktreeError: Error, LocalizedError {
        case gitFailed(String)

        var errorDescription: String? {
            switch self {
            case let .gitFailed(stderr):
                let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return msg.isEmpty ? "Git worktree operation failed." : msg
            }
        }
    }

    /// Parse `git worktree list --porcelain` into Worktree records.
    func list(repoPath: URL, projectId: String) async throws -> [Worktree] {
        let result = try await Process.git(["worktree", "list", "--porcelain"], cwd: repoPath)
        guard result.exitCode == 0 else { throw WorktreeError.gitFailed(result.stderr) }
        let host = RemoteHostRegistry.shared.host(forPath: repoPath.path)
        let absentLockedPaths = if let host {
            await Self.absentRemoteLockedPaths(in: result.stdout, host: host)
        } else {
            Set<String>()
        }
        var trees = Self.parsePorcelain(
            result.stdout,
            projectId: projectId,
            isRemote: host != nil,
            absentLockedPaths: absentLockedPaths
        )
        if let host {
            trees = await Self.fillingRemoteMetadata(trees, host: host)
        } else {
            trees = await Self.fillingHeadCommitTimes(trees)
        }
        return trees
    }

    /// Returns a best-effort "last activity" timestamp for the worktree at
    /// `path`. Resolves the worktree's HEAD ref through the symbolic-ref
    /// indirection so commits actually update the timestamp:
    ///   <worktree>/.git → gitdir → HEAD → (symbolic) refs/heads/<branch>
    /// Falls back through packed-refs, HEAD's own mtime, and the worktree
    /// directory mtime if any layer can't be resolved.
    static func lastActivity(forWorktreeAt path: URL) -> Date? {
        if path.isRemoteAlasPath { return nil }
        let fm = FileManager.default

        func mtime(of pathStr: String) -> Date? {
            (try? fm.attributesOfItem(atPath: pathStr)[.modificationDate]) as? Date
        }
        func dirMtime() -> Date? { mtime(of: path.path) }

        // 1. Resolve the gitdir.
        let dotGit = path.appendingPathComponent(".git").path
        let gitdir: String
        if let attrs = try? fm.attributesOfItem(atPath: dotGit),
           (attrs[.type] as? FileAttributeType) == .typeRegular,
           let contents = try? String(contentsOfFile: dotGit, encoding: .utf8),
           let line = contents.split(separator: "\n", omittingEmptySubsequences: true)
               .first(where: { $0.hasPrefix("gitdir: ") }) {
            // Linked worktree (or submodule): ".git" file points to the gitdir.
            // Git writes relative paths for submodules (e.g. "gitdir: ../.git/modules/sub")
            // so resolve against the worktree directory before further use.
            let raw = String(line.dropFirst("gitdir: ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            gitdir = raw.hasPrefix("/")
                ? raw
                : path.appendingPathComponent(raw).standardizedFileURL.path
        } else if let attrs = try? fm.attributesOfItem(atPath: dotGit),
                  (attrs[.type] as? FileAttributeType) == .typeDirectory {
            // Main worktree: ".git" is the gitdir.
            gitdir = dotGit
        } else {
            return dirMtime()
        }

        // 2. Resolve the common dir (where shared refs live).
        let commonDir: String = {
            let commondirFile = (gitdir as NSString).appendingPathComponent("commondir")
            if let raw = try? String(contentsOfFile: commondirFile, encoding: .utf8) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("/") { return trimmed }
                // Relative to gitdir.
                return URL(fileURLWithPath: gitdir)
                    .appendingPathComponent(trimmed)
                    .standardizedFileURL.path
            }
            return gitdir
        }()

        // 3. Read HEAD.
        let headPath = (gitdir as NSString).appendingPathComponent("HEAD")
        guard let headContents = try? String(contentsOfFile: headPath, encoding: .utf8) else {
            return dirMtime()
        }
        let head = headContents.trimmingCharacters(in: .whitespacesAndNewlines)

        if head.hasPrefix("ref: ") {
            // Symbolic ref — follow to the loose branch ref file.
            let refRel = String(head.dropFirst("ref: ".count))
                .trimmingCharacters(in: .whitespaces)
            let refPath = (commonDir as NSString).appendingPathComponent(refRel)
            if let m = mtime(of: refPath) { return m }
            // Packed: fall through to packed-refs.
            let packed = (commonDir as NSString).appendingPathComponent("packed-refs")
            if let m = mtime(of: packed) { return m }
        }
        // Detached HEAD or unresolved symref — HEAD's own mtime is meaningful
        // (it's rewritten on each detached commit/checkout).
        if let m = mtime(of: headPath) { return m }
        return dirMtime()
    }

    static func date(fromEpochOutput output: String) -> Date? {
        TimeInterval(output.trimmingCharacters(in: .whitespacesAndNewlines)).map(Date.init(timeIntervalSince1970:))
    }

    static func remoteCreationDate(fromEpochOutput output: String) -> Date? {
        guard let seconds = TimeInterval(output.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds > 0
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func remoteCreationDateCommand(path: String) -> String {
        let dotGit = URL(fileURLWithPath: path).appendingPathComponent(".git").path
        return "f=\(SSHCommand.shellQuote(dotGit)); "
            + "if b=$(stat -c %W -- \"$f\" 2>/dev/null); then "
            + "[ \"$b\" -gt 0 ] || b=$(stat -c %Z -- \"$f\") || exit 1; "
            + "else b=$(stat -f %B \"$f\") || exit 1; "
            + "[ \"$b\" -gt 0 ] || b=$(stat -f %c \"$f\") || exit 1; fi; "
            + "printf '%s\\n' \"$b\""
    }

    static func localLineageID(forWorktreeAt path: URL) -> String? {
        guard let gitDirectory = localGitDirectory(forWorktreeAt: path) else { return nil }
        let marker = gitDirectory.appendingPathComponent("alas-worktree-lineage")
        if let existing = try? String(contentsOf: marker, encoding: .utf8),
           let normalized = normalizedLineageID(existing) {
            return normalized
        }
        let candidate = UUID().uuidString.lowercased()
        try? Data("\(candidate)\n".utf8).write(to: marker, options: .withoutOverwriting)
        guard let stored = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        return normalizedLineageID(stored)
    }

    static func localBranchName(forWorktreeAt path: URL) -> String? {
        guard let gitDirectory = localGitDirectory(forWorktreeAt: path),
              let head = HeadReader.read(headFile: gitDirectory.appendingPathComponent("HEAD"))
        else { return nil }
        switch head {
        case .branch(let name): return name
        case .detached: return "(detached)"
        }
    }

    private static func localGitDirectory(forWorktreeAt path: URL) -> URL? {
        let dotGit = path.appendingPathComponent(".git")
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let contents = try? String(contentsOf: dotGit, encoding: .utf8),
              contents.hasPrefix("gitdir:")
        else { return nil }
        let rawPath = contents.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return nil }
        if (rawPath as NSString).isAbsolutePath {
            return URL(fileURLWithPath: rawPath).standardizedFileURL
        }
        return path.appendingPathComponent(rawPath).standardizedFileURL
    }

    static func remoteLineageIDCommand(path: String, candidateID: String = UUID().uuidString.lowercased()) -> String {
        "p=\(SSHCommand.shellQuote(path)); c=\(SSHCommand.shellQuote(candidateID)); "
            + "d=$(git -C \"$p\" rev-parse --absolute-git-dir) || exit 1; "
            + "f=\"$d/alas-worktree-lineage\"; "
            + "if [ ! -s \"$f\" ]; then "
            + "(umask 077; set -C; printf '%s\\n' \"$c\" > \"$f\") 2>/dev/null || true; fi; "
            + "head -n 1 \"$f\""
    }

    private static func fillingHeadCommitTimes(_ trees: [Worktree]) async -> [Worktree] {
        await withTaskGroup(of: (Int, Date?).self) { group in
            for (index, tree) in trees.enumerated() {
                group.addTask {
                    let invocation = GitInvocation.build(
                        gitArgs: ["log", "-1", "--format=%ct", "HEAD"],
                        cwd: tree.path,
                        host: nil
                    )
                    let result = try? await Process.run(
                        invocation.executable,
                        args: invocation.args,
                        cwd: invocation.cwd,
                        env: invocation.env
                    )
                    return (index, result.flatMap { $0.exitCode == 0 ? date(fromEpochOutput: $0.stdout) : nil })
                }
            }
            var trees = trees
            for await (index, date) in group where date != nil { trees[index].lastActivity = date! }
            return trees
        }
    }

    private static func fillingRemoteMetadata(_ trees: [Worktree], host: String) async -> [Worktree] {
        await withTaskGroup(of: (Int, Date?, Date?, String?).self) { group in
            for (index, tree) in trees.enumerated() {
                group.addTask {
                    let invocation = GitInvocation.build(
                        gitArgs: ["log", "-1", "--format=%ct", "HEAD"],
                        cwd: tree.path,
                        host: host
                    )
                    async let activityResult: ProcessResult? = try? await Process.run(
                        invocation.executable,
                        args: invocation.args,
                        cwd: invocation.cwd,
                        env: invocation.env
                    )
                    async let creationResult: ProcessResult? = try? await RemoteExec.run(
                        host: host,
                        cwd: nil,
                        command: remoteCreationDateCommand(path: tree.path.path)
                    )
                    async let lineageResult: ProcessResult? = try? await RemoteExec.run(
                        host: host,
                        cwd: nil,
                        command: remoteLineageIDCommand(path: tree.path.path)
                    )
                    let (activity, creation, lineage) = await (activityResult, creationResult, lineageResult)
                    return (
                        index,
                        activity.flatMap { $0.exitCode == 0 ? date(fromEpochOutput: $0.stdout) : nil },
                        creation.flatMap { $0.exitCode == 0 ? remoteCreationDate(fromEpochOutput: $0.stdout) : nil },
                        lineage.flatMap { $0.exitCode == 0 ? normalizedLineageID($0.stdout) : nil }
                    )
                }
            }
            var trees = trees
            for await (index, lastActivity, createdAt, lineageID) in group {
                if let lastActivity { trees[index].lastActivity = lastActivity }
                if let createdAt { trees[index].createdAt = createdAt }
                if let lineageID { trees[index].lineageID = lineageID }
            }
            return trees
        }
    }

    static func normalizedLineageID(_ output: String) -> String? {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return value
    }

    static func parsePorcelain(
        _ out: String,
        projectId: String,
        isRemote: Bool = false,
        absentLockedPaths: Set<String> = []
    ) -> [Worktree] {
        var result: [Worktree] = []
        var currentPath: URL?
        var currentBranch: String?
        var currentPrunable = false
        var currentLocked = false

        func flush() {
            let absentLockedPath = currentPath.map { path in
                currentLocked
                    && (isRemote
                        ? absentLockedPaths.contains(path.standardizedFileURL.path)
                        : !path.isRemoteAlasPath && !FileManager.default.fileExists(atPath: path.path))
            } ?? false
            if let path = currentPath, !currentPrunable, !absentLockedPath {
                let branch = currentBranch ?? "(detached)"
                let dirAttrs = try? FileManager.default.attributesOfItem(atPath: path.path)
                let dirMtime = (dirAttrs?[.modificationDate] as? Date) ?? Date()
                let lastActivity = WorktreeService.lastActivity(forWorktreeAt: path) ?? dirMtime
                let ctime = (dirAttrs?[.creationDate] as? Date) ?? dirMtime
                result.append(Worktree(
                    id: Worktree.makeId(path: path),
                    projectId: projectId,
                    name: branch,
                    branch: branch,
                    path: path,
                    isMainWorktree: result.isEmpty,
                    status: .clean,
                    lastActivity: lastActivity,
                    createdAt: ctime,
                    lineageID: isRemote ? nil : WorktreeService.localLineageID(forWorktreeAt: path)
                ))
            }
            currentPath = nil
            currentBranch = nil
            currentPrunable = false
            currentLocked = false
        }

        for line in out.split(separator: "\n") {
            if line.hasPrefix("worktree ") {
                flush()
                currentPath = URL(fileURLWithPath: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("branch ") {
                let raw = String(line.dropFirst("branch ".count))
                // refs/heads/foo → foo
                currentBranch = raw.replacingOccurrences(of: "refs/heads/", with: "")
            } else if line.hasPrefix("prunable") {
                currentPrunable = true
            } else if line.hasPrefix("locked") {
                currentLocked = true
            }
        }
        flush()
        return result
    }

    private static func absentRemoteLockedPaths(in porcelain: String, host: String) async -> Set<String> {
        var lockedPaths: [String] = []
        var currentPath: String?
        for line in porcelain.split(separator: "\n") {
            if line.hasPrefix("worktree ") {
                currentPath = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("locked"), let currentPath {
                lockedPaths.append(URL(fileURLWithPath: currentPath).standardizedFileURL.path)
            }
        }
        return await withTaskGroup(of: String?.self) { group in
            for path in lockedPaths {
                group.addTask {
                    await RemoteFileAccess.existence(host: host, path: path) == .missing ? path : nil
                }
            }
            var absent: Set<String> = []
            for await path in group {
                if let path { absent.insert(path) }
            }
            return absent
        }
    }

    func add(
        repoPath: URL,
        base: String,
        branch: String,
        destination: URL,
        projectId: String
    ) async throws -> Worktree {
        switch GitNameValidator.validateBranchName(branch) {
        case .valid:
            break
        case .invalid(let message):
            throw WorktreeError.gitFailed("Invalid branch name: \(message)")
        }
        let refCheck = try await Process.git(
            ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"],
            cwd: repoPath
        )
        let branchExists = refCheck.exitCode == 0
        var staleRegistration: StaleWorktreeRegistration?
        if let registration = try? await Process.git(
               ["worktree", "list", "--porcelain"],
               cwd: repoPath
           ),
           registration.exitCode == 0 {
            let lockedDestinationIsMissing: Bool
            if let host = RemoteHostRegistry.shared.host(forPath: repoPath.path) {
                lockedDestinationIsMissing = await RemoteFileAccess.existence(
                    host: host,
                    path: destination.path
                ) == .missing
            } else {
                lockedDestinationIsMissing = !FileManager.default.fileExists(atPath: destination.path)
            }
            staleRegistration = Self.staleRegistration(
                registration.stdout,
                destination: destination,
                lockedDestinationIsMissing: lockedDestinationIsMissing
            )
        }

        if staleRegistration == .locked {
            let unlock = try await Process.git(
                ["worktree", "unlock", destination.path],
                cwd: repoPath
            )
            guard unlock.exitCode == 0 else {
                throw WorktreeError.gitFailed(unlock.stderr)
            }
        }
        if staleRegistration != nil {
            let removal = try await Process.git(
                ["worktree", "remove", destination.path],
                cwd: repoPath
            )
            guard removal.exitCode == 0 else {
                throw WorktreeError.gitFailed(removal.stderr)
            }
        }

        let args: [String]
        if branchExists {
            args = ["worktree", "add", destination.path, branch]
        } else {
            args = ["worktree", "add", destination.path, "-b", branch, base]
        }

        let result = try await Process.git(args, cwd: repoPath)
        if result.exitCode == 0 {
            return makeWorktree(destination: destination, branch: branch, projectId: projectId)
        }

        guard Self.looksLikeMissingLFS(result.stderr) else {
            throw WorktreeError.gitFailed(result.stderr)
        }

        // The worktree may already exist if the failure came from a
        // post-checkout hook rather than the checkout itself (e.g. LFS hook
        // detecting missing git-lfs after files are already checked out).
        if let existing = try await existingWorktree(
            repoPath: repoPath, destination: destination, projectId: projectId
        ) {
            return existing
        }

        let recheck = try await Process.git(
            ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"],
            cwd: repoPath
        )
        let branchNowExists = recheck.exitCode == 0

        let fallbackArgs: [String]
        if branchNowExists {
            fallbackArgs = ["worktree", "add", destination.path, branch]
        } else {
            fallbackArgs = ["worktree", "add", destination.path, "-b", branch, base]
        }

        let fallbackResult = try await Process.git(
            Self.lfsFilterOverride + ["-c", "core.hooksPath=/dev/null"] + fallbackArgs,
            cwd: repoPath
        )
        guard fallbackResult.exitCode == 0 else { throw WorktreeError.gitFailed(fallbackResult.stderr) }
        return makeWorktree(destination: destination, branch: branch, projectId: projectId)
    }

    /// Prepares exactly the branch state recorded by Workspace preflight.
    /// Unlike `add`, this never picks a branch mode from current Git state.
    func prepareFrozenBranch(
        repoPath: URL,
        branch: String,
        intent: FrozenBranchIntent
    ) async throws {
        let refCheck = try await Process.git(
            ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"],
            cwd: repoPath
        )
        switch intent {
        case .create(let atCommit):
            guard refCheck.exitCode == 1 else {
                throw WorktreeError.gitFailed("Frozen Workspace branch '\(branch)' changed after preflight.")
            }
            let create = try await Process.git(["branch", branch, atCommit], cwd: repoPath)
            guard create.exitCode == 0 else { throw WorktreeError.gitFailed(create.stderr) }
        case .reuse(let atCommit):
            guard refCheck.exitCode == 0 else {
                throw WorktreeError.gitFailed("Frozen Workspace branch '\(branch)' is no longer reusable.")
            }
            let resolved = try await Process.git(["rev-parse", "--verify", "\(branch)^{commit}"], cwd: repoPath)
            guard resolved.exitCode == 0,
                  resolved.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == atCommit
            else { throw WorktreeError.gitFailed("Frozen Workspace branch '\(branch)' changed after preflight.") }
        }
    }

    /// Adds a worktree from a branch already prepared by
    /// `prepareFrozenBranch`. It deliberately refuses stale registrations and
    /// existing destinations instead of repairing or adopting them.
    func addFrozen(
        repoPath: URL,
        branch: String,
        destination: URL,
        projectId: String,
        intent: FrozenBranchIntent
    ) async throws -> Worktree {
        switch GitNameValidator.validateBranchName(branch) {
        case .valid: break
        case .invalid(let message): throw WorktreeError.gitFailed("Invalid branch name: \(message)")
        }
        if repoPath.isRemoteAlasPath {
            if let host = RemoteHostRegistry.shared.host(forPath: repoPath.path),
               await RemoteFileAccess.existence(host: host, path: destination.path) != .missing {
                throw WorktreeError.gitFailed("Frozen Workspace destination already exists.")
            }
        } else if FileManager.default.fileExists(atPath: destination.path) {
            throw WorktreeError.gitFailed("Frozen Workspace destination already exists.")
        }
        let registrations = try await Process.git(["worktree", "list", "--porcelain"], cwd: repoPath)
        guard registrations.exitCode == 0,
              Self.staleRegistration(registrations.stdout, destination: destination, lockedDestinationIsMissing: false) == nil,
              !registrations.stdout.split(separator: "\n").contains(where: { $0 == "worktree \(destination.path)" })
        else { throw WorktreeError.gitFailed("Frozen Workspace destination is already registered.") }
        let expectedCommit: String
        switch intent {
        case .create(let atCommit), .reuse(let atCommit): expectedCommit = atCommit
        }
        let ref = try await Process.git(["rev-parse", "--verify", "\(branch)^{commit}"], cwd: repoPath)
        guard ref.exitCode == 0,
              ref.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == expectedCommit
        else { throw WorktreeError.gitFailed("Frozen Workspace branch '\(branch)' changed after preflight.") }
        if !repoPath.isRemoteAlasPath {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let result = try await Process.git(["worktree", "add", destination.path, branch], cwd: repoPath)
        guard result.exitCode == 0 else { throw WorktreeError.gitFailed(result.stderr) }
        return makeWorktree(destination: destination, branch: branch, projectId: projectId)
    }

    enum StaleWorktreeRegistration {
        case prunable
        case locked
    }

    static func staleRegistration(
        _ porcelain: String,
        destination: URL,
        lockedDestinationIsMissing: Bool
    ) -> StaleWorktreeRegistration? {
        func canonicalPath(_ url: URL) -> String {
            url.deletingLastPathComponent()
                .resolvingSymlinksInPath()
                .appendingPathComponent(url.lastPathComponent)
                .standardizedFileURL.path
        }

        let destinationPath = canonicalPath(destination)
        var currentPath: String?
        var currentPrunable = false
        var currentLocked = false

        func currentRegistration() -> StaleWorktreeRegistration? {
            guard let currentPath,
                  canonicalPath(URL(fileURLWithPath: currentPath)) == destinationPath
            else { return nil }
            if currentPrunable { return .prunable }
            if currentLocked, lockedDestinationIsMissing {
                return .locked
            }
            return nil
        }

        for line in porcelain.split(separator: "\n") {
            if line.hasPrefix("worktree ") {
                if let registration = currentRegistration() { return registration }
                currentPath = String(line.dropFirst("worktree ".count))
                currentPrunable = false
                currentLocked = false
            } else if line.hasPrefix("prunable") {
                currentPrunable = true
            } else if line.hasPrefix("locked") {
                currentLocked = true
            }
        }
        return currentRegistration()
    }

    /// Remove a worktree. Pass the full `Worktree` (not just a path) so we can
    /// reliably resolve the branch name when `deleteBranchIfMerged` is true —
    /// path basenames diverge from branch names whenever the path template
    /// substitutes `/` (e.g. branch `feat/x` lives at dir basename `feat-x`).
    /// `force` adds `--force`, required when the worktree has uncommitted
    /// changes or untracked files.
    func remove(
        repoPath: URL,
        worktree: Worktree,
        deleteBranchIfMerged: Bool,
        force: Bool = false
    ) async throws {
        var args = ["worktree", "remove", worktree.path.path]
        if force { args.append("--force") }
        var result = try await Process.git(args, cwd: repoPath, timeout: 90)
        if result.exitCode != 0 {
            if Self.looksLikeMissingLFS(result.stderr) {
                result = try await Process.git(Self.lfsFilterOverride + args, cwd: repoPath, timeout: 90)
            }
            if !force,
               result.exitCode != 0,
               Self.looksLikeDirtyWorktreeRemoveError(result.stderr),
               try await canForceRemoveAfterMissingLFS(worktree.path) {
                result = try await Process.git(
                    Self.lfsFilterOverride + ["worktree", "remove", worktree.path.path, "--force"],
                    cwd: repoPath,
                    timeout: 90
                )
            }
        }
        if result.exitCode != 0 {
            throw WorktreeError.gitFailed(result.stderr)
        }
        if deleteBranchIfMerged && worktree.branch != "(detached)" {
            // Best-effort delete. -d only succeeds if merged; ignore failures.
            _ = try? await Process.git(["branch", "-d", worktree.branch], cwd: repoPath)
        }
    }

    func deletePreflight(worktreePath: URL) async throws -> WorktreeDeletePreflight {
        var reasons: Set<WorktreeDeletePreflightReason> = []

        let hasInitializedSubmodules = try await containsInitializedSubmodules(worktreePath)
        if hasInitializedSubmodules {
            reasons.insert(.containsInitializedSubmodules)
        }

        let worktreeClean: Bool?
        do {
            worktreeClean = try await isWorktreeClean(worktreePath)
        } catch {
            guard hasInitializedSubmodules else { throw error }
            worktreeClean = nil
        }

        if worktreeClean == false {
            reasons.insert(.dirty)
        }

        let submoduleLocalState: SubmoduleLocalState
        if hasInitializedSubmodules {
            do {
                if worktreeClean == nil {
                    submoduleLocalState = .unknown
                } else if try await areInitializedSubmodulesClean(worktreePath) {
                    submoduleLocalState = try await initializedSubmodulesHaveNoLocalState(
                        worktreePath,
                        timeout: 10
                    )
                        ? .none
                        : .present
                } else {
                    submoduleLocalState = .present
                }
            } catch {
                submoduleLocalState = .unknown
            }
        } else {
            submoduleLocalState = .none
        }

        return WorktreeDeletePreflight(reasons: reasons, submoduleLocalState: submoduleLocalState)
    }

    func prune(repoPath: URL) async throws {
        let result = try await Process.git(["worktree", "prune"], cwd: repoPath)
        guard result.exitCode == 0 else { throw WorktreeError.gitFailed(result.stderr) }
    }

    // MARK: - Helpers

    private static let lfsFilterOverride = [
        "-c", "filter.lfs.process=",
        "-c", "filter.lfs.smudge=",
        "-c", "filter.lfs.clean=",
        "-c", "filter.lfs.required=false"
    ]

    private static func looksLikeMissingLFS(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return (lower.contains("command not found")
                || lower.contains("not found")
                || lower.contains("no such file or directory"))
            && (lower.contains("git-lfs") || lower.contains("filter-process"))
    }

    private static func looksLikeDirtyWorktreeRemoveError(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("contains modified or untracked files")
            || lower.contains("is dirty")
            || lower.contains("dirty worktree")
    }

    private func containsInitializedSubmodules(_ path: URL) async throws -> Bool {
        let result = try await Process.git(["submodule", "status", "--recursive"], cwd: path)
        guard result.exitCode == 0 else {
            let paths = try await submodulePathsFromGitmodules(path)
            return paths.contains { relativePath in
                FileManager.default.fileExists(
                    atPath: path.appendingPathComponent(relativePath).appendingPathComponent(".git").path
                )
            }
        }
        return result.stdout.split(separator: "\n").contains { line in
            guard let first = line.first else { return false }
            return first != "-"
        }
    }

    private func submodulePathsFromGitmodules(_ path: URL) async throws -> [String] {
        let result = try await Process.git(
            ["config", "--file", ".gitmodules", "--get-regexp", "path"],
            cwd: path
        )
        if result.exitCode != 0 {
            return []
        }
        return result.stdout
            .split(separator: "\n")
            .compactMap { line in
                line.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init)
            }
    }

    private func isWorktreeClean(_ path: URL) async throws -> Bool {
        let result = try await Process.git(
            ["status", "--porcelain", "--ignore-submodules=none", "--untracked-files=all"],
            cwd: path
        )
        guard result.exitCode == 0 else { throw WorktreeError.gitFailed(result.stderr) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func areInitializedSubmodulesClean(_ path: URL) async throws -> Bool {
        let result = try await Process.git(
            [
                "submodule", "foreach", "--quiet", "--recursive",
                "git status --porcelain --ignore-submodules=none --untracked-files=all"
            ],
            cwd: path
        )
        guard result.exitCode == 0 else { throw WorktreeError.gitFailed(result.stderr) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func initializedSubmodulesHaveNoLocalState(
        _ path: URL,
        timeout: TimeInterval = 120
    ) async throws -> Bool {
        // Reachability set arithmetic for reflog and notes/stash (the
        // perf-critical fix — replaces an O(reflog × remotes) shell loop
        // that timed out on submodules with non-trivial reflogs).
        //
        // Branches and tags get explicit name+oid comparisons via single
        // `ls-remote` calls: rev-list reachability misses the case where
        // a local ref's NAME or annotation differs from the remote while
        // its target commit is already reachable from a remote branch
        // (`my-fix` at origin/main; a retargeted/retagged release tag).
        // Losing that local ref on a force-remove would surprise the user.
        let localStateScript = """
        if test -n "$(git rev-list --max-count=1 --reflog --not --remotes 2>/dev/null)"; then
          echo local-reflog
          exit 0
        fi
        extra=$(git for-each-ref --format='%(refname)' refs/notes refs/stash)
        if test -n "$extra" && test -n "$(git rev-list --max-count=1 $extra --not --remotes 2>/dev/null)"; then
          echo notes-stash
          exit 0
        fi
        # Branches: compare against local remote-tracking refs. No
        # network: refs/remotes/<remote>/<branch> already encodes what
        # the user has fetched. Translate to refs/heads/<branch>=<oid>
        # so a direct join against for-each-ref refs/heads is exact.
        remote_heads=$(git for-each-ref --format='%(refname)=%(objectname)' refs/remotes 2>/dev/null \\
          | awk '/^refs\\/remotes\\/[^\\/]+\\/HEAD=/ { next }
                 { sub(/^refs\\/remotes\\/[^\\/]+\\//, "refs/heads/", $0); print }')
        branch_diff=$(git for-each-ref --format='%(refname)=%(objectname)' refs/heads \\
          | awk -v rt="$remote_heads" '
              BEGIN { n = split(rt, arr, "\\n"); for (i = 1; i <= n; i++) seen[arr[i]] = 1 }
              !seen[$0] { print; exit }
          ')
        if test -n "$branch_diff"; then
          echo "branch-mismatch $branch_diff"
          exit 0
        fi
        # Tags: one network call per submodule. `protocol.file.allow=always`
        # lets the file-protocol test fixtures work; harmless on real
        # remotes. If `ls-remote` fails (offline, dead remote, etc.) any
        # local tag is treated as a mismatch — the safer default: don't
        # force-remove when we can't verify the tag state.
        remote_tags=$(git -c protocol.file.allow=always ls-remote --tags --refs origin 2>/dev/null \\
          | awk '{print $2"="$1}')
        tag_diff=$(git for-each-ref --format='%(refname)=%(objectname)' refs/tags \\
          | awk -v rt="$remote_tags" '
              BEGIN { n = split(rt, arr, "\\n"); for (i = 1; i <= n; i++) seen[arr[i]] = 1 }
              !seen[$0] { print; exit }
          ')
        if test -n "$tag_diff"; then
          echo "tag-mismatch $tag_diff"
        fi
        """
        let result = try await Process.git(
            ["submodule", "foreach", "--quiet", "--recursive", localStateScript],
            cwd: path,
            timeout: timeout
        )
        guard result.exitCode == 0 else { throw WorktreeError.gitFailed(result.stderr) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func canForceRemoveAfterMissingLFS(_ path: URL) async throws -> Bool {
        guard try await isWorktreeCleanAllowingSmudgedLFS(path) else { return false }
        let subsClean = try await areInitializedSubmodulesClean(path)
        guard subsClean else { return false }
        return try await initializedSubmodulesHaveNoLocalState(path)
    }

    private func isWorktreeCleanAllowingSmudgedLFS(_ path: URL) async throws -> Bool {
        let result = try await Process.git(
            Self.lfsFilterOverride + [
                "status", "--porcelain=v2", "-z",
                "--ignore-submodules=none", "--untracked-files=all"
            ],
            cwd: path
        )
        guard result.exitCode == 0 else { throw WorktreeError.gitFailed(result.stderr) }

        let records = result.stdout.split(separator: "\u{0}", omittingEmptySubsequences: true)
        for record in records {
            if record.hasPrefix("? ") { return false }
            guard record.hasPrefix("1 ") else { return false }

            let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
            guard fields.count == 9 else { return false }
            let xy = fields[1]
            guard xy.count == 2,
                  xy.first == ".",
                  xy.last == "M",
                  fields[4] == fields[5]
            else { return false }

            let relativePath = String(fields[8])
            guard try await isCleanLFSFile(relativePath, in: path) else { return false }
        }
        return true
    }

    private func isCleanLFSFile(_ relativePath: String, in worktreePath: URL) async throws -> Bool {
        guard try await usesLFSFilter(relativePath, in: worktreePath),
              let pointer = try await indexLFSPointer(relativePath, in: worktreePath)
        else { return false }

        let fileURL = worktreePath.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        let pointerData = Data(pointer.raw.utf8)
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        if fileSize == UInt64(pointerData.count),
           let data = try? Data(contentsOf: fileURL),
           data == pointerData {
            return true
        }

        let actual = try sha256AndSize(of: fileURL)
        return actual.oid == pointer.oid && actual.size == pointer.size
    }

    private func usesLFSFilter(_ relativePath: String, in worktreePath: URL) async throws -> Bool {
        let result = try await Process.git(["check-attr", "-z", "filter", "--", relativePath], cwd: worktreePath)
        guard result.exitCode == 0 else { throw WorktreeError.gitFailed(result.stderr) }
        let parts = result.stdout.split(separator: "\u{0}", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts[2] == "lfs"
    }

    private func indexLFSPointer(_ relativePath: String, in worktreePath: URL) async throws -> LFSPointer? {
        let listed = try await Process.git(["ls-files", "-s", "--", relativePath], cwd: worktreePath)
        guard listed.exitCode == 0 else { throw WorktreeError.gitFailed(listed.stderr) }
        guard let sha = listed.stdout.split(whereSeparator: \.isWhitespace).dropFirst().first else {
            return nil
        }

        let blob = try await Process.git(["cat-file", "-p", String(sha)], cwd: worktreePath)
        guard blob.exitCode == 0 else { throw WorktreeError.gitFailed(blob.stderr) }
        return Self.parseLFSPointer(blob.stdout)
    }

    private func sha256AndSize(of fileURL: URL) throws -> (oid: String, size: UInt64) {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        var size: UInt64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            size += UInt64(chunk.count)
            hasher.update(data: chunk)
        }
        let oid = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (oid, size)
    }

    private struct LFSPointer {
        let raw: String
        let oid: String
        let size: UInt64
    }

    private static func parseLFSPointer(_ text: String) -> LFSPointer? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "version https://git-lfs.github.com/spec/v1" else { return nil }

        var oid: String?
        var size: UInt64?
        for line in lines {
            if line.hasPrefix("oid sha256:") {
                oid = String(line.dropFirst("oid sha256:".count))
            } else if line.hasPrefix("size ") {
                size = UInt64(line.dropFirst("size ".count))
            }
        }
        guard let oid, oid.count == 64, let size else { return nil }
        return LFSPointer(raw: text, oid: oid, size: size)
    }

    private func existingWorktree(
        repoPath: URL,
        destination: URL,
        projectId: String
    ) async throws -> Worktree? {
        let listed = try await list(repoPath: repoPath, projectId: projectId)
        let normalizedDest = destination.standardizedFileURL.path
        return listed.first { $0.path.standardizedFileURL.path == normalizedDest }
    }

    private func makeWorktree(destination: URL, branch: String, projectId: String) -> Worktree {
        let now = Date()
        return Worktree(
            id: Worktree.makeId(path: destination),
            projectId: projectId,
            name: branch,
            branch: branch,
            path: destination,
            isMainWorktree: false,
            status: .clean,
            lastActivity: now,
            createdAt: now
        )
    }
}
