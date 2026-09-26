import Foundation
import CryptoKit

protocol CheckpointGitRunning: Sendable {
    func run(_ args: [String], cwd: URL, environment: [String: String]) async throws -> ProcessResult
    func runData(_ args: [String], cwd: URL, environment: [String: String]) async throws -> ProcessResultData
    func blobReference(oid: String, cwd: URL, environment: [String: String]) async throws -> CheckpointBlobReference
}

extension CheckpointGitRunning {
    func blobReference(oid: String, cwd: URL, environment: [String: String]) async throws -> CheckpointBlobReference {
        let result = try await runData(["cat-file", "blob", oid], cwd: cwd, environment: environment)
        guard result.exitCode == 0 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
        return CheckpointBlobReference.make(for: result.stdout)
    }
}

/// Git-dir paths one checkpoint operation reads, resolved by a single
/// `rev-parse`. Only the path strings are shared; callers still check each
/// file on disk where the check happens today.
struct CheckpointGitPaths: Equatable, Sendable {
    static let operationMarkerNames = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer"]

    let index: URL
    let indexLock: URL
    /// In `operationMarkerNames` order.
    let operationMarkers: [URL]

    static func resolve(git: any CheckpointGitRunning, cwd: URL) async throws -> Self {
        let names = ["index", "index.lock"] + operationMarkerNames
        let result = try await git.run(["rev-parse", "--path-format=absolute"] + names.flatMap { ["--git-path", $0] },
                                       cwd: cwd, environment: [:])
        guard result.exitCode == 0 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
        var output = result.stdout
        if output.hasSuffix("\n") { output.removeLast() }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == names.count, !lines.contains(where: { $0.isEmpty }) else {
            throw CheckpointSnapshotError.invalidGitOutput
        }
        let urls = lines.map { URL(fileURLWithPath: String($0)) }
        return .init(index: urls[0], indexLock: urls[1], operationMarkers: Array(urls[2...]))
    }
}

struct LiveCheckpointGitRunner: CheckpointGitRunning {
    func run(_ args: [String], cwd: URL, environment: [String: String] = [:]) async throws -> ProcessResult {
        let invocation = try invocation(args, cwd: cwd)
        return try await Process.run(invocation.executable, args: invocation.args, cwd: invocation.cwd,
                                     env: gitEnvironment(environment))
    }

    func runData(_ args: [String], cwd: URL, environment: [String: String] = [:]) async throws -> ProcessResultData {
        let invocation = try invocation(args, cwd: cwd)
        return try await Process.runData(invocation.executable, args: invocation.args, cwd: invocation.cwd,
                                         env: gitEnvironment(environment))
    }

    func blobReference(oid: String, cwd: URL, environment: [String: String] = [:]) async throws -> CheckpointBlobReference {
        let invocation = try invocation(["cat-file", "blob", oid], cwd: cwd)
        return try await streamBlobReference(invocation: invocation, environment: gitEnvironment(environment))
    }

    private func invocation(_ args: [String], cwd: URL) throws -> GitInvocation {
        guard !cwd.isRemoteAlasPath else { throw CheckpointSnapshotError.remoteTarget }
        return GitInvocation.build(gitArgs: args, cwd: cwd, host: nil)
    }

    private func gitEnvironment(_ overrides: [String: String]) -> [String: String] {
        var environment = Process.gitEnv()
        if let index = overrides["GIT_INDEX_FILE"] { environment["GIT_INDEX_FILE"] = index }
        return environment
    }

    private func streamBlobReference(invocation: GitInvocation, environment: [String: String]) async throws -> CheckpointBlobReference {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.args
        process.currentDirectoryURL = invocation.cwd
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let termination = ProcessTerminationWaiter()
        process.terminationHandler = { _ in termination.finish() }

        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed(error.localizedDescription)
        }
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        let referenceTask = Task.detached(priority: .utility) {
            let handle = stdout.fileHandleForReading
            var hasher = SHA256()
            var byteCount: Int64 = 0
            while true {
                let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                byteCount += Int64(chunk.count)
                hasher.update(data: chunk)
            }
            let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return CheckpointBlobReference(sha256: hash, byteCount: byteCount)
        }
        let stderrTask = Task.detached(priority: .utility) {
            stderr.fileHandleForReading.readDataToEndOfFile()
        }

        await termination.wait()
        let reference = try await referenceTask.value
        let errorData = await stderrTask.value
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? ""
            throw ProcessError.nonZeroExit(process.terminationStatus, message)
        }
        return reference
    }
}

private final class ProcessTerminationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    func finish() {
        let toResume: CheckedContinuation<Void, Never>?
        lock.lock()
        finished = true
        toResume = continuation
        continuation = nil
        lock.unlock()
        toResume?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
