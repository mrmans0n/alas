import Foundation

struct GeneratedMessage: Equatable {
    let subject: String
    let body: String
}

/// First paragraph = subject (first line only); the rest = body.
/// Tolerates missing blank lines, trailing whitespace, empty input.
enum AgentMessageParser {
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

/// Spawns the agent's resolved binary with its non-interactive prompt shape,
/// pipes any stdin payload, and parses stdout. 120s timeout. Cancellation is
/// delivered by Task cancellation, which `Process.run` propagates as SIGTERM.
///
/// Pipe-management and process-lifecycle logic mirrors `Process.run` in
/// `Process+Git.swift`; the commentary there explains why each fd is closed
/// when it is.
enum AgentRunner {
    /// Convenience wrapper for callers that want the parsed
    /// `subject`/`body` shape (commit-message generator, etc.). The
    /// bulk merge-conflict resolve uses `runPromptRaw` instead because
    /// `AgentMessageParser` drops every line after the first in the
    /// initial paragraph, which collapses "one line per file"
    /// summaries to a single line.
    static func runPrompt(
        agent: AgentDefinition,
        input: String,
        prompt: String,
        workingDirectory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 120,
        bypassPermissions: Bool = false
    ) async throws -> GeneratedMessage {
        let stdout = try await runPromptRaw(
            agent: agent,
            input: input,
            prompt: prompt,
            workingDirectory: workingDirectory,
            environment: environment,
            timeout: timeout,
            bypassPermissions: bypassPermissions
        )
        return AgentMessageParser.parse(stdout)
    }

    /// Returns the agent's raw stdout, lossless. Use this when the
    /// caller wants the full output structure (e.g. a multi-line
    /// per-file summary) instead of the heuristic
    /// subject/body split.
    static func runPromptRaw(
        agent: AgentDefinition,
        input: String,
        prompt: String,
        workingDirectory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 120,
        bypassPermissions: Bool = false
    ) async throws -> String {
        let binary = agent.resolvedBinary
        let invocation = AgentPromptInvocation.make(
            agent: agent,
            input: input,
            prompt: prompt,
            bypassPermissions: bypassPermissions
        )
        let pipe = Pipe()
        // We can't use Process.run directly because it doesn't accept
        // stdin. Inline a minimal variant that does, reusing gitEnv()
        // semantics (parent env + GIT_OPTIONAL_LOCKS=0 doesn't matter
        // for these CLIs, but the parent-env passthrough does).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [binary] + invocation.arguments
        // Without an explicit cwd, the child inherits the app bundle's
        // launch directory (typically `/`), which breaks CLIs whose first
        // act is to inspect the surrounding git repo — codex refuses with
        // "Not inside a trusted directory" before reading stdin.
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        var env = environment
        env["PATH"] = AgentPath.augmented(base: env["PATH"])
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Latch termination via a gate so an immediate exit between
        // `process.run()` and the `await` cannot drop the resume. Set the
        // handler BEFORE `run()` for the same reason — see ExitGate in
        // Process+Git.swift.
        let exit = AgentRunnerExitGate()
        process.terminationHandler = { _ in exit.didExit() }

        do {
            try process.run()
        } catch {
            throw AgentRunError.binaryNotFound(agentId: agent.id, displayName: agent.displayName)
        }

        // Close the parent's copies of the stdin read end and the
        // stdout/stderr write ends now that the child has dup'd them.
        // Three reasons, one symmetric rule (close anything you don't
        // own once the fork has happened):
        //
        //  - outPipe / errPipe writing end: without this, `readToEnd()`
        //    below never sees EOF (kernel keeps the read end open as long
        //    as ANY writer — including this parent's stray FD — remains)
        //    and the function hangs indefinitely after the child exits.
        //
        //  - stdin reading end: without this, terminating the child does
        //    NOT deliver EPIPE to the parent's blocked stdin write,
        //    because the kernel still sees a live reader (us). A
        //    misbehaving CLI that stops reading stdin would then keep the
        //    parent's write blocked even after our watchdog/cancel
        //    SIGTERMs the child.
        //
        // Mirrors the same cleanup in Process.run.
        try? pipe.fileHandleForReading.close()
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()

        // Drain stdout and stderr concurrently with the child, NOT after
        // exit. If a CLI writes more than the pipe buffer (~64KB on macOS)
        // before exiting — verbose warnings, a model that ignores the
        // prompt and emits a long explanation, etc. — the child blocks on
        // its own write and we'd deadlock waiting for an exit that can't
        // happen. Detached read Tasks let the kernel drain the pipes in
        // parallel; they finish when the child exits and the pipes EOF.
        let outRead = Task.detached {
            (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        }
        let errRead = Task.detached {
            (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        }

        // Watchdog. Armed BEFORE the stdin write so a CLI that stalls
        // before draining stdin (e.g. waiting on auth) and a staged diff
        // larger than the pipe buffer can't block this function past
        // `timeout`: when the watchdog fires, `process.terminate()` closes
        // the child's read end, the kernel delivers EPIPE to our blocked
        // write, and `write(contentsOf:)` returns (via `try?`).
        let timeoutState = AgentRunnerTimeoutState()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled && process.isRunning {
                timeoutState.markTimedOut()
                ACPProcessKiller.terminateThenKillIfNeeded(process)
            }
        }

        // Cancellation scope spans the stdin write too, for the same
        // reason: if the awaiting Task is cancelled while we're blocked
        // writing, `onCancel` terminates the child and the write unblocks.
        await withTaskCancellationHandler {
            if let data = invocation.stdin.data(using: .utf8) {
                try? pipe.fileHandleForWriting.write(contentsOf: data)
            }
            try? pipe.fileHandleForWriting.close()
            await exit.wait()
        } onCancel: {
            if process.isRunning {
                ACPProcessKiller.terminateThenKillIfNeeded(process)
            }
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

        // Distinguish a watchdog kill from a genuine CLI failure: if the
        // watchdog fired, surface `.timedOut` so the inline error reads
        // "Timed out after 120s" instead of a generic non-zero exit
        // message, which would mislead users about what actually happened.
        if timeoutState.didTimeOut {
            throw AgentRunError.timedOut(seconds: timeout)
        }

        // Bound the post-exit drain: if a selected CLI spawned a helper
        // process that inherited the stdout/stderr FDs, the parent's read
        // end will not see EOF until that descendant closes its copy. To
        // keep the composer from hanging on those zombies, close our read
        // ends after a 2s grace period — `readToEnd()` then returns
        // whatever was accumulated up to that point. Mirrors the
        // `waitForClose(timeoutNanoseconds: 2_000_000_000)` cap in
        // Process.run.
        let drainCap = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
        }
        let outData = await outRead.value
        let errData = await errRead.value
        drainCap.cancel()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            // exit 127 is the POSIX convention for "command not found" — env
            // uses it when the named binary doesn't exist on PATH.  Surface
            // that as .binaryNotFound so callers can show a targeted "install
            // the CLI" message rather than a generic non-zero-exit one.
            if process.terminationStatus == 127 {
                throw AgentRunError.binaryNotFound(agentId: agent.id, displayName: agent.displayName)
            }
            throw AgentRunError.nonZeroExit(stderr: stderr, exitCode: process.terminationStatus)
        }
        return stdout
    }
}

private struct AgentPromptInvocation {
    let arguments: [String]
    let stdin: String

