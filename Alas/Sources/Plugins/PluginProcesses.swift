import Darwin
import Foundation

/// What a plugin process reports, in order: output as it arrives, then its exit status, last.
enum PluginProcessEvent: Equatable, Sendable {
    case stdout(Data)
    case stderr(Data)
    /// Output past the retained amount was dropped; reported once, before the exit.
    case truncated
    /// The exit code, or 128 plus the signal number when a signal ended it, as shells report it.
    case exit(Int32)
}

/// A process Alas started for a plugin.
protocol PluginProcessHandle: AnyObject, Sendable {
    var events: AsyncStream<PluginProcessEvent> { get }
    /// Asks the process, and every process it started, to stop.
    func terminate()
    /// Stops them at once.
    func kill()
}

/// Starts plugin processes. Alas resolves the executable and owns the environment; the plugin owns neither.
protocol PluginProcessLauncher: Sendable {
    /// Keeps at most `limit` bytes of each of stdout and stderr: the first ones, or the latest with `keep: .tail`.
    func launch(
        _ argv: [String], in directory: URL, stdin: Data?, keep: PluginProcessOutput.Keep, limit: Int
    ) throws -> any PluginProcessHandle
}

enum PluginProcessError: Error, CustomStringConvertible {
    case notFound(String)

    var description: String {
        switch self {
        case .notFound(let name): "command not found: \(name)"
        }
    }
}

/// Output waiting for its reader, bounded per stream where it is produced, so a noisy command neither grows
/// Alas's memory nor floods the main actor: the reader takes everything pending as one batch, at most once per
/// `interval`. The exit always comes through, after the output.
final class PluginProcessOutput: @unchecked Sendable {
    enum Keep: Sendable { case head, tail }

    private(set) var events: AsyncStream<PluginProcessEvent>!
    private let limit: Int
    private let keep: Keep
    private let interval: Duration
    private let lock = NSLock()
    private var pending = [Data(), Data()]
    private var accepted = [0, 0]
    private var truncated = false
    private var reportedTruncation = false
    private var exit: Int32?
    private var done = false
    private let wake: AsyncStream<Void>.Continuation
    private var emitted = false
    /// Only the reader touches it.
    private var waiter: AsyncStream<Void>.Iterator

