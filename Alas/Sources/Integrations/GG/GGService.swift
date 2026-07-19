import Foundation
import Observation

/// Injectable gg process runner, mirroring `CodeHostCommandRunning` so
/// tests can fake CLI output. Local-only in phase 1 (no SSH rewrite).
protocol GGCommandRunning: Sendable {
    func run(args: [String], cwd: URL?) async throws -> ProcessResult
    /// Streams stdout lines as they arrive (for `gg sync --jsonl`). Finishes
    /// with `.commandFailed`/`.cliMissing` on a non-zero exit.
    func runStreaming(args: [String], cwd: URL?) -> AsyncThrowingStream<String, Error>
}

extension GGCommandRunning {
    /// Default: buffer the whole command then split into lines. Good enough
    /// for tests and any non-streaming conformer; `ProcessGGCommandRunner`
    /// overrides this with a truly incremental implementation.
    func runStreaming(args: [String], cwd: URL?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await run(args: args, cwd: cwd)
                    for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
                        continuation.yield(String(line))
                    }
                    if result.exitCode == 0 {
                        continuation.finish()
                    } else if result.exitCode == 127 {
                        continuation.finish(throwing: GGServiceError.cliMissing)
                    } else {
                        continuation.finish(throwing: GGServiceError.commandFailed(
                            stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        ))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

struct ProcessGGCommandRunner: GGCommandRunning {
    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        try await Process.run(
            "/usr/bin/env",
            args: ["gg"] + args,
            cwd: cwd,
            env: Process.gitEnv()
        )
    }

    func runStreaming(args: [String], cwd: URL?) -> AsyncThrowingStream<String, Error> {
        Self.streamProcess(executable: "/usr/bin/env", args: ["gg"] + args, cwd: cwd, env: Process.gitEnv())
    }

    /// Pipe-lifecycle core of `runStreaming`, parameterized on the
    /// executable/args so tests can exercise the readability-handler /
    /// write-end-close pattern against a trivial subprocess (e.g.
    /// `/bin/sh -c ...`) without depending on the `gg` binary being
    /// installed.
    static func streamProcess(
        executable: String,
        args: [String],
        cwd: URL?,
        env: [String: String]?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            if let cwd { process.currentDirectoryURL = cwd }
            if let env { process.environment = env }
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let buffer = LineBuffer()
            let stderrAccum = StderrAccumulator()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    if let tail = buffer.flush() { continuation.yield(tail) }
                } else {
                    let chunk = String(decoding: data, as: UTF8.self)
                    for line in buffer.feed(chunk) { continuation.yield(line) }
                }
            }
            // Drain stderr incrementally as it arrives rather than blocking
            // on it in the termination handler — see `Process+Git.swift`'s
            // `run(_:args:...)` for the same pattern and why it matters: a
            // chatty child can fill the ~64KB pipe buffer and block its own
            // `write()` (and therefore its own exit) if nobody is reading.
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    stderrAccum.append(data)
                }
            }
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.finish()
                } else if proc.terminationStatus == 127 {
                    continuation.finish(throwing: GGServiceError.cliMissing)
                } else {
                    continuation.finish(throwing: GGServiceError.commandFailed(
                        stderr: stderrAccum.text().trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.finish(throwing: GGServiceError.commandFailed(stderr: error.localizedDescription))
                return
            }
            // Close the parent's copy of the pipe write ends now that the
            // child has dup'd them. Without this, the kernel keeps
            // reporting "writers still open" on the read side and the
            // readability handlers never see EOF after the child exits —
            // the stream would hang forever waiting for a termination that
            // already happened.
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
            }
        }
    }
}

/// Thread-safe accumulator for stderr bytes read incrementally off a
/// readability handler. Mirrors `Process+Git.swift`'s `ByteAccumulator`
/// (kept separate here since that type is file-private and this call site
/// only needs the final text, not EOF-latching).
private final class StderrAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Stateless read-only facade over the gg CLI (peer to `GitService`).
struct GGService {
    var runner: GGCommandRunning = ProcessGGCommandRunner()