    static func make(
        agent: AgentDefinition,
        input: String,
        prompt: String,
        bypassPermissions: Bool = false
    ) -> AgentPromptInvocation {
        // Insert the agent-specific bypass-permissions flag (e.g.
        // `--dangerously-skip-permissions`, `--yolo`,
        // `--dangerously-bypass-approvals-and-sandbox`) between the
        // prompt-mode args and the prompt itself when the caller opted
        // in. Callers that don't need file-write capability (e.g.
        // read-only summary calls) leave this off.
        let bypass: [String] = {
            guard bypassPermissions, let flag = agent.bypassPermissionsFlag else {
                return []
            }
            return [flag]
        }()
        if isCodexExec(agent) {
            // `--skip-git-repo-check` is required because codex refuses to
            // start in a directory it hasn't been told to trust (and there
            // is no interactive prompt to satisfy in non-interactive exec).
            // The trailing `-` makes codex read the prompt from stdin.
            return AgentPromptInvocation(
                arguments: agent.promptModeArgs + bypass + ["--skip-git-repo-check", "-"],
                stdin: combinedPrompt(prompt: prompt, input: input)
            )
        }

        // Put bypass BEFORE `promptModeArgs` (not between args + prompt)
        // so a custom agent whose `promptModeArgs` ends with an
        // option-taking-value (e.g. `["chat", "--prompt"]`) keeps
        // that option adjacent to its value. Inserting bypass in the
        // middle would make the option swallow the bypass flag as its
        // value and misparse the prompt.
        return AgentPromptInvocation(
            arguments: bypass + agent.promptModeArgs + [prompt],
            stdin: input
        )
    }

    private static func combinedPrompt(prompt: String, input: String) -> String {
        if input.isEmpty { return prompt }
        if prompt.isEmpty { return input }
        return "\(prompt)\n\n\(input)"
    }

    private static func isCodexExec(_ agent: AgentDefinition) -> Bool {
        let binaryName = (agent.resolvedBinary as NSString).lastPathComponent
        let subcommand = agent.promptModeArgs.first
        return binaryName == "codex" && (subcommand == "exec" || subcommand == "e")
    }
}

/// Thread-safe latch for "did the watchdog terminate this child?" Set
/// by the watchdog Task, read by the runner after `exit.wait()` so we
/// can distinguish a watchdog SIGTERM from a normal non-zero exit.
private final class AgentRunnerTimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }
}

/// Latches process termination so `wait()` resumes exactly once, even if
/// the child exits before (or concurrently with) `wait()` being awaited.
/// Mirrors `ExitGate` in Process+Git.swift.
private final class AgentRunnerExitGate: @unchecked Sendable {
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
