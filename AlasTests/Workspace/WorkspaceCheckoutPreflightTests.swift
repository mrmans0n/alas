import Foundation
import Testing
@testable import Alas

@Suite("Workspace checkout preflight")
struct WorkspaceCheckoutPreflightTests {
    @Test func producesFrozenPlansInWorkspaceMemberOrderWithoutMutating() async {
        let first = WorkspaceMember(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            projectID: "one",
            fallbackProjectName: "One",
            fallbackRepositoryRoot: "/repos/one"
        )
        let second = WorkspaceMember(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            projectID: "two",
            fallbackProjectName: "Two",
            fallbackRepositoryRoot: "/repos/two"
        )
        let workspace = Workspace(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            name: "Release",
            executionLocation: .local,
            members: [first, second]
        )
        let projects = [
            project(id: "one", name: "One", path: "/repos/one"),
            project(id: "two", name: "Two", path: "/repos/two")
        ]
        let git = GitProbe(
            resolutions: ["/repos/one": "one-commit", "/repos/two": "two-commit"],
            branches: ["/repos/one": .available, "/repos/two": .available]
        )
        let paths = PathProbe()
        let preflight = WorkspaceCheckoutPreflight(projects: projects, git: git, paths: paths)

        let result = await preflight.prepare(.init(
            workspace: workspace,
            branch: "release/1091",
            rootPath: "/checkouts/release",
            baseReference: "main"
        ))

        guard case .success(let plan) = result else {
            Issue.record("Expected a frozen plan")
            return
        }
        #expect(plan.rootPath == "/checkouts/release")
        #expect(plan.members.map(\.workspaceMemberID) == [first.id, second.id])
        #expect(plan.members.map(\.destinationPath) == ["/checkouts/release/one", "/checkouts/release/two"])
        #expect(plan.members.map(\.sourceRepositoryPath) == ["/repos/one", "/repos/two"])
        #expect(plan.members.map(\.baseCommit) == ["one-commit", "two-commit"])
        #expect(plan.members.allSatisfy { $0.branchIntent == .create(atCommit: $0.baseCommit) })
        #expect(await git.mutationCount == 0)
        #expect(paths.mutationCount == 0)
    }

    @Test func usesMemberBaseOverridesAndFreezesSafeBranchReuse() async {
        let member = WorkspaceMember(projectID: "one", fallbackProjectName: "One", fallbackRepositoryRoot: "/repos/one")
        let workspace = Workspace(name: "Release", executionLocation: .local, members: [member])
        let git = GitProbe(
            resolutions: ["/repos/one": "base-commit"],
            branches: ["/repos/one": .reusable("base-commit")]
        )
        let preflight = WorkspaceCheckoutPreflight(projects: [project(id: "one", name: "Renamed", path: "/repos/one")], git: git, paths: PathProbe())

        let result = await preflight.prepare(.init(
            workspace: workspace,
            branch: "release/1091",
            rootPath: "/checkouts/release",
            baseReference: "main",
            memberBaseReferences: [member.id: "origin/stable"]
        ))

        guard case .success(let plan) = result, let plannedMember = plan.members.first else {
            Issue.record("Expected a reusable frozen plan")
            return
        }
        #expect(plannedMember.baseReference == "origin/stable")
        #expect(plannedMember.baseCommit == "base-commit")
        #expect(plannedMember.branchIntent == .reuse)
        #expect(plannedMember.destinationPath == "/checkouts/release/one")
    }

    @Test func derivesDestinationFromResolvedProjectPathInsteadOfStaleFallback() async {
        let member = WorkspaceMember(
            projectID: "one",
            fallbackProjectName: "One",
            fallbackRepositoryRoot: "/repos/old-name"
        )
        let workspace = Workspace(name: "Release", executionLocation: .local, members: [member])
        let git = GitProbe(
            resolutions: ["/repos/current-name": "base-commit"],
            branches: ["/repos/current-name": .available]
        )
        let preflight = WorkspaceCheckoutPreflight(
            projects: [project(id: "one", name: "Renamed", path: "/repos/current-name")],
            git: git,
            paths: PathProbe()
        )

        let result = await preflight.prepare(.init(
            workspace: workspace,
            branch: "release/1091",
            rootPath: "/checkouts/release",
            baseReference: "main"
        ))

        guard case .success(let plan) = result, let plannedMember = plan.members.first else {
            Issue.record("Expected a frozen plan")
            return
        }
        #expect(plannedMember.sourceRepositoryPath == "/repos/current-name")
        #expect(plannedMember.destinationPath == "/checkouts/release/current-name")
    }

