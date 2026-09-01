import Foundation

/// Read-only Git facts needed to turn a checkout request into a durable plan.
/// Mutation deliberately lives in the later checkout coordinator.
protocol WorkspaceGitInspecting: Sendable {
    func resolveRevision(at repositoryPath: String, location: ExecutionLocation, ref: String) async throws -> String
    func branchDisposition(named branch: String, at repositoryPath: String, location: ExecutionLocation) async throws -> WorkspaceBranchDisposition
}

enum WorkspaceBranchDisposition: Equatable, Sendable {
    case available
    case reusable(atCommit: String)
    case checkedOut
    case unsafeReuse
}

/// Read-only filesystem facts needed by checkout preflight.
protocol WorkspacePathInspecting: Sendable {
    func resolvedRootPath(_ path: String, location: ExecutionLocation) async -> String?
    func exists(at path: String, location: ExecutionLocation) async -> Bool
    func isCreatableDirectory(at path: String, location: ExecutionLocation) async -> Bool
    func destinationCollisionKey(for path: String, location: ExecutionLocation) async -> String
}

extension WorkspacePathInspecting {
    func resolvedRootPath(_ path: String, location: ExecutionLocation) async -> String? {
        WorkspaceCheckoutPreflight.normalizedPath(path, location: location)
    }

    func destinationCollisionKey(for path: String, location: ExecutionLocation) async -> String {
        path
    }
}

struct WorkspaceCheckoutRequest: Sendable {
    var workspace: Workspace
    var branch: String
    var rootPath: String
    var baseReference: String
    var memberBaseReferences: [UUID: String]
    var checkoutID: UUID
    var checkoutMemberIDs: [UUID: UUID]

    init(
        workspace: Workspace,
        branch: String,
        rootPath: String,
        baseReference: String,
        memberBaseReferences: [UUID: String] = [:],
        checkoutID: UUID = UUID(),
        checkoutMemberIDs: [UUID: UUID] = [:]
    ) {
        self.workspace = workspace
        self.branch = branch
        self.rootPath = rootPath
        self.baseReference = baseReference
        self.memberBaseReferences = memberBaseReferences
        self.checkoutID = checkoutID
        self.checkoutMemberIDs = checkoutMemberIDs
    }
}

struct FrozenWorkspaceCheckoutPlan: Equatable, Sendable {
    struct Member: Equatable, Sendable {
        var checkoutMemberID: UUID
        var workspaceMemberID: UUID
        var projectID: String
        var sourceRepositoryPath: String
        var destinationPath: String
        var baseReference: String
        var baseCommit: String
        var branchIntent: WorkspaceBranchIntent
    }

    var checkoutID: UUID
    var workspaceID: UUID
    var executionLocation: ExecutionLocation
    var branch: String
    var rootPath: String
    var members: [Member]
    var warnings: [WorkspaceDiagnostic] = []
}

enum WorkspaceCheckoutPreflightResult: Equatable, Sendable {
    case success(FrozenWorkspaceCheckoutPlan)
    case failure([WorkspaceDiagnostic])
}

struct WorkspaceCheckoutPreflight: Sendable {
    private let projectsByID: [String: [ProjectConfig]]
    private let git: any WorkspaceGitInspecting
    private let paths: any WorkspacePathInspecting
    private let remoteValidator: any WorkspaceRemoteRepositoryValidating

    init(
        projects: [ProjectConfig],
        git: any WorkspaceGitInspecting = GitService(),
        paths: any WorkspacePathInspecting = WorkspacePathInspector(),
        remoteValidator: any WorkspaceRemoteRepositoryValidating = WorkspaceRemoteRepositoryValidator()
    ) {
        self.projectsByID = Dictionary(grouping: projects, by: \.id)
        self.git = git
        self.paths = paths
        self.remoteValidator = remoteValidator
    }

