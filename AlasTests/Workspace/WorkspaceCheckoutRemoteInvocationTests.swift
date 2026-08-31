import Foundation
import Testing
@testable import Alas

@Suite("Workspace checkout remote invocation")
struct WorkspaceCheckoutRemoteInvocationTests {
    @Test func remotePathPreflightUsesTheWorkspaceExactHost() async {
        let runner = RecordingWorkspaceSSHRunner(results: [
            .init(exitCode: 1, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: "")
        ])
        let inspector = WorkspacePathInspector(remote: .init(runner: { executable, args, timeout in
            await runner.run(executable: executable, args: args, timeout: timeout)
        }))

        #expect(await inspector.exists(at: "/srv/checkouts/release", location: .ssh("builder.example")) == false)
        #expect(await inspector.isCreatableDirectory(at: "/srv/checkouts/release", location: .ssh("builder.example")))

        let calls = await runner.calls
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.args.contains("BatchMode=yes") })
        #expect(calls.allSatisfy { $0.args.dropLast().last == "builder.example" })
        #expect(calls[0].args.last?.contains("test -e") == true)
        #expect(calls[0].args.last?.contains("test -L") == true)
        #expect(calls[1].args.last?.contains("test -d") == true)
        #expect(calls[1].args.last?.contains("test -w") == true)
    }

    @Test func remoteConnectionFailureFailsClosedWithoutTryingAnotherHost() async {
        let runner = RecordingWorkspaceSSHRunner(results: [
            .init(exitCode: 255, stdout: "", stderr: "Connection refused")
        ])
        let inspector = WorkspacePathInspector(remote: .init(runner: { executable, args, timeout in
            await runner.run(executable: executable, args: args, timeout: timeout)
        }))

        #expect(await inspector.exists(at: "/srv/checkouts/release", location: .ssh("builder.example")))
        #expect(await runner.calls.count == 1)
    }

    @Test func manifestWriterUsesIdenticalVersionedBytesForLocalAndRemote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-manifest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = WorkspaceCheckoutManifest(checkoutID: UUID(), rootPath: root.path, branch: "release/1091", members: [WorkspaceCheckoutManifest.Member]())
        let writer = WorkspaceCheckoutManifestWriter()

        try await writer.write(manifest, to: root.path, location: .local)
        let local = try Data(contentsOf: root.appendingPathComponent(WorkspaceCheckoutManifest.fileName))

        let runner = RecordingWorkspaceSSHRunner(results: [.init(exitCode: 0, stdout: "", stderr: "")])
        try await WorkspaceCheckoutManifestWriter(remote: .init(runner: { executable, args, timeout in
            await runner.run(executable: executable, args: args, timeout: timeout)
        })).write(
            manifest,
            to: "/srv/checkouts/release",
            location: .ssh("builder.example")
        )
        let call = try #require(await runner.calls.first)
        #expect(call.args.dropLast().last == "builder.example")
        #expect(call.args.last?.contains(".alas-workspace-checkout.json") == true)
        #expect(call.args.last?.contains(String(data: local, encoding: .utf8)!) == true)
    }

    @Test func remoteLineageInspectionUsesTheExactWorkspaceHost() async {
        let memberID = UUID()
        let member = WorkspaceCheckoutMember(
            id: memberID,
            workspaceMemberID: UUID(),
            projectID: "project",
            fallbackProjectName: "Project",
            fallbackRepositoryRoot: "/srv/project",
            worktreePath: "/srv/checkouts/release/project",
            gitLineageID: "lineage",
            plan: .init(checkoutMemberID: memberID, projectID: "project", sourceRepositoryPath: "/srv/project", destinationPath: "/srv/checkouts/release/project", baseReference: "main", baseCommit: "commit", branchIntent: .create(atCommit: "commit"))
        )
        let checkout = WorkspaceCheckout(id: UUID(), workspaceID: UUID(), fallbackWorkspaceName: "Release", executionLocation: .ssh("builder.example"), branch: "release/1091", rootPath: "/srv/checkouts/release", members: [member])
        let runner = RecordingWorkspaceSSHRunner(results: [.init(exitCode: 0, stdout: "lineage\n", stderr: "")])
        let observer = WorkspaceCheckoutObserver(remote: .init(runner: { executable, args, timeout in
            await runner.run(executable: executable, args: args, timeout: timeout)
        }))

        #expect(await observer.observe(member, in: checkout) == .exactLineage("lineage"))
        let call = try! #require(await runner.calls.first)
        #expect(call.args.dropLast().last == "builder.example")
        #expect(call.args.last?.contains("rev-parse --absolute-git-dir") == true)
    }

    @Test func remoteRepositoryValidationReusesTheExistingValidatorInvocation() async throws {
        let runner = RecordingWorkspaceSSHRunner(results: [.init(exitCode: 0, stdout: "true\n", stderr: "")])
        let validator = WorkspaceRemoteRepositoryValidator(remote: .init(runner: { executable, args, timeout in
            await runner.run(executable: executable, args: args, timeout: timeout)
        }))

        try await validator.validate(host: "builder.example", path: "/srv/project")
        let call = try #require(await runner.calls.first)
        #expect(call.args.contains("BatchMode=yes"))
        #expect(call.args.dropLast().last == "builder.example")
        #expect(call.args.last?.contains("git -C") == true)
    }

    @Test func acceptsOneExactSSHHostAndRejectsADifferentHost() async {
        let first = WorkspaceMember(projectID: "one", fallbackProjectName: "One", fallbackRepositoryRoot: "/srv/one")
        let second = WorkspaceMember(projectID: "two", fallbackProjectName: "Two", fallbackRepositoryRoot: "/srv/two")
        let workspace = Workspace(name: "Release", executionLocation: .ssh("builder.example"), members: [first, second])
        let paths = EmptyWorkspacePaths()

        let sameHost = WorkspaceCheckoutPreflight(projects: [
            project(id: "one", path: "/srv/one", host: "builder.example"),
            project(id: "two", path: "/srv/two", host: "builder.example")
        ], git: FixedWorkspaceGit(), paths: paths, remoteValidator: NoopWorkspaceRemoteRepositoryValidator())
        if case .failure(let diagnostics) = await sameHost.prepare(.init(workspace: workspace, branch: "release/1091", rootPath: "/srv/checkouts/release", baseReference: "main")) {
            Issue.record("Expected exact-host success: \(diagnostics)")
        }

        let crossHost = WorkspaceCheckoutPreflight(projects: [
            project(id: "one", path: "/srv/one", host: "builder.example"),
            project(id: "two", path: "/srv/two", host: "other.example")
        ], git: FixedWorkspaceGit(), paths: paths, remoteValidator: NoopWorkspaceRemoteRepositoryValidator())
        guard case .failure(let diagnostics) = await crossHost.prepare(.init(workspace: workspace, branch: "release/1091", rootPath: "/srv/checkouts/release", baseReference: "main")) else {
            Issue.record("Expected cross-host rejection")
            return
        }
        #expect(diagnostics.map(\.message).contains("Workspace member 2 Project 'two' is not on the Workspace execution location."))
    }

    @Test func cachedBaseFallbackWarnsAndStillFreezesItsExactCommit() async {
        let member = WorkspaceMember(projectID: "one", fallbackProjectName: "One", fallbackRepositoryRoot: "/repos/one")
        let workspace = Workspace(name: "Release", executionLocation: .local, members: [member])
        let result = await WorkspaceCheckoutPreflight(
            projects: [.init(id: "one", name: "One", path: "/repos/one", color: "blue", addedAt: .distantPast)],
            git: CachedFallbackGit(),
            paths: EmptyWorkspacePaths()
        ).prepare(.init(workspace: workspace, branch: "release/1091", rootPath: "/checkouts/release", baseReference: "origin/main"))

        guard case .success(let plan) = result else {
            Issue.record("Expected cached fallback plan")
            return
        }
        #expect(plan.members.first?.baseReference == "origin/main")
        #expect(plan.members.first?.baseCommit == "cached-main-commit")
        #expect(plan.warnings.map(\.message) == ["Workspace member 1 is using cached ref 'main' for 'origin/main'."])
    }

    private func project(id: String, path: String, host: String) -> ProjectConfig {
        .init(id: id, name: id, path: path, color: "blue", addedAt: .distantPast, host: host)
    }
}

