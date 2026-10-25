import Foundation
import AlasFoundation
import AlasPlatform
import AlasACP

/// Starts a login shell inside a detached zmx session on a host with no
/// terminal: `zmx attach` creates the daemon and returns once its stdin (here
/// `/dev/null`) closes, leaving the shell running for peers to attach to.
public struct HostShellLaunch: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let directory: URL

    /// Inherited terminal identity that would describe the launcher's
    /// terminal, not the zmx PTY the shell gets.
    private static let terminalKeys: Set<String> = [
        "TERM", "TERMINFO", "TERMINFO_DIRS", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "COLORTERM", "ZMX_SESSION",
    ]

    /// Nil when zmx is unavailable: a host shell without zmx would die with
    /// its launcher.
    public static func make(
        zmx: ZmxClient,
        sessionName: String,
        directory: URL,
        shell: String,
        shellArguments: [String] = ["-l"],
        environmentOverrides: [String: String] = [:],
        baseEnvironment: [String: String]
    ) -> HostShellLaunch? {
        guard zmx.isAvailable, let zmxDir = zmx.env.zmxDir else { return nil }
        let plan = zmx.wrap(
            sessionName: sessionName,
            plan: StartupScriptInstaller.Plan(executable: shell, args: shellArguments, envOverrides: [:])
        )
        // Agent session markers too: a host started from inside an agent
        // session must not hand them to the user's shells. `ALAS_*` is the
        // host's own configuration (profile, zmx, web dir), not the user's.
        var environment = baseEnvironment.filter {
            !terminalKeys.contains($0.key) && !ACPProcessEnvironment.agentSessionMarkerKeys.contains($0.key)
                && !$0.key.hasPrefix("ALAS_")
        }
        // launchd sets no locale, which leaves the shell in "C" and garbles
        // UTF-8 input and output.
        if ["LANG", "LC_ALL", "LC_CTYPE"].allSatisfy({ environment[$0] == nil }) {
            environment["LANG"] = "en_US.UTF-8"
        }
        environment.merge(environmentOverrides) { _, override in override }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["ZMX_DIR"] = zmxDir.path
        return HostShellLaunch(
            executable: URL(fileURLWithPath: plan.executable),
            arguments: plan.args,
            environment: environment,
            directory: directory
        )
    }

    /// Runs the launcher to completion. Throws `PeerConsoleOpenError.notStarted`
    /// when it can't spawn, exits non-zero, or outlives `timeout`.
    public func run(timeout: TimeInterval = 10) async throws {
        try await BlockingWork.run { [self] in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = directory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            do {
                try process.run()
            } catch {
                throw PeerConsoleOpenError.notStarted
            }
            guard exited.wait(timeout: .now() + timeout) == .success else {
                process.terminate()
                throw PeerConsoleOpenError.notStarted
            }
            guard process.terminationStatus == 0 else { throw PeerConsoleOpenError.notStarted }
        }
    }

    /// The user's login shell: the password database, then `$SHELL`, then zsh.
    public static func loginShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }
        return "/bin/zsh"
    }

    /// `ALAS_ZMX_BINARY` when set, else `zmx/zmx` beside `executable` or
    /// `fallback`, by the rules of ``bundledBinary(_:overrideKey:executable:fallback:environment:fileManager:)``.
    public static func zmxBinary(
        executable: URL?,
        fallback: URL = URL(fileURLWithPath: "/Applications/Alas.app/Contents/Resources/zmx/zmx"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        bundledBinary(["zmx/zmx"], overrideKey: "ALAS_ZMX_BINARY", executable: executable,
                      fallback: fallback, environment: environment, fileManager: fileManager)
    }

    /// The `alas` CLI: `ALAS_CLI_BINARY`, else `alas-cli/alas` (the host zip)
    /// or `alas-cli/<arch>/alas` (the app bundle) beside `executable`, else
    /// `fallback`.
    public static func cliBinary(
        executable: URL?,
        fallback: URL = URL(
            fileURLWithPath: "/Applications/Alas.app/Contents/Resources/alas-cli/\(TerminalCLIInjection.archDirectory)/alas"
        ),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        bundledBinary(["alas-cli/alas", "alas-cli/\(TerminalCLIInjection.archDirectory)/alas"],
                      overrideKey: "ALAS_CLI_BINARY", executable: executable,
                      fallback: fallback, environment: environment, fileManager: fileManager)
    }

    /// `overrideKey` when set, if it is an executable: a set path that isn't
    /// means no binary, with no fallback. Otherwise the first executable among
    /// each of `relativePaths` under the directory above `executable`'s with
    /// links resolved (the layout of `Alas.app/Contents/Resources` and the
    /// cask zip), then `fallback`.
    public static func bundledBinary(
        _ relativePaths: [String],
        overrideKey: String,
        executable: URL?,
        fallback: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        if let override = environment[overrideKey], !override.isEmpty {
            return fileManager.isExecutableFile(atPath: override) ? URL(fileURLWithPath: override) : nil
        }
        let root = executable.map { $0.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent() }
        let beside = root.map { root in relativePaths.map { root.appendingPathComponent($0) } } ?? []
        return (beside + [fallback]).first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
