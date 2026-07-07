import Foundation
import Observation

/// Command shape for a self-update operation. Wrapping the Homebrew command
/// makes `SelfUpdater` testable and avoids scattering it across views.
struct SelfUpdateCommand: Equatable, Sendable {
    static let alasHomebrewCask = "mrmans0n/tap/alas"

    let executable: String
    let arguments: [String]
    /// Overrides `displayCommandLine` for commands whose real invocation
    /// (e.g. a `sh -c` wrapper chaining multiple steps) isn't what a user
    /// should copy-paste into their own shell.
    let displayOverride: String?

    init(executable: String, arguments: [String], displayOverride: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.displayOverride = displayOverride
    }

    /// Detects the `brew` executable on the host's PATH so the upgrade
    /// works on both Apple Silicon (`/opt/homebrew/bin/brew`) and Intel
    /// (`/usr/local/bin/brew`) Macs. Falls back to the Apple Silicon default
    /// if brew cannot be found.
    ///
    /// Runs `brew update` first: Homebrew doesn't always refresh its local
    /// tap metadata before `upgrade`, so without this a stale local index
    /// can make `brew upgrade --cask` report nothing to do even though the
    /// app's own GitHub-based check just found a newer release.
    static var homebrew: SelfUpdateCommand {
        let host = InstallerHost.detect()
        let brew = host.detected[.brew]?.executable ?? "/opt/homebrew/bin/brew"
        let updateCommand = "\(brew) update"
        let upgradeCommand = "\(brew) upgrade --cask \(alasHomebrewCask)"
        return SelfUpdateCommand(
            executable: "/bin/sh",
            arguments: ["-c", "\(updateCommand) && \(upgradeCommand)"],
            displayOverride: "brew update && brew upgrade --cask \(alasHomebrewCask)"
        )
    }

    var displayCommandLine: String {
        displayOverride ?? ((executable as NSString).lastPathComponent as String) + " " + arguments.joined(separator: " ")
    }
}

@Observable
@MainActor
final class SelfUpdater {
    enum State: Equatable, Sendable {
        case idle
        case running(commandLine: String)
        case finished(exitCode: Int32)
        case cancelled
        case failed(message: String)
    }

    private(set) var state: State = .idle
    private(set) var logLines: [String] = []

    private var currentProcess: Process?
    private var watchdog: Task<Void, Never>?
    private var cancelRequested = false
    /// Identity token for the currently-tracked update. Incremented on every
    /// spawn and on every `reset()`. The readability/termination handlers only
    /// mutate state/logs if this still matches the spawn-time value —
    /// otherwise a stale handler from a killed process could corrupt a new run.
    private var generation: Int = 0

    /// Start the update. Requires `.idle`; otherwise throws.
    func start(command: SelfUpdateCommand) async throws {
        guard state == .idle else {
            throw SelfUpdaterBusy()
        }
        await _spawn(
            executable: command.executable,
            arguments: command.arguments,
            commandLineForDisplay: command.displayCommandLine
        )
    }

    func cancel() {
        guard case .running = state, let process = currentProcess else { return }
        cancelRequested = true
        kill(process.processIdentifier, SIGINT)
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            await MainActor.run {
                if case .running = self.state, let proc = self.currentProcess, proc.isRunning {
                    proc.terminate()
                }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                if case .running = self.state, let proc = self.currentProcess, proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
        }
    }

    func reset() {
        if case .running = state, let proc = currentProcess, proc.isRunning {
            cancelRequested = true
            kill(proc.processIdentifier, SIGKILL)
        }
        state = .idle
        logLines = []
        currentProcess = nil
        watchdog?.cancel()
        watchdog = nil
        cancelRequested = false
        generation &+= 1
    }

    /// Test seam: spawn a command directly without going through `start`.
    func runForTesting(executable: String, arguments: [String]) async {
        precondition(state == .idle, "runForTesting requires idle state")
        await _spawn(
            executable: executable,
            arguments: arguments,
            commandLineForDisplay: ([executable] + arguments).joined(separator: " ")
        )
    }

    // MARK: - Private spawn

    private func _spawn(
        executable: String,
        arguments: [String],
        commandLineForDisplay: String
    ) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = augmentedPATH(base: env["PATH"])
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        generation &+= 1
        let myGeneration = generation

        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            let lines = buffer.feed(chunk)
            if lines.isEmpty { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == myGeneration else { return }
                self.logLines.append(contentsOf: lines)
            }
        }

        process.terminationHandler = { [weak self, buffer, pipe] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let finalData = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            let finalLines: [String]
            if let chunk = String(data: finalData, encoding: .utf8), !chunk.isEmpty {
                finalLines = buffer.feed(chunk)
            } else {
                finalLines = []
            }
            let finalTrailing = buffer.flush()
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.generation == myGeneration else { return }
                if !finalLines.isEmpty {
                    self.logLines.append(contentsOf: finalLines)
                }
                if let trailing = finalTrailing, !trailing.isEmpty {
                    self.logLines.append(trailing)
                }
                self.currentProcess = nil
                self.watchdog?.cancel()
                self.watchdog = nil
                defer { self.cancelRequested = false }
                if case .running = self.state {
                    if proc.terminationStatus == 0 {
                        self.state = .finished(exitCode: 0)
                    } else if self.cancelRequested || proc.terminationReason == .uncaughtSignal {
                        self.state = .cancelled
                    } else {
                        self.state = .finished(exitCode: proc.terminationStatus)
                    }
                }
            }
        }

        state = .running(commandLine: commandLineForDisplay)
        logLines = []
        currentProcess = process

        do {
            try process.run()
        } catch {
            state = .failed(message: String(describing: error))
            currentProcess = nil
            return
        }

        try? stdinPipe.fileHandleForReading.close()
        try? stdinPipe.fileHandleForWriting.close()
        try? pipe.fileHandleForWriting.close()
    }

    private func augmentedPATH(base: String?) -> String {
        let basePath = base ?? ""
        let additional = InstallerHost.defaultAdditionalPathDirectories()
        var seen = Set<String>()
        var parts: [String] = []
        for dir in basePath.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        where seen.insert(dir).inserted {
            parts.append(dir)
        }
        for dir in additional where !dir.isEmpty && seen.insert(dir).inserted {
            parts.append(dir)
        }
        return parts.joined(separator: ":")
    }
}

struct SelfUpdaterBusy: Error {}