    func prepare(_ request: WorkspaceCheckoutRequest) async -> WorkspaceCheckoutPreflightResult {
        let location = request.workspace.executionLocation.normalized
        let rootPath = await paths.resolvedRootPath(request.rootPath, location: location) ?? ""
        var messages: [String] = []
        if case .invalid = GitNameValidator.validateBranchName(request.branch) {
            messages.append("Branch '\(request.branch)' is invalid.")
        }
        if rootPath.isEmpty {
            messages.append("Checkout root is required.")
        }
        for projectID in projectsByID.keys.sorted() where projectsByID[projectID]?.count != 1 {
            messages.append("Project '\(projectID)' is duplicated.")
        }

        var seenProjects = Set<String>()
        for (index, member) in request.workspace.members.enumerated() where !seenProjects.insert(member.projectID).inserted {
            messages.append("Workspace member \(index + 1) duplicates Project '\(member.projectID)'.")
        }

        var resolved: [(WorkspaceMember, ProjectConfig, String, String)] = []
        var warnings: [WorkspaceDiagnostic] = []
        for (index, member) in request.workspace.members.enumerated() {
            guard let projects = projectsByID[member.projectID], projects.count == 1,
                  let project = projects.first else {
                messages.append("Workspace member \(index + 1) references missing Project '\(member.projectID)'.")
                continue
            }
            guard Self.location(of: project) == location else {
                messages.append("Workspace member \(index + 1) Project '\(member.projectID)' is not on the Workspace execution location.")
                continue
            }
            if case .ssh(let host) = location {
                do {
                    try await remoteValidator.validate(host: host, path: project.path)
                } catch {
                    messages.append("Workspace member \(index + 1) could not validate its remote repository.")
                    continue
                }
            }
            let base = request.memberBaseReferences[member.id] ?? request.baseReference
            guard !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                messages.append("Workspace member \(index + 1) has no base reference.")
                continue
            }
            do {
                let commit = try await git.resolveRevision(at: project.path, location: location, ref: base)
                resolved.append((member, project, base, commit))
            } catch {
                // A locally cached tracking ref is safe only as an immutable
                // fallback: we still freeze the exact commit in the plan and
                // never fetch or substitute a branch during creation.
                if let cachedBase = Self.cachedFallback(for: base),
                   let commit = try? await git.resolveRevision(at: project.path, location: location, ref: cachedBase) {
                    resolved.append((member, project, base, commit))
                    warnings.append(.init(severity: .warning, message: "Workspace member \(index + 1) is using cached ref '\(cachedBase)' for '\(base)'."))
                } else {
                    messages.append("Workspace member \(index + 1) could not resolve base '\(base)'.")
                }
            }
        }

        if !rootPath.isEmpty {
            if await paths.exists(at: rootPath, location: location) {
                messages.append("Checkout root '\(rootPath)' already exists.")
            } else if !(await paths.isCreatableDirectory(at: rootPath, location: location)) {
                messages.append("Checkout root '\(rootPath)' cannot be created.")
            }
        }

        var destinations = Set<String>()
        var plans: [FrozenWorkspaceCheckoutPlan.Member] = []
        for (index, item) in resolved.enumerated() {
            // The checkout path is repository-root-derived, not display-name-derived:
            // changing a Project's label must not change a durable checkout layout.
            let destinationName = Self.lastPathComponent(item.1.path, location: location)
            let destination = Self.appendingPathComponent(destinationName, to: rootPath, location: location)
            let destinationKey = await paths.destinationCollisionKey(for: destination, location: location)
            let memberIndex = request.workspace.members.firstIndex(where: { $0.id == item.0.id })! + 1
            var memberHasError = false
            if !destinations.insert(destinationKey).inserted {
                messages.append("Workspace member \(memberIndex) has a duplicate destination '\(destination)'.")
                memberHasError = true
            }
            if await paths.exists(at: destination, location: location) {
                messages.append("Workspace member \(memberIndex) destination '\(destination)' already exists.")
                memberHasError = true
            }
            do {
                let disposition = try await git.branchDisposition(named: request.branch, at: item.1.path, location: location)
                let intent: WorkspaceBranchIntent?
                switch disposition {
                case .available:
                    intent = .create(atCommit: item.3)
                case .reusable(let commit) where commit == item.3:
                    intent = .reuse
                case .reusable, .unsafeReuse:
                    messages.append("Workspace member \(memberIndex) cannot safely reuse branch '\(request.branch)'.")
                    memberHasError = true
                    intent = nil
                case .checkedOut:
                    messages.append("Workspace member \(memberIndex) branch '\(request.branch)' is already checked out.")
                    memberHasError = true
                    intent = nil
                }
                if let intent, !memberHasError {
                    plans.append(.init(
                        checkoutMemberID: request.checkoutMemberIDs[item.0.id] ?? UUID(),
                        workspaceMemberID: item.0.id,
                        projectID: item.1.id,
                        sourceRepositoryPath: item.1.path,
                        destinationPath: destination,
                        baseReference: item.2,
                        baseCommit: item.3,
                        branchIntent: intent
                    ))
                }
            } catch {
                messages.append("Workspace member \(memberIndex) could not inspect branch '\(request.branch)'.")
            }
            _ = index
        }

