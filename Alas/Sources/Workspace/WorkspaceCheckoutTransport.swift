import Foundation

/// Narrow injectable bridge for Workspace commands that must run on the
/// checkout host but are not Git operations. Git keeps using `Process.git`,
/// which already selects SSH from `RemoteHostRegistry`.
struct WorkspaceRemoteTransport: Sendable {
    typealias Runner = @Sendable (String, [String], TimeInterval) async throws -> ProcessResult

    private let runner: Runner

    init(runner: @escaping Runner = { executable, args, timeout in
        try await Process.run(executable, args: args, timeout: timeout)
    }) {
        self.runner = runner
    }

    func run(host: String, cwd: String? = nil, command: String, timeout: TimeInterval = Process.defaultTimeout) async throws -> ProcessResult {
        let invocation = RemoteExec.invocation(host: host, cwd: cwd, command: command)
        return try await runner(invocation.executable, invocation.args, timeout)
    }

    func run(executable: String, args: [String], timeout: TimeInterval) async throws -> ProcessResult {
        try await runner(executable, args, timeout)
    }
}

protocol WorkspaceRemoteRepositoryValidating: Sendable {
    func validate(host: String, path: String) async throws
}

/// Workspace preflight reuses the add-project remote repository validation
/// contract, while injecting the same transport used by other Workspace SSH
/// operations for deterministic tests.
struct WorkspaceRemoteRepositoryValidator: WorkspaceRemoteRepositoryValidating {
    private let remote: WorkspaceRemoteTransport

    init(remote: WorkspaceRemoteTransport = .init()) { self.remote = remote }

    func validate(host: String, path: String) async throws {
        try await RemoteRepoValidator.validate(host: host, path: path, runner: { executable, args, timeout in
            try await remote.run(executable: executable, args: args, timeout: timeout)
        })
    }
}

struct NoopWorkspaceRemoteRepositoryValidator: WorkspaceRemoteRepositoryValidating {
    func validate(host: String, path: String) async throws {}
}

/// Stable, transport-neutral description written at every checkout root.
/// The SSH path deliberately uses a plain shell command through `RemoteExec`'s
/// transport shape; no Workspace command is added to the remote helper.
struct WorkspaceCheckoutManifest: Codable, Equatable, Sendable {
    static let version = 1
    static let fileName = ".alas-workspace-checkout.json"

    struct Member: Codable, Equatable, Sendable {
        var id: UUID
        var projectID: String
        var path: String
    }

    var version: Int = Self.version
    var checkoutID: UUID
    var rootPath: String
    var branch: String
    var members: [Member]
}

enum WorkspaceCheckoutManifestError: Error, Equatable, Sendable {
    case writeFailed(String)
}

protocol WorkspaceCheckoutManifestWriting: Sendable {
    func writeManifest(for checkout: WorkspaceCheckout) async throws
}

struct NoopWorkspaceCheckoutManifestWriter: WorkspaceCheckoutManifestWriting {
    func writeManifest(for checkout: WorkspaceCheckout) async throws {}
}

struct WorkspaceCheckoutManifestWriter: WorkspaceCheckoutManifestWriting, Sendable {
    private let remote: WorkspaceRemoteTransport

    init(remote: WorkspaceRemoteTransport = .init()) {
        self.remote = remote
    }

    func write(_ manifest: WorkspaceCheckoutManifest, to rootPath: String, location: ExecutionLocation) async throws {
        let data = try JSONEncoder.workspaceManifest.encode(manifest)
        let target = URL(fileURLWithPath: rootPath).appendingPathComponent(WorkspaceCheckoutManifest.fileName).path
        switch location.normalized {
        case .local:
            try FileManager.default.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: target), options: .atomic)
        case .ssh(let host):
            let temporary = "\(target).tmp-\(UUID().uuidString)"
            let payload = String(decoding: data, as: UTF8.self)
            let command = "mkdir -p \(SSHCommand.shellQuote(rootPath)) && umask 077 && printf %s \(SSHCommand.shellQuote(payload)) > \(SSHCommand.shellQuote(temporary)) && mv \(SSHCommand.shellQuote(temporary)) \(SSHCommand.shellQuote(target))"
            let result = try await remote.run(host: host, command: command)
            guard result.exitCode == 0 else {
                throw WorkspaceCheckoutManifestError.writeFailed(result.stderr)
            }
        }
    }

    func writeManifest(for checkout: WorkspaceCheckout) async throws {
        let manifest = WorkspaceCheckoutManifest(
            checkoutID: checkout.id,
            rootPath: checkout.rootPath,
            branch: checkout.branch,
            members: checkout.members.map {
                .init(id: $0.id, projectID: $0.projectID, path: $0.worktreePath)
            }
        )
        try await write(manifest, to: checkout.rootPath, location: checkout.executionLocation)
    }
}

private extension JSONEncoder {
    static var workspaceManifest: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
