import Darwin
import Foundation

/// What a plugin process reports, in order: output as it arrives, then its exit status, last.
enum PluginProcessEvent: Equatable, Sendable {
    case stdout(Data)
    case stderr(Data)
    /// The exit code, or 128 plus the signal number when a signal ended it, as shells report it.
    case exit(Int32)
}

/// A process Alas started for a plugin.
protocol PluginProcessHandle: AnyObject, Sendable {
    var events: AsyncStream<PluginProcessEvent> { get }
    /// Asks the process, and what it started in its process group, to stop.
    func terminate()
    /// Stops them at once.
    func kill()
}

/// Starts plugin processes. Alas resolves the executable and owns the environment; the plugin owns neither.
protocol PluginProcessLauncher: Sendable {
    func launch(_ argv: [String], in directory: URL, stdin: Data?) throws -> any PluginProcessHandle
}

enum PluginProcessError: Error, CustomStringConvertible {
    case notFound(String)

    var description: String {
        switch self {
        case .notFound(let name): "command not found: \(name)"
        }
    }
}

/// Runs processes with Foundation, in Alas's own login environment.
struct PluginFoundationLauncher: PluginProcessLauncher {
    func launch(_ argv: [String], in directory: URL, stdin: Data?) throws -> any PluginProcessHandle {
        let environment = Self.environment()
        guard let name = argv.first,
              let executable = Self.resolve(name, in: directory, path: environment["PATH"] ?? "")
        else { throw PluginProcessError.notFound(argv.first ?? "") }
        return try FoundationPluginProcess(
            executable: executable, arguments: Array(argv.dropFirst()), directory: directory,
            environment: environment, stdin: stdin)
    }

    /// Alas's environment with the login shell's `PATH`, as git and agent processes get it, without Alas's own
    /// variables or the markers of the agent session Alas may have been started from.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("ALAS_") }
        for key in ACPProcessEnvironment.agentSessionMarkerKeys { env[key] = nil }
        env["PATH"] = ShellEnvResolver.shared.resolvedPath ?? ACPProcessEnvironment.augmented()["PATH"]
        return env
    }

    /// An absolute path as it is, a path with a slash relative to the worktree (`./bin/x`), and a bare name looked
    /// up in `path`.
    static func resolve(_ name: String, in directory: URL, path: String) -> URL? {
        let candidates: [URL] = if name.hasPrefix("/") {
            [URL(fileURLWithPath: name)]
        } else if name.contains("/") {
            [directory.appending(path: name)]
        } else {
            path.split(separator: ":").map { URL(fileURLWithPath: String($0)).appending(path: name) }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

/// The stream ends once the process has exited and both pipes have closed, or a second after the exit when
/// something it left behind holds a pipe open.
private final class FoundationPluginProcess: PluginProcessHandle, @unchecked Sendable {
    let events: AsyncStream<PluginProcessEvent>
    private let continuation: AsyncStream<PluginProcessEvent>.Continuation
    private let process = Process()
    private let lock = NSLock()
    private var openPipes = 2
    private var exitStatus: Int32?
    private var finished = false

    init(executable: URL, arguments: [String], directory: URL, environment: [String: String], stdin: Data?) throws {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        let input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        for (pipe, wrap) in [(out, PluginProcessEvent.stdout), (err, PluginProcessEvent.stderr)] {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard let self else { return }
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    self.settle { $0.openPipes -= 1 }
                } else {
                    self.lock.withLock { if !self.finished { self.continuation.yield(wrap(data)) } }
                }
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationReason == .uncaughtSignal
                ? 128 + process.terminationStatus : process.terminationStatus
            self?.settle { $0.exitStatus = status }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.settle { $0.openPipes = 0 }
            }
        }
        try process.run()
        // Its own process group, so stopping it reaches what it started. Foundation cannot spawn into one, so this
        // races the exec, as `JSONRPCStdioTransport` does.
        // ponytail: descendants that leave the group (daemons) are not followed; that transport tracks the tree.
        _ = setpgid(process.processIdentifier, process.processIdentifier)
        if let stdin {
            DispatchQueue.global().async {
                try? input.fileHandleForWriting.write(contentsOf: stdin)
                try? input.fileHandleForWriting.close()
            }
        }
    }

    private func settle(_ change: (FoundationPluginProcess) -> Void) {
        lock.withLock {
            change(self)
            guard !finished, let exitStatus, openPipes <= 0 else { return }
            finished = true
            continuation.yield(.exit(exitStatus))
            continuation.finish()
        }
    }

    func terminate() { signal(SIGTERM) }
    func kill() { signal(SIGKILL) }

    private func signal(_ signal: Int32) {
        // Only while it runs: after the exit its pid, and so the group, may belong to something else.
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        _ = Darwin.kill(-pid, signal)
        _ = Darwin.kill(pid, signal)
    }
}

// MARK: - Messages

struct PluginProcessRunParams: Decodable, Sendable {
    let id: String
    let worktree: String
    let args: [String]?
    let stdin: String?
}

struct PluginProcessRunResult: Encodable, Equatable {
    let exit: Int32
    let stdout: String
    let stderr: String
    /// Output past the cap was dropped.
    let truncated: Bool
    /// Alas stopped it at the time limit.
    let timedOut: Bool
}

struct PluginProcessStopParams: Decodable, Sendable {
    let run: String
}

struct PluginProcessStartResult: Encodable, Equatable {
    let run: String
}

struct PluginProcessExitedParams: Codable, Equatable {
    let run: String
    let exit: Int32
}

/// A long-running process, shown in the Run tab of its worktree.
struct PluginProcessRun: Identifiable, Equatable, Sendable {
    let id: String
    let process: String
    let worktree: String
    let command: [String]
    /// The latest output, stdout and stderr interleaved as they arrived.
    var output = ""
    var exit: Int32?
}

/// A long-running plugin process as the Run tab lists it.
struct PluginProcessItem: Identifiable, Equatable {
    let pluginID: String
    let projectID: String
    let pluginName: String
    let run: PluginProcessRun
    var id: String { "\(pluginID)/\(run.id)" }
}
