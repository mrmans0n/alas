import Foundation
import os

struct ZmxSessionInfo: Equatable, Sendable {
    let name: String
    let startDir: String?
}

/// Thin Swift wrapper around the bundled `zmx` CLI. Exposes the three
/// operations Alas needs (`wrap` for launch, `killSession` for explicit
/// close, `listSessions` for cleanup walks) and falls back to a no-op
/// posture when zmx is unavailable so callers can stay oblivious.
///
/// Not isolated to any actor: all state is set at init and immutable
/// afterwards, so callers from any context can invoke its methods. Methods
/// that wait on a subprocess (`killSession`, `listSessions`) block the
/// calling thread for up to ~5s in the worst case — callers that must
/// stay responsive (e.g. MainActor UI paths) should dispatch into
/// `Task.detached` themselves. `wrap` is pure and safe to call inline.
final class ZmxClient: Sendable {
    let env: ZmxEnv
    private let runner: SubprocessRunner
    private let logger: Logger

    init(
        env: ZmxEnv,
        runner: SubprocessRunner = .system,
        logger: Logger = Logger(subsystem: "io.nlopez.alas", category: "zmx")
    ) {
        self.env = env
        self.runner = runner
        self.logger = logger
        if !env.isAvailable {
            // Logged at construction (once) rather than from `wrap`, so the
            // class can drop its mutable `loggedUnavailable` flag and stay
            // trivially Sendable.
            logger.warning("zmx not bundled or no usable ZMX_DIR — terminal panes will not persist across app quit")
        }
    }

    var isAvailable: Bool { env.isAvailable }

    /// Wrap `plan` in `zmx attach <sessionName> <inner>`. When zmx is not
    /// available, returns `plan` unchanged so the pane still launches as a
    /// plain shell (cross-launch persistence is silently disabled).
    ///
    /// zmx's `attach` subcommand takes everything after the session name as
    /// the command to run — there is no `--` flag-terminator (it would be
    /// treated literally as the program name).
    func wrap(sessionName: String, plan: StartupScriptInstaller.Plan) -> StartupScriptInstaller.Plan {
        // Require BOTH binary AND a safely-resolved zmxDir. If zmxDir is
        // nil (security fallback refused — see ZmxEnv.secureFallback), we
        // intentionally launch a plain shell instead of `zmx attach` with
        // an unpinned ZMX_DIR (which would let zmx default to its own
        // temp dir, re-introducing the unvalidated-path risk we just
        // refused).
        guard env.isAvailable, let binary = env.binaryURL else { return plan }
        return StartupScriptInstaller.Plan(
            executable: binary.path,
            args: ["attach", sessionName, plan.executable] + plan.args,
            envOverrides: plan.envOverrides
        )
    }

    /// Best-effort `zmx kill <name>`. Never throws; logs and swallows
    /// failures so a hung daemon never blocks the close path. Blocks the
    /// caller for up to ~5s (the SubprocessRunner timeout); MainActor
    /// callers should dispatch via `Task.detached`.
    func killSession(name: String) {
        guard env.isAvailable, let binary = env.binaryURL else { return }
        let result = runner.run(binary, ["kill", name], zmxEnv(), 5.0)
        switch result.exitCode {
        case 0?:
            return
        case let code?:
            logger.warning("zmx kill \(name, privacy: .public) exited \(code, privacy: .public): \(result.stderr, privacy: .public)")
        case nil:
            logger.warning("zmx kill \(name, privacy: .public) timed out")
        }
    }

    /// Parse `zmx ls --short` into session names. Returns `[]` on any error
    /// or when zmx is unavailable. Same blocking-up-to-5s caveat as
    /// `killSession`.
    ///
    /// `--short` is required: the default `zmx ls` output is tab-separated
    /// key=value fields (`  name=alas-X\tpid=123\t…`), not bare names, so
    /// orphan-sweep callers would otherwise miss every `alas-*` session.
    func listSessions() -> [String] {
        guard env.isAvailable, let binary = env.binaryURL else { return [] }
        let result = runner.run(binary, ["ls", "--short"], zmxEnv(), 5.0)
        guard result.exitCode == 0 else {
            if let code = result.exitCode {
                logger.warning("zmx ls exited \(code, privacy: .public): \(result.stderr, privacy: .public)")
            } else {
                logger.warning("zmx ls timed out")
            }
            return []
        }
        return result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Parse full `zmx ls` key-value rows. Used for legacy session migration,
    /// where `start_dir` lets us avoid attaching an old unscoped session from
    /// a different worktree.
    func listSessionInfos() -> [ZmxSessionInfo] {
        guard env.isAvailable, let binary = env.binaryURL else { return [] }
        let result = runner.run(binary, ["ls"], zmxEnv(), 5.0)
        guard result.exitCode == 0 else {
            if let code = result.exitCode {
                logger.warning("zmx ls exited \(code, privacy: .public): \(result.stderr, privacy: .public)")
            } else {
                logger.warning("zmx ls timed out")
            }
            return []
        }
        return result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parseSessionInfoLine(String($0)) }
    }

    /// Environment passed to every zmx invocation. Pins `ZMX_DIR` so the
    /// CLI talks to the same daemon/socket dir Alas-spawned shells will use.
    private func zmxEnv() -> [String: String] {
        var inherited = ProcessInfo.processInfo.environment
        if let dir = env.zmxDir { inherited["ZMX_DIR"] = dir.path }
        return inherited
    }

    private func parseSessionInfoLine(_ line: String) -> ZmxSessionInfo? {
        let fields = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: true)
        var name: String?
        var startDir: String?
        for field in fields {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "name": name = String(parts[1])
            case "start_dir": startDir = String(parts[1])
            default: break
            }
        }
        guard let name else { return nil }
        return ZmxSessionInfo(name: name, startDir: startDir)
    }
}
