import Foundation
import Observation

/// Injectable gg process runner, mirroring `CodeHostCommandRunning` so
/// tests can fake CLI output. Local-only in phase 1 (no SSH rewrite).
protocol GGCommandRunning: Sendable {
    func run(args: [String], cwd: URL?) async throws -> ProcessResult
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
