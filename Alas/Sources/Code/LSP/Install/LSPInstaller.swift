import Foundation
import Observation

/// Orchestrates installation of one language server at a time. UI observes
/// `state` and `logLines` for live updates; consumers call `install(...)`
/// to start, `cancel()` to abort.
///
/// Runs on the main actor — this matches the rest of AppState. The actual
/// `Process` spawn is delegated to a detached `Task` so the main actor isn't
/// blocked on I/O; the spawn task feeds back into the installer via
/// `@MainActor` hops.
@Observable
@MainActor
final class LSPInstaller {
    enum State: Equatable, Sendable {
        case idle
        case running(language: String, commandLine: String)
        case finished(language: String, exitCode: Int32)
        case cancelled(language: String)
        case failed(language: String, message: String)
    }

    private(set) var state: State = .idle
    private(set) var logLines: [String] = []

    /// Pure: builds the argv for spawning. Extracted so tests can verify
    /// command shape without spawning a real process.
    nonisolated static func argv(
        for recipe: InstallRecipe,
        using installer: DetectedInstaller
    ) -> (executable: String, arguments: [String]) {
        let exec = installer.executable
        switch installer.kind {
        case .brew:
            return (exec, ["install", recipe.package])
        case .npm:
            return (exec, ["install", "-g", recipe.package])
        case .pnpm:
            return (exec, ["add", "-g", recipe.package])
        case .bun:
            return (exec, ["add", "-g", recipe.package])
        case .cargo:
            return (exec, ["install", recipe.package])
        case .rustup:
            assert(!recipe.extraArgs.isEmpty, "rustup recipe must supply extraArgs")
            return (exec, recipe.extraArgs)
        case .go:
            return (exec, ["install", "\(recipe.package)@latest"])
        case .pipx:
            return (exec, ["install", recipe.package])
        }
    }

    /// Human-readable command line shown above the log in the progress sheet.
    /// Uses the installer's basename, not the full path, to keep it readable.
    nonisolated static func displayCommandLine(
        for recipe: InstallRecipe,
        using installer: DetectedInstaller
    ) -> String {
        let argv = argv(for: recipe, using: installer)
        let basename = (argv.executable as NSString).lastPathComponent
        return ([basename] + argv.arguments).joined(separator: " ")
    }

    // MARK: - Execution

    private var currentProcess: Process?
    private var watchdog: Task<Void, Never>?
    /// Set in `cancel()` so the terminationHandler can recognize a clean
    /// non-zero exit (e.g. `brew` trapping SIGINT and exiting 130) as a
    /// user-initiated cancel rather than an install failure.
    private var cancelRequested = false
    /// Identity token for the currently-tracked install. Incremented on
    /// every spawn and on every `reset()`. The terminationHandler captures
    /// its spawn-time value and only mutates installer state if it still
    /// matches — otherwise the handler is firing for a process whose
    /// install has already been reset/superseded, and any log lines or
    /// state transitions it would produce belong to a stale lifecycle.
    private var generation: Int = 0

    func install(
        recipe: InstallRecipe,
        using installer: DetectedInstaller,
        language: String
    ) async throws {
        guard state == .idle else {
            throw InstallerBusy()
        }
        let argv = Self.argv(for: recipe, using: installer)
        await _spawn(
            executable: argv.executable,
            arguments: argv.arguments,
            language: language,
            commandLineForDisplay: Self.displayCommandLine(for: recipe, using: installer)
        )
    }

    func cancel() {
        guard case .running = state else { return }
        guard let process = currentProcess else { return }
        cancelRequested = true
        // SIGINT first
        kill(process.processIdentifier, SIGINT)
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            await MainActor.run {
                if case .running = self.state, let proc = self.currentProcess, proc.isRunning {
                    proc.terminate() // SIGTERM
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
        // If a sheet host disappears mid-install (window closed, tab destroyed),
        // SwiftUI fires the sheet's onDismiss → reset(). Tear down the live
        // process synchronously — there's no UI left to watch the SIGINT→TERM
        // escalation, so just SIGKILL and move on. The terminationHandler
        // will still fire from a background queue, but bumping `generation`
        // here makes it a no-op for state/log mutation — preventing it from
        // appending stale logs or marking a freshly-started next install
        // as cancelled.
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

    /// Test seam: spawn without going through recipe argv. Production code calls
    /// `install(...)`; tests call this directly with /bin/echo or /bin/sleep so
    /// they don't depend on brew/npm being on PATH.
    func _spawnForTesting(
        executable: String,
        arguments: [String],
        language: String
    ) async {
        precondition(state == .idle, "_spawnForTesting requires idle state")
        await _spawn(
            executable: executable,
            arguments: arguments,
            language: language,
            commandLineForDisplay: ([executable] + arguments).joined(separator: " ")
        )
    }

    // MARK: - Private spawn

    private func _spawn(
        executable: String,
        arguments: [String],
        language: String,
        commandLineForDisplay: String
    ) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        // Re-augment PATH so children (like brew shelling out to curl) see
        // the same well-known directories the installer found.
        env["PATH"] = augmentedPATH(base: env["PATH"])
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // No interactive stdin — close after launch so any prompting installer
        // fails fast instead of hanging.
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        // Capture our identity-at-spawn-time. The readability/termination
        // handlers will only mutate installer state if this still matches
        // `self.generation` on the main actor — otherwise reset() has
        // bumped generation and a fresh install may be in flight; touching
        // logLines/state from this stale lifecycle would corrupt it.
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

        // For fast-exiting processes (e.g. `brew install` printing "Already
        // up to date." and quitting) the readabilityHandler may never fire,
        // or fire after termination. We can't rely on streaming alone to
        // capture all output. The terminationHandler nils the streaming
        // handler and performs one final synchronous drain of any remaining
        // bytes on the pipe before transitioning state, so observers seeing
        // `.finished` are guaranteed to see all output that was written.
        process.terminationHandler = { [weak self, buffer, pipe] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let finalData = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            let finalLines: [String]
            let finalTrailing: String?
            if let chunk = String(data: finalData, encoding: .utf8), !chunk.isEmpty {
                finalLines = buffer.feed(chunk)
            } else {
                finalLines = []
            }
            finalTrailing = buffer.flush()
            Task { @MainActor [weak self] in
                guard let self else { return }
                // If a reset (or another spawn) has happened since we
                // launched, this handler is a ghost from a stale lifecycle.
                // Drop on the floor.
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
                // Distinguish cancel from organic non-zero exit. Some
                // installers (notably `brew`) trap SIGINT and exit cleanly
                // with a non-zero status (commonly 130), so `.uncaughtSignal`
                // alone misses user-initiated cancels — consult the flag
                // set by cancel() too.
                let cancelled = self.cancelRequested
                if case .running(let lang, _) = self.state {
                    if proc.terminationStatus == 0 {
                        self.state = .finished(language: lang, exitCode: 0)
                    } else if cancelled || proc.terminationReason == .uncaughtSignal {
                        self.state = .cancelled(language: lang)
                    } else {
                        self.state = .finished(language: lang, exitCode: proc.terminationStatus)
                    }
                }
            }
        }

        state = .running(language: language, commandLine: commandLineForDisplay)
        logLines = []
        currentProcess = process

        do {
            try process.run()
        } catch {
            state = .failed(language: language, message: String(describing: error))
            currentProcess = nil
            return
        }

        // Close our copies of the stdin read end and stdout/stderr write end
        // immediately, same rationale as CommitAIAdapter.swift:90-115.
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

struct InstallerBusy: Error {}

