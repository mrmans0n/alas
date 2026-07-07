import Foundation
import Observation

/// Command shape for a self-update operation. Wrapping the Homebrew command
/// makes `SelfUpdater` testable and avoids scattering it across views.
struct SelfUpdateCommand: Equatable, Sendable {
    static let alasHomebrewCask = "mrmans0n/tap/alas"

    /// A single subprocess invocation. Steps run in order; the sequence
    /// stops at the first non-zero exit or cancellation.
    struct Step: Equatable, Sendable {
        let executable: String
        let arguments: [String]

        var displayCommandLine: String {
            ((executable as NSString).lastPathComponent as String) + " " + arguments.joined(separator: " ")
        }
    }

    let steps: [Step]

    /// Detects the `brew` executable on the host's PATH so the upgrade
    /// works on both Apple Silicon (`/opt/homebrew/bin/brew`) and Intel
    /// (`/usr/local/bin/brew`) Macs. Falls back to the Apple Silicon default
    /// if brew cannot be found.
    ///
    /// Runs `brew update` as its own step first: Homebrew doesn't always
    /// refresh its local tap metadata before `upgrade`, so without this a
    /// stale local index can make `brew upgrade --cask` report nothing to
    /// do even though the app's own GitHub-based check just found a newer
    /// release. The two steps run as direct, separately-tracked processes
    /// (not a `sh -c` chain) so `SelfUpdater` always signals the real
    /// `brew` process — a shell wrapper would let a cancelled update leave
    /// `brew` running in the background.
    static var homebrew: SelfUpdateCommand {
        let host = InstallerHost.detect()
        let brew = host.detected[.brew]?.executable ?? "/opt/homebrew/bin/brew"
        return SelfUpdateCommand(steps: [
            Step(executable: brew, arguments: ["update"]),
            Step(executable: brew, arguments: ["upgrade", "--cask", alasHomebrewCask]),
        ])
    }

    var displayCommandLine: String {
        steps.map(\.displayCommandLine).joined(separator: " && ")
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
    /// Identity token for the currently-tracked update run. Incremented on
    /// every `start`/`runForTesting` call and on every `reset()`. Handlers
    /// from a superseded run check this before touching state/logs so a
    /// stale callback from a killed process can't corrupt a new run.
    private var generation: Int = 0

    /// Start the update. Requires `.idle`; otherwise throws.
    func start(command: SelfUpdateCommand) async throws {
        guard state == .idle else {
            throw SelfUpdaterBusy()
        }
        await _runSequence(steps: command.steps, commandLineForDisplay: command.displayCommandLine)
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

    /// Test seam: run one or more steps directly without going through `start`.
    func runForTesting(steps: [SelfUpdateCommand.Step]) async {
        precondition(state == .idle, "runForTesting requires idle state")
        await _runSequence(steps: steps, commandLineForDisplay: steps.map(\.displayCommandLine).joined(separator: " && "))
    }

    func runForTesting(executable: String, arguments: [String]) async {
        await runForTesting(steps: [SelfUpdateCommand.Step(executable: executable, arguments: arguments)])
    }

    // MARK: - Private sequencing

    private enum StepOutcome {
        case launchFailed(Error)
        case exited(status: Int32, reason: Process.TerminationReason)
    }

    private func _runSequence(steps: [SelfUpdateCommand.Step], commandLineForDisplay: String) async {
        generation &+= 1
        let myGeneration = generation
        state = .running(commandLine: commandLineForDisplay)
        logLines = []
        cancelRequested = false

        for step in steps {
            guard generation == myGeneration else { return }
            if cancelRequested {
                state = .cancelled
                watchdog?.cancel()
                watchdog = nil
                cancelRequested = false
                return
            }

            let outcome = await _runStep(step, generation: myGeneration)
            guard generation == myGeneration else { return }
            currentProcess = nil

            switch outcome {
            case .launchFailed(let error):
                state = .failed(message: String(describing: error))
                watchdog?.cancel()
                watchdog = nil
                cancelRequested = false
                return
            case .exited(let status, let reason):
                if cancelRequested || reason == .uncaughtSignal {
                    state = .cancelled
                    watchdog?.cancel()
                    watchdog = nil
                    cancelRequested = false
                    return
                }
                if status != 0 {
                    state = .finished(exitCode: status)
                    watchdog?.cancel()
                    watchdog = nil
                    cancelRequested = false
                    return
                }
                // Step succeeded; continue on to the next one.
            }
        }

        state = .finished(exitCode: 0)
        watchdog?.cancel()
        watchdog = nil
        cancelRequested = false
    }

    private func _runStep(_ step: SelfUpdateCommand.Step, generation myGeneration: Int) async -> StepOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: step.executable)
        process.arguments = step.arguments

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = augmentedPATH(base: env["PATH"])
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

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

        currentProcess = process

        return await withCheckedContinuation { (continuation: CheckedContinuation<StepOutcome, Never>) in
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
                    if let self, self.generation == myGeneration {
                        if !finalLines.isEmpty {
                            self.logLines.append(contentsOf: finalLines)
                        }
                        if let trailing = finalTrailing, !trailing.isEmpty {
                            self.logLines.append(trailing)
                        }
                    }
                    continuation.resume(returning: .exited(
                        status: proc.terminationStatus,
                        reason: proc.terminationReason
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: .launchFailed(error))
                return
            }

            try? stdinPipe.fileHandleForReading.close()
            try? stdinPipe.fileHandleForWriting.close()
            try? pipe.fileHandleForWriting.close()
        }
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