    /// Returns the gg version string ("0.9.8") or nil when gg is not
    /// installed / not on the login-shell PATH.
    func probeVersion() async -> String? {
        guard let result = try? await runner.run(args: ["--version"], cwd: nil),
              result.exitCode == 0
        else { return nil }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // "gg 0.9.8" → "0.9.8"
        return output.split(separator: " ").last.map(String.init)
    }

    /// Loads the current branch's stack via `gg ls --json`. Returns nil
    /// when the branch is not a gg stack (gg emits the all-stacks shape).
    func currentStack(worktreePath: String) async throws -> GGStack? {
        let result: ProcessResult
        do {
            result = try await runner.run(
                args: ["ls", "--json"],
                cwd: URL(fileURLWithPath: worktreePath)
            )
        } catch let error as GGServiceError {
            throw error
        } catch {
            throw GGServiceError.commandFailed(stderr: String(describing: error))
        }
        guard result.exitCode == 0 else {
            if result.exitCode == 127 { throw GGServiceError.cliMissing }
            throw GGServiceError.commandFailed(
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return try GGStackSnapshot.decode(fromJSON: Data(result.stdout.utf8)).stack
    }

    /// Streams `gg sync --jsonl` events. Non-`GGSyncEvent` lines are skipped.
    func sync(worktreePath: String) -> AsyncThrowingStream<GGSyncEvent, Error> {
        let lines = runner.runStreaming(args: ["sync", "--jsonl"], cwd: URL(fileURLWithPath: worktreePath))
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await line in lines {
                        if let event = GGSyncEvent.parse(line: line) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Lands ready entries (bottom-up). `until` lands up to a target
    /// (position/GG-ID/SHA); nil lands all currently-approved entries.
    func land(worktreePath: String, until: String?) async throws -> GGLandResult {
        let args: [String] = until.map { ["land", "--until", $0, "--json"] } ?? ["land", "--all", "--json"]
        let result = try await runChecked(args: args, worktreePath: worktreePath)
        return try GGLandResult.decode(fromJSON: Data(result.stdout.utf8))
    }

    func clean(worktreePath: String) async throws {
        _ = try await runChecked(args: ["clean"], worktreePath: worktreePath)
    }

    func continueOp(worktreePath: String) async throws {
        _ = try await runChecked(args: ["continue"], worktreePath: worktreePath)
    }

    func abortOp(worktreePath: String) async throws {
        _ = try await runChecked(args: ["abort"], worktreePath: worktreePath)
    }

    func checkout(worktreePath: String, target: String) async throws {
        _ = try await runChecked(args: ["mv", target], worktreePath: worktreePath)
    }

    /// Runs a gg command and maps a non-zero exit to `GGServiceError`, the
    /// same way `currentStack` does.
    private func runChecked(args: [String], worktreePath: String) async throws -> ProcessResult {
        let result: ProcessResult
        do {
            result = try await runner.run(args: args, cwd: URL(fileURLWithPath: worktreePath))
        } catch let error as GGServiceError {
            throw error
        } catch {
            throw GGServiceError.commandFailed(stderr: String(describing: error))
        }
        guard result.exitCode == 0 else {
            if result.exitCode == 127 { throw GGServiceError.cliMissing }
            throw GGServiceError.commandFailed(
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }
}

/// Session-cached gg availability, probed once at startup and re-probed
/// (force) after the Settings install flow completes.
@MainActor
@Observable
final class GGAvailability {
    static let shared = GGAvailability()

    private(set) var version: String?
    private(set) var hasProbed = false

    var isInstalled: Bool { version != nil }

    func probe(service: GGService = GGService(), force: Bool = false) async {
        if hasProbed && !force { return }
        version = await service.probeVersion()
        hasProbed = true
    }
}