        guard messages.isEmpty, plans.count == request.workspace.members.count else {
            return .failure(messages.map { WorkspaceDiagnostic(severity: .error, message: $0) })
        }
        return .success(.init(
            checkoutID: request.checkoutID,
            workspaceID: request.workspace.id,
            executionLocation: location,
            branch: request.branch,
            rootPath: rootPath,
            members: plans,
            warnings: warnings
        ))
    }

    private static func location(of project: ProjectConfig) -> ExecutionLocation {
        project.host.map { .ssh($0) } ?? .local
    }

    fileprivate static func normalizedPath(_ path: String, location: ExecutionLocation) -> String {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        switch location.normalized {
        case .local:
            return URL(fileURLWithPath: path).standardizedFileURL.path
        case .ssh:
            return path.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func lastPathComponent(_ path: String, location: ExecutionLocation) -> String {
        switch location.normalized {
        case .local:
            return URL(fileURLWithPath: path).lastPathComponent
        case .ssh:
            return path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
        }
    }

    private static func appendingPathComponent(_ component: String, to rootPath: String, location: ExecutionLocation) -> String {
        switch location.normalized {
        case .local:
            return URL(fileURLWithPath: rootPath).appendingPathComponent(component).path
        case .ssh:
            return rootPath.hasSuffix("/") ? rootPath + component : rootPath + "/" + component
        }
    }

    private static func cachedFallback(for ref: String) -> String? {
        guard ref.hasPrefix("origin/"), ref.count > "origin/".count else { return nil }
        return "refs/remotes/\(ref)"
    }
}

extension GitService: WorkspaceGitInspecting {
    func resolveRevision(at repositoryPath: String, ref: String) async throws -> String {
        try await resolveRevision(at: repositoryPath, location: .local, ref: ref)
    }

    func resolveRevision(at repositoryPath: String, location: ExecutionLocation, ref: String) async throws -> String {
        switch location.normalized {
        case .local:
            let revision = try await Process.git(
                ["rev-parse", "--verify", "\(ref)^{commit}"],
                cwd: URL(fileURLWithPath: repositoryPath),
                usesRemoteHostRegistry: false
            )
            guard revision.exitCode == 0 else {
                throw WorkspaceCheckoutPreflightProbeError.gitInspectionFailed(revision.stderr)
            }
            return revision.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        case .ssh(let host):
            let revision = SSHCommand.shellQuote("\(ref)^{commit}")
            let command = "git -C \(SSHCommand.shellQuote(repositoryPath)) rev-parse --verify \(revision)"
            let result = try await WorkspaceRemoteTransport().run(host: host, command: command)
            guard result.exitCode == 0 else {
                throw WorkspaceCheckoutPreflightProbeError.gitInspectionFailed(result.stderr)
            }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func branchDisposition(named branch: String, at repositoryPath: String) async throws -> WorkspaceBranchDisposition {
        try await branchDisposition(named: branch, at: repositoryPath, location: .local)
    }

    func branchDisposition(named branch: String, at repositoryPath: String, location: ExecutionLocation) async throws -> WorkspaceBranchDisposition {
        switch location.normalized {
        case .local:
            return try await localBranchDisposition(named: branch, at: repositoryPath)
        case .ssh(let host):
            return try await remoteBranchDisposition(named: branch, at: repositoryPath, host: host)
        }
    }

    private func localBranchDisposition(named branch: String, at repositoryPath: String) async throws -> WorkspaceBranchDisposition {
        let repository = URL(fileURLWithPath: repositoryPath)
        let ref = try await Process.git(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], cwd: repository, usesRemoteHostRegistry: false)
        if ref.exitCode == 1 { return .available }
        guard ref.exitCode == 0 else {
            throw WorkspaceCheckoutPreflightProbeError.gitInspectionFailed(ref.stderr)
        }
        let commit = try await resolveRevision(at: repositoryPath, location: .local, ref: branch)
        let worktrees = try await Process.git(["worktree", "list", "--porcelain"], cwd: repository, usesRemoteHostRegistry: false)
        guard worktrees.exitCode == 0 else { return .unsafeReuse }
        let isCheckedOut = worktrees.stdout.split(separator: "\n").contains { $0 == "branch refs/heads/\(branch)" }
        return isCheckedOut ? .checkedOut : .reusable(atCommit: commit)
    }

    private func remoteBranchDisposition(named branch: String, at repositoryPath: String, host: String) async throws -> WorkspaceBranchDisposition {
        let remote = WorkspaceRemoteTransport()
        let branchRef = "refs/heads/\(branch)"
        let check = try await remote.run(
            host: host,
            command: "git -C \(SSHCommand.shellQuote(repositoryPath)) show-ref --verify --quiet \(SSHCommand.shellQuote(branchRef))"
        )
        if check.exitCode == 1 { return .available }
        guard check.exitCode == 0 else {
            throw WorkspaceCheckoutPreflightProbeError.gitInspectionFailed(check.stderr)
        }
        let commit = try await resolveRevision(at: repositoryPath, location: .ssh(host), ref: branch)
        let worktrees = try await remote.run(
            host: host,
            command: "git -C \(SSHCommand.shellQuote(repositoryPath)) worktree list --porcelain"
        )
        guard worktrees.exitCode == 0 else { return .unsafeReuse }
        let isCheckedOut = worktrees.stdout.split(separator: "\n").contains { $0 == "branch \(branchRef)" }
        return isCheckedOut ? .checkedOut : .reusable(atCommit: commit)
    }
}

private enum WorkspaceCheckoutPreflightProbeError: Error {
    case gitInspectionFailed(String)
}

struct WorkspacePathInspector: WorkspacePathInspecting {
    private let remote: WorkspaceRemoteTransport

    init(remote: WorkspaceRemoteTransport = .init()) {
        self.remote = remote
    }

    func resolvedRootPath(_ path: String, location: ExecutionLocation) async -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        switch location.normalized {
        case .local:
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        case .ssh(let host):
            let command = """
            raw=\(SSHCommand.shellQuote(trimmed))
            case "$raw" in
              "~") p="$HOME" ;;
              "~/"*) p="$HOME/${raw#??}" ;;
              /*) p="$raw" ;;
              *) p="$PWD/$raw" ;;
            esac
            suffix=
            while [ ! -e "$p" ] && [ ! -L "$p" ]; do
              base=$(basename "$p") || exit 2
              suffix="/$base$suffix"
              next=$(dirname "$p") || exit 2
              [ "$next" = "$p" ] && exit 2
              p="$next"
            done
            resolved=$(cd "$p" 2>/dev/null && pwd -P) || exit 2
            printf '%s\\n' "$resolved$suffix"
            """
            guard let result = try? await remote.run(host: host, command: command),
                  result.exitCode == 0
            else { return nil }
            let resolved = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return resolved.isEmpty ? nil : resolved
        }
    }

    func exists(at path: String, location: ExecutionLocation) async -> Bool {
        switch location.normalized {
        case .local:
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
            return (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
        case .ssh(let host):
            let quoted = SSHCommand.shellQuote(path)
            guard let result = try? await remote.run(host: host, command: "test -e \(quoted) || test -L \(quoted)") else { return true }
            // An SSH transport failure is not evidence that the destination
            // is absent. Treat it as occupied so preflight cannot create on a
            // host whose current state it could not inspect.
            return result.exitCode == 0 || RemoteExec.isConnectionFailure(exitCode: result.exitCode)
        }
    }

    func isCreatableDirectory(at path: String, location: ExecutionLocation) async -> Bool {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        switch location.normalized {
        case .local:
            var candidate = URL(fileURLWithPath: parent)
            var isDirectory = ObjCBool(false)
            while !FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
                let next = candidate.deletingLastPathComponent()
                guard next.path != candidate.path else { return false }
                candidate = next
                isDirectory = false
            }
            return isDirectory.boolValue && FileManager.default.isWritableFile(atPath: candidate.path)
        case .ssh(let host):
            let quotedParent = SSHCommand.shellQuote(parent)
            let command = """
            p=\(quotedParent); while [ ! -e "$p" ] && [ ! -L "$p" ]; do next=$(dirname "$p"); [ "$next" = "$p" ] && exit 1; p="$next"; done; test -d "$p" && test -w "$p"
            """
            guard let result = try? await remote.run(host: host, command: command) else { return false }
            return result.exitCode == 0
        }
    }

    func destinationCollisionKey(for path: String, location: ExecutionLocation) async -> String {
        switch location.normalized {
        case .local:
            return Self.localVolumeSupportsCaseSensitiveNames(for: path) ? path : path.lowercased()
        case .ssh:
            return path.lowercased()
        }
    }

    private static func localVolumeSupportsCaseSensitiveNames(for path: String) -> Bool {
        var candidate = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL
        var isDirectory = ObjCBool(false)
        while !FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
            let next = candidate.deletingLastPathComponent()
            guard next.path != candidate.path else { return true }
            candidate = next
            isDirectory = false
        }
        guard isDirectory.boolValue,
              let values = try? candidate.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]),
              let caseSensitive = values.volumeSupportsCaseSensitiveNames
        else { return true }
        return caseSensitive
    }
}
