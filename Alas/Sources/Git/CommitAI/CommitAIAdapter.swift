import Foundation

struct GeneratedMessage: Equatable {
    let subject: String
    let body: String
}

enum CommitAIError: LocalizedError {
    case toolNotFound(String)
    case nonZeroExit(stderr: String, exitCode: Int32)
    case timedOut(seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let bin): return "CLI not found on PATH: \(bin)"
        case .nonZeroExit(let stderr, _):
            let first = stderr
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first
                .map(String.init) ?? "CLI exited with an error"
            return first
        case .timedOut(let s): return "Timed out after \(Int(s))s"
        }
    }
}

protocol CommitAIAdapter {
    var tool: CommitAITool { get }
    /// Run the CLI, piping `input` to its stdin. Returns the parsed
    /// (subject, body). Throws `CommitAIError` on failure.
    func generate(input: String, prompt: String) async throws -> GeneratedMessage
}

/// Shared parser. First paragraph = subject (first line only); the rest =
/// body. Tolerates missing blank lines, trailing whitespace, empty input.
enum CommitAIAdapterParser {
    static func parse(_ stdout: String) -> GeneratedMessage {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return GeneratedMessage(subject: "", body: "")
        }
        let parts = trimmed.components(separatedBy: "\n\n")
        let subject = (parts.first ?? "")
            .split(separator: "\n").first.map(String.init) ?? ""
        let body = parts.dropFirst().joined(separator: "\n\n")
        return GeneratedMessage(
            subject: subject.trimmingCharacters(in: .whitespaces),
            body: body.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

/// Shared runner: spawns `binary <args...>`, pipes `input` on stdin, parses
/// stdout. 120s timeout (longer than the default git 30s — generation can
/// be slow). Cancellation is delivered by Task cancellation, which
/// `Process.run` propagates as SIGTERM.
enum CommitAIRunner {
    static func run(
        binary: String,
        args: [String],
        input: String,
        timeout: TimeInterval = 120
    ) async throws -> GeneratedMessage {
        let pipe = Pipe()
        // We can't use Process.run directly because it doesn't accept
        // stdin. Inline a minimal variant that does, reusing gitEnv()
        // semantics (parent env + GIT_OPTIONAL_LOCKS=0 doesn't matter
        // for these CLIs, but the parent-env passthrough does).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [binary] + args
        process.environment = ProcessInfo.processInfo.environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Latch termination via a gate so an immediate exit between
        // `process.run()` and the `await` cannot drop the resume. Set the
        // handler BEFORE `run()` for the same reason — see ExitGate in
        // Process+Git.swift.
        let exit = RunnerExitGate()
        process.terminationHandler = { _ in exit.didExit() }

        do {
            try process.run()
        } catch {
            throw CommitAIError.toolNotFound(binary)
        }

        // Write stdin and close.
        if let data = input.data(using: .utf8) {
            try? pipe.fileHandleForWriting.write(contentsOf: data)
        }
        try? pipe.fileHandleForWriting.close()

        // Watchdog.
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled && process.isRunning { process.terminate() }
        }

        await withTaskCancellationHandler {
            await exit.wait()
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        watchdog.cancel()

        // If the awaiting Task was cancelled, the SIGTERM above produced a
        // non-zero exit status. Treat that as cancellation instead of a CLI
        // error so callers' `catch is CancellationError` paths fire and the
        // UI doesn't surface a misleading error message for an intentional
        // cancel.
        if Task.isCancelled {
            throw CancellationError()
        }

        let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            throw CommitAIError.nonZeroExit(stderr: stderr, exitCode: process.terminationStatus)
        }
        return CommitAIAdapterParser.parse(stdout)
    }
}

/// Latches process termination so `wait()` resumes exactly once, even if
/// the child exits before (or concurrently with) `wait()` being awaited.
/// Mirrors `ExitGate` in Process+Git.swift.
private final class RunnerExitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    private var continuation: CheckedContinuation<Void, Never>?

    func didExit() {
        lock.lock()
        if let c = continuation {
            continuation = nil
            lock.unlock()
            c.resume()
            return
        }
        exited = true
        lock.unlock()
    }

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if exited {
                lock.unlock()
                cont.resume()
                return
            }
            continuation = cont
            lock.unlock()
        }
    }
}

extension CommitAITool {
    func makeAdapter() -> CommitAIAdapter? {
        switch self {
        case .none:        return nil
        case .claude:      return ClaudeAdapter()
        case .codex:       return CodexAdapter()
        case .cursorAgent: return CursorAgentAdapter()
        case .pi:          return PiAdapter()
        }
    }
}