    @Test func reportsHostBaseBranchAndDestinationFailuresTogetherWithoutMutation() async {
        let local = WorkspaceMember(projectID: "local", fallbackProjectName: "Local", fallbackRepositoryRoot: "/repos/shared")
        let remote = WorkspaceMember(projectID: "remote", fallbackProjectName: "Remote", fallbackRepositoryRoot: "/repos/remote")
        let unresolved = WorkspaceMember(projectID: "unresolved", fallbackProjectName: "Unresolved", fallbackRepositoryRoot: "/repos/shared")
        let workspace = Workspace(name: "Release", executionLocation: .local, members: [local, remote, unresolved])
        let git = GitProbe(
            resolutions: ["/repos/local": "local-commit"],
            branches: ["/repos/local": .checkedOut]
        )
        let paths = PathProbe(existing: ["/checkouts/release", "/checkouts/release/local"])
        let preflight = WorkspaceCheckoutPreflight(projects: [
            project(id: "local", name: "Local", path: "/repos/local"),
            project(id: "remote", name: "Remote", path: "/repos/remote", host: "builder.example"),
            project(id: "unresolved", name: "Unresolved", path: "/repos/unresolved")
        ], git: git, paths: paths)

        let result = await preflight.prepare(.init(
            workspace: workspace,
            branch: "release/1091",
            rootPath: "/checkouts/release",
            baseReference: "main"
        ))

        guard case .failure(let diagnostics) = result else {
            Issue.record("Expected accumulated diagnostics")
            return
        }
        let messages = diagnostics.map(\.message)
        #expect(messages.contains("Workspace member 2 Project 'remote' is not on the Workspace execution location."))
        #expect(messages.contains("Workspace member 3 could not resolve base 'main'."))
        #expect(messages.contains("Checkout root '/checkouts/release' already exists."))
        #expect(messages.contains("Workspace member 1 destination '/checkouts/release/local' already exists."))
        #expect(messages.contains("Workspace member 1 branch 'release/1091' is already checked out."))
        #expect(await git.mutationCount == 0)
        #expect(paths.mutationCount == 0)
    }

