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
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in cont.resume() }
                if !process.isRunning { cont.resume() }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        watchdog.cancel()

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