    init(keep: Keep, limit: Int, interval: Duration = .milliseconds(50)) {
        self.keep = keep
        self.limit = limit
        self.interval = interval
        let (wakes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.wake = wake
        waiter = wakes.makeAsyncIterator()
        events = AsyncStream(unfolding: { [self] in await next() })
    }

    /// `stream` 0 is stdout, 1 is stderr.
    func append(_ data: Data, stream: Int) {
        lock.withLock {
            switch keep {
            case .head:
                let room = max(0, limit - accepted[stream])
                if data.count > room { truncated = true }
                pending[stream].append(data.prefix(room))
                accepted[stream] += min(room, data.count)
            case .tail:
                pending[stream].append(data)
                if pending[stream].count > limit {
                    pending[stream] = Data(pending[stream].suffix(limit))
                    truncated = true
                }
            }
        }
        wake.yield()
    }

    func finish(exit: Int32) {
        lock.withLock { self.exit = exit }
        wake.yield()
    }

    /// Waits `interval` after each batch, however much is pending, so output that arrives meanwhile joins the next.
    private func next() async -> PluginProcessEvent? {
        if emitted, interval > .zero { try? await Task.sleep(for: interval) }
        while true {
            if let event = take() {
                emitted = true
                return event
            }
            guard await waiter.next() != nil else { return nil }
        }
    }

    private func take() -> PluginProcessEvent? {
        lock.withLock {
            for (stream, wrap) in [(0, PluginProcessEvent.stdout), (1, PluginProcessEvent.stderr)] where !pending[stream].isEmpty {
                defer { pending[stream] = Data() }
                return wrap(pending[stream])
            }
            if truncated, !reportedTruncation {
                reportedTruncation = true
                return .truncated
            }
            if let exit, !done {
                done = true
                return .exit(exit)
            }
            if done { wake.finish() }
            return nil
        }
    }
}

/// Runs processes with Foundation, in Alas's own login environment.
struct PluginFoundationLauncher: PluginProcessLauncher {
    func launch(
        _ argv: [String], in directory: URL, stdin: Data?, keep: PluginProcessOutput.Keep, limit: Int
    ) throws -> any PluginProcessHandle {
        let environment = Self.environment()
        guard let name = argv.first,
              let executable = Self.resolve(name, in: directory, path: environment["PATH"] ?? "")
        else { throw PluginProcessError.notFound(argv.first ?? "") }
        return try FoundationPluginProcess(
            executable: executable, arguments: Array(argv.dropFirst()), directory: directory,
            environment: environment, stdin: stdin, output: PluginProcessOutput(keep: keep, limit: limit))
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
    var events: AsyncStream<PluginProcessEvent> { output.events }
    private let output: PluginProcessOutput
    private let process = Process()
    private let lock = NSLock()
    private var openPipes = 2
    private var exitStatus: Int32?
    private var finished = false
    /// Every descendant seen while the root ran, as `ACPTerminal` tracks them: the parent-side `setpgid` can lose
    /// the race with `exec`, and once the root exits its children are reparented and no longer found from it.
    private var descendants: Set<ACPTerminal.DescendantKey> = []
    private var tracker: Task<Void, Never>?

    init(
        executable: URL, arguments: [String], directory: URL, environment: [String: String], stdin: Data?,
        output: PluginProcessOutput
    ) throws {
        self.output = output
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
        for (stream, pipe) in [out, err].enumerated() {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard let self else { return }
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    self.settle { $0.openPipes -= 1 }
                } else {
                    self.lock.withLock { if !self.finished { self.output.append(data, stream: stream) } }
                }
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationReason == .uncaughtSignal
                ? 128 + process.terminationStatus : process.terminationStatus
            self?.settle { $0.exitStatus = status }
            // What it leaves running goes with it, killed if it outlasts the grace.
            self?.signalLeftovers(SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.signalLeftovers(SIGKILL)
                self?.settle { $0.openPipes = 0 }
            }
        }
        try process.run()
        // Its own process group, so one signal reaches what it started. Foundation cannot spawn into one, so this
        // races the exec; the tracked descendants cover a lost race and children that leave the group.
        let pid = process.processIdentifier
        _ = setpgid(pid, pid)
        tracker = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled, let self, self.lock.withLock({ self.exitStatus == nil }) {
                self.track(ACPTerminal.collectChildDescendants(of: pid))
                try? await Task.sleep(for: .seconds(1))
            }
        }
        if let stdin {
            DispatchQueue.global().async {
                try? input.fileHandleForWriting.write(contentsOf: stdin)
                try? input.fileHandleForWriting.close()
            }
        }
    }

    deinit { tracker?.cancel() }

    private func track(_ found: [ACPTerminal.DescendantKey]) {
        lock.withLock {
            descendants = ACPTerminal.currentlyMatching(descendants).union(found)
        }
    }

    private func settle(_ change: (FoundationPluginProcess) -> Void) {
        lock.withLock {
            change(self)
            guard !finished, let exitStatus, openPipes <= 0 else { return }
            finished = true
            output.finish(exit: exitStatus)
        }
    }

    func terminate() { signal(SIGTERM) }
    func kill() { signal(SIGKILL) }

    /// The root and its group only while it runs, since afterwards its pid may belong to something else; every
    /// tracked descendant that is still the same process, whether or not the root has exited.
    private func signal(_ signal: Int32) {
        let pid = process.processIdentifier
        let rootRunning = lock.withLock { exitStatus == nil } && process.isRunning
        if rootRunning {
            track(ACPTerminal.collectChildDescendants(of: pid))
            _ = Darwin.kill(-pid, signal)
            _ = Darwin.kill(pid, signal)
        }
        for descendant in ACPTerminal.currentlyMatching(lock.withLock { descendants }) {
            _ = Darwin.kill(descendant.pid, signal)
        }
    }

    /// After the root exits: its group, whose id cannot be reused while any member is left, and every tracked
    /// descendant that is still the same process.
    private func signalLeftovers(_ signal: Int32) {
        _ = Darwin.kill(-process.processIdentifier, signal)
        for descendant in ACPTerminal.currentlyMatching(lock.withLock { descendants }) {
            _ = Darwin.kill(descendant.pid, signal)
        }
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