    @Test func rejectsDanglingSymlinkCheckoutRootAsOccupied() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-preflight-\(UUID().uuidString)")
        let source = temp.appendingPathComponent("source")
        let root = temp.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: temp.appendingPathComponent("missing"))
        defer { try? FileManager.default.removeItem(at: temp) }
        let member = WorkspaceMember(projectID: "one", fallbackProjectName: "One", fallbackRepositoryRoot: source.path)
        let workspace = Workspace(name: "Release", executionLocation: .local, members: [member])
        let git = GitProbe(
            resolutions: [source.path: "one-commit"],
            branches: [source.path: .available]
        )
        let preflight = WorkspaceCheckoutPreflight(
            projects: [project(id: "one", name: "One", path: source.path)],
            git: git
        )

        let result = await preflight.prepare(.init(
            workspace: workspace,
            branch: "release/1091",
            rootPath: root.path,
            baseReference: "main"
        ))

        guard case .failure(let diagnostics) = result else {
            Issue.record("Expected dangling symlink root to fail preflight")
            return
        }
        #expect(diagnostics.map(\.message).contains("Checkout root '\(root.path)' already exists."))
        #expect(await git.mutationCount == 0)
    }

    @Test func rejectsDuplicateProjectRecordsAndUnsafeBranchReuse() async {
        let member = WorkspaceMember(projectID: "one", fallbackProjectName: "One", fallbackRepositoryRoot: "/repos/one")
        let workspace = Workspace(name: "Release", executionLocation: .local, members: [member])
        let duplicateResult = await WorkspaceCheckoutPreflight(
            projects: [project(id: "one", name: "One", path: "/repos/one"), project(id: "one", name: "Duplicate", path: "/repos/other")],
            git: GitProbe(),
            paths: PathProbe()
        ).prepare(.init(workspace: workspace, branch: "release/1091", rootPath: "/checkouts/release", baseReference: "main"))
        guard case .failure(let duplicateDiagnostics) = duplicateResult else {
            Issue.record("Expected duplicate Project failure")
            return
        }
        #expect(duplicateDiagnostics.map(\.message).contains("Project 'one' is duplicated."))

        let unsafeResult = await WorkspaceCheckoutPreflight(
            projects: [project(id: "one", name: "One", path: "/repos/one")],
            git: GitProbe(resolutions: ["/repos/one": "base"], branches: ["/repos/one": .unsafeReuse]),
            paths: PathProbe()
        ).prepare(.init(workspace: workspace, branch: "release/1091", rootPath: "/checkouts/release", baseReference: "main"))
        guard case .failure(let unsafeDiagnostics) = unsafeResult else {
            Issue.record("Expected unsafe reuse failure")
            return
        }
        #expect(unsafeDiagnostics.map(\.message).contains("Workspace member 1 cannot safely reuse branch 'release/1091'."))
    }

    @Test func gitBranchProbeFailsClosedForUnexpectedShowRefFailure() async {
        await #expect(throws: Error.self) {
            try await GitService().branchDisposition(named: "release/1091", at: "/path/that/does/not/exist")
        }
    }

    @Test func accumulatesDeterministicFailuresBeforeAnyMutation() async {
        let member = WorkspaceMember(projectID: "missing", fallbackProjectName: "Missing", fallbackRepositoryRoot: "/missing")
        let duplicate = WorkspaceMember(projectID: "missing", fallbackProjectName: "Again", fallbackRepositoryRoot: "/again")
        let workspace = Workspace(name: "Release", executionLocation: .local, members: [member, duplicate])
        let git = GitProbe()
        let paths = PathProbe(existing: ["/checkouts/release"])
        let preflight = WorkspaceCheckoutPreflight(projects: [], git: git, paths: paths)

        let result = await preflight.prepare(.init(
            workspace: workspace,
            branch: "bad branch",
            rootPath: "/checkouts/release",
            baseReference: "main"
        ))

        guard case .failure(let diagnostics) = result else {
            Issue.record("Expected diagnostics")
            return
        }
        #expect(diagnostics.map(\.message) == [
            "Branch 'bad branch' is invalid.",
            "Workspace member 2 duplicates Project 'missing'.",
            "Workspace member 1 references missing Project 'missing'.",
            "Workspace member 2 references missing Project 'missing'.",
            "Checkout root '/checkouts/release' already exists."
        ])
        #expect(await git.mutationCount == 0)
        #expect(paths.mutationCount == 0)
    }

    private func project(id: String, name: String, path: String, host: String? = nil) -> ProjectConfig {
        .init(id: id, name: name, path: path, color: "blue", addedAt: .distantPast, host: host)
    }
}

private actor GitProbe: WorkspaceGitInspecting {
    enum Branch: Sendable { case available, reusable(String), checkedOut, unsafeReuse }

    let resolutions: [String: String]
    let branches: [String: Branch]
    private(set) var mutationCount = 0

    init(resolutions: [String: String] = [:], branches: [String: Branch] = [:]) {
        self.resolutions = resolutions
        self.branches = branches
    }

    func resolveRevision(at repositoryPath: String, location: ExecutionLocation, ref: String) async throws -> String {
        guard let value = resolutions[repositoryPath] else { throw ProbeError.unresolved }
        return value
    }

    func branchDisposition(named branch: String, at repositoryPath: String, location: ExecutionLocation) async throws -> WorkspaceBranchDisposition {
        switch branches[repositoryPath] ?? .available {
        case .available: .available
        case .reusable(let commit): .reusable(atCommit: commit)
        case .checkedOut: .checkedOut
        case .unsafeReuse: .unsafeReuse
        }
    }
}

private final class PathProbe: WorkspacePathInspecting, @unchecked Sendable {
    let existing: Set<String>
    private(set) var mutationCount = 0

    init(existing: Set<String> = []) { self.existing = existing }

    func exists(at path: String, location: ExecutionLocation) async -> Bool {
        existing.contains(path)
    }

    func isCreatableDirectory(at path: String, location: ExecutionLocation) async -> Bool {
        !existing.contains(path)
    }
}

private enum ProbeError: Error { case unresolved }