private actor RecordingWorkspaceSSHRunner {
    struct Call: Sendable { let executable: String
    let args: [String]
    let timeout: TimeInterval }
    private var results: [ProcessResult]
    private(set) var calls: [Call] = []

    init(results: [ProcessResult]) { self.results = results }

    func run(executable: String, args: [String], timeout: TimeInterval) -> ProcessResult {
        calls.append(.init(executable: executable, args: args, timeout: timeout))
        return results.isEmpty ? .init(exitCode: 1, stdout: "", stderr: "") : results.removeFirst()
    }
}

private actor FixedWorkspaceGit: WorkspaceGitInspecting {
    func resolveRevision(at repositoryPath: String, ref: String) async throws -> String { "commit-\(repositoryPath)" }
    func branchDisposition(named branch: String, at repositoryPath: String) async throws -> WorkspaceBranchDisposition { .available }
}

private struct EmptyWorkspacePaths: WorkspacePathInspecting {
    func exists(at path: String, location: ExecutionLocation) async -> Bool { false }
    func isCreatableDirectory(at path: String, location: ExecutionLocation) async -> Bool { true }
}

private actor CachedFallbackGit: WorkspaceGitInspecting {
    func resolveRevision(at repositoryPath: String, ref: String) async throws -> String {
        if ref == "main" { return "cached-main-commit" }
        throw CachedFallbackError.unavailable
    }
    func branchDisposition(named branch: String, at repositoryPath: String) async throws -> WorkspaceBranchDisposition { .available }
}

private enum CachedFallbackError: Error { case unavailable }
