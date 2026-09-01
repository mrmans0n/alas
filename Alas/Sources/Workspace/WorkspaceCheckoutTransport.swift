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
        var availability: WorkspaceCheckoutMemberAvailability

        init(
            id: UUID,
            projectID: String,
            path: String,
            availability: WorkspaceCheckoutMemberAvailability = .pending
        ) {
            self.id = id
            self.projectID = projectID
            self.path = path
            self.availability = availability
        }
    }

    var version: Int = Self.version
    var checkoutID: UUID
    var rootPath: String
    var branch: String
    var members: [Member]
}

enum WorkspaceCheckoutManifestError: Error, Equatable, Sendable {
    case checkoutRootAlreadyClaimed(String)
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
    private let localWrite: @Sendable (Data, URL, Data.WritingOptions) throws -> Void

    init(
        remote: WorkspaceRemoteTransport = .init(),
        localWrite: @escaping @Sendable (Data, URL, Data.WritingOptions) throws -> Void = { data, url, options in
            try data.write(to: url, options: options)
        }
    ) {
        self.remote = remote
        self.localWrite = localWrite
    }

    func write(_ manifest: WorkspaceCheckoutManifest, to rootPath: String, location: ExecutionLocation) async throws {
        let data = try JSONEncoder.workspaceManifest.encode(manifest)
        let target = URL(fileURLWithPath: rootPath).appendingPathComponent(WorkspaceCheckoutManifest.fileName).path
        switch location.normalized {
        case .local:
            let rootURL = URL(fileURLWithPath: rootPath)
            let targetURL = URL(fileURLWithPath: target)
            if try existingManifestAtTargetBelongsToCheckout(targetURL, checkoutID: manifest.checkoutID) {
                try localWrite(data, targetURL, .atomic)
            } else {
                if FileManager.default.fileExists(atPath: rootURL.path) {
                    throw WorkspaceCheckoutManifestError.checkoutRootAlreadyClaimed(rootPath)
                }
                do {
                    try FileManager.default.createDirectory(at: rootURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
                } catch {
                    if (error as? CocoaError)?.code == .fileWriteFileExists {
                        throw WorkspaceCheckoutManifestError.checkoutRootAlreadyClaimed(rootPath)
                    }
                    throw WorkspaceCheckoutManifestError.writeFailed(error.localizedDescription)
                }
                do {
                    try localWrite(data, targetURL, .withoutOverwriting)
                } catch {
                    if try existingManifestAtTargetBelongsToCheckout(targetURL, checkoutID: manifest.checkoutID) {
                        try localWrite(data, targetURL, .atomic)
                        return
                    }
                    guard !FileManager.default.fileExists(atPath: targetURL.path) else {
                        throw WorkspaceCheckoutManifestError.checkoutRootAlreadyClaimed(rootPath)
                    }
                    removeEmptyDirectory(rootURL)
                    throw WorkspaceCheckoutManifestError.writeFailed(error.localizedDescription)
                }
            }
        case .ssh(let host):
            let temporary = "\(target).tmp-\(UUID().uuidString)"
            let payload = String(decoding: data, as: UTF8.self)
            let expectedCheckoutID = "\"checkoutID\":\"\(manifest.checkoutID.uuidString)\""
            let parentPath = URL(fileURLWithPath: rootPath).deletingLastPathComponent().path
            let command = """
            umask 077
            if [ -e \(SSHCommand.shellQuote(target)) ]; then
              grep -F \(SSHCommand.shellQuote(expectedCheckoutID)) \(SSHCommand.shellQuote(target)) >/dev/null 2>&1 || exit 73
              printf %s \(SSHCommand.shellQuote(payload)) > \(SSHCommand.shellQuote(temporary)) || { rm -f \(SSHCommand.shellQuote(temporary)); exit 74; }
              mv \(SSHCommand.shellQuote(temporary)) \(SSHCommand.shellQuote(target))
            else
              mkdir -p \(SSHCommand.shellQuote(parentPath)) || exit 74
              mkdir \(SSHCommand.shellQuote(rootPath)) 2>/dev/null || exit 73
              printf %s \(SSHCommand.shellQuote(payload)) > \(SSHCommand.shellQuote(temporary)) || { rm -f \(SSHCommand.shellQuote(temporary)); rmdir \(SSHCommand.shellQuote(rootPath)) 2>/dev/null; exit 74; }
              if ln \(SSHCommand.shellQuote(temporary)) \(SSHCommand.shellQuote(target)) 2>/dev/null; then
                rm -f \(SSHCommand.shellQuote(temporary))
              elif [ -e \(SSHCommand.shellQuote(target)) ] && grep -F \(SSHCommand.shellQuote(expectedCheckoutID)) \(SSHCommand.shellQuote(target)) >/dev/null 2>&1; then
                mv \(SSHCommand.shellQuote(temporary)) \(SSHCommand.shellQuote(target))
              else
                rm -f \(SSHCommand.shellQuote(temporary))
                exit 73
              fi
            fi
            """
            let result = try await remote.run(host: host, command: command)
            guard result.exitCode == 0 else {
                if result.exitCode == 73 {
                    throw WorkspaceCheckoutManifestError.checkoutRootAlreadyClaimed(rootPath)
                }
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
                .init(id: $0.id, projectID: $0.projectID, path: $0.worktreePath, availability: $0.availability)
            }
        )
        try await write(manifest, to: checkout.rootPath, location: checkout.executionLocation)
    }
}

private func existingManifestAtTargetBelongsToCheckout(_ targetURL: URL, checkoutID: UUID) throws -> Bool {
    guard FileManager.default.fileExists(atPath: targetURL.path) else { return false }
    do {
        let data = try Data(contentsOf: targetURL)
        let existing = try JSONDecoder().decode(WorkspaceCheckoutManifest.self, from: data)
        guard existing.checkoutID == checkoutID else {
            throw WorkspaceCheckoutManifestError.checkoutRootAlreadyClaimed(targetURL.deletingLastPathComponent().path)
        }
        return true
    } catch let error as WorkspaceCheckoutManifestError {
        throw error
    } catch {
        throw WorkspaceCheckoutManifestError.checkoutRootAlreadyClaimed(targetURL.deletingLastPathComponent().path)
    }
}

private func removeEmptyDirectory(_ url: URL) {
    guard let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
          contents.isEmpty
    else { return }
    try? FileManager.default.removeItem(at: url)
}

private extension JSONEncoder {
    static var workspaceManifest: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
