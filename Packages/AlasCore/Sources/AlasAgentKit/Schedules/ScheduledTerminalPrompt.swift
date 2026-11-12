import Foundation
import AlasFoundation
import AlasModel

/// Types a schedule's prompt into its agent's terminal, in the app and on a
/// headless host alike.
///
/// Nothing is typed into a terminal whose agent has not been seen: the shell
/// would receive the text instead, and with auto-send would run it.
@MainActor
public enum ScheduledTerminalPrompt {
    /// How long to wait for the agent to appear in its terminal. Generous
    /// because the session-open script runs first.
    public static let readinessTimeout: TimeInterval = 120
    /// Pause between the agent appearing and the first keystroke, so a TUI
    /// has drawn its input box before text arrives in it.
    public static let settleDelay: Duration = .milliseconds(1_500)
    /// Pause between the prompt and the Enter that submits it, so an input
    /// that debounces paste-like bursts sees them as two events.
    public static let submitDelay: Duration = .milliseconds(200)

    public enum Outcome: Equatable, Sendable {
        /// Typed, and submitted when the schedule asks for that.
        case sent
        /// Nothing to type, or the schedule was removed meanwhile.
        case nothing
        /// The agent was never confirmed in its terminal.
        case notReady
        /// The terminal was gone when the prompt was typed.
        case closed
        /// The agent stopped between the prompt and its Enter.
        case agentStopped
    }

    /// Delivers `prompt`. `waitUntilReady` answers whether the agent came up;
    /// `ownsTerminal` whether it is, at this instant, the terminal's
    /// foreground process; `type` writes text and reports whether it could.
    public static func deliver(
        _ prompt: String,
        sendsAutomatically: Bool,
        waitUntilReady: () async -> Bool,
        ownsTerminal: () async -> Bool,
        type: (String) async -> Bool
    ) async -> Outcome {
        let text = RunScheduleComposition.terminalText(for: prompt)
        guard !text.isEmpty else { return .nothing }
        guard await waitUntilReady() else {
            // A cancelled delivery is not a failed one: the schedule was
            // removed, and reporting its agent never got ready would be noise.
            return Task.isCancelled ? .nothing : .notReady
        }
        // The wait can report ready and the schedule be removed before this
        // resumes, in which case nothing threw.
        guard !Task.isCancelled else { return .nothing }
        guard await type(text) else { return .closed }
        guard sendsAutomatically else { return .sent }
        // Cancelled between the prompt and its Enter: submitting would start
        // the work just called off, so the text is left in the input.
        do {
            try await Task.sleep(for: submitDelay)
        } catch {
            return .nothing
        }
        // The agent can die inside that pause, leaving the shell to reclaim
        // the terminal, where Enter would run the prompt as a command.
        guard await ownsTerminal() else { return .agentStopped }
        // Last, so nothing suspends between these answers and the write.
        guard !Task.isCancelled else { return .nothing }
        _ = await type("\r")
        return .sent
    }

    /// Polls until the agent owns its terminal, then lets its TUI settle and
    /// asks once more: the agent can exit while drawing, and the terminal
    /// outlives it. False once `isOpen` turns false, at the deadline, or on
    /// cancellation, which ends the wait instead of spinning on a sleep that
    /// returns at once.
    public static func waitUntilOwned(
        ownsTerminal: () async -> Bool,
        isOpen: () -> Bool,
        timeout: TimeInterval = readinessTimeout,
        pollInterval: Duration = .milliseconds(500),
        settleDelay: Duration = settleDelay
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await ownsTerminal()) {
            guard Date() < deadline, isOpen() else { return false }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return false
            }
        }
        do {
            try await Task.sleep(for: settleDelay)
        } catch {
            return false
        }
        return await ownsTerminal()
    }

    /// What to tell the user about an undelivered prompt; nil when nothing
    /// went wrong.
    public static func failureMessage(_ outcome: Outcome, scheduleName: String, worktreeTitle: String) -> String? {
        switch outcome {
        case .sent, .nothing:
            nil
        case .notReady:
            "\(scheduleName): could not confirm the agent was ready in \(worktreeTitle), so the prompt was not sent."
        case .closed:
            "\(scheduleName): the agent's terminal in \(worktreeTitle) closed before the prompt could be sent."
        case .agentStopped:
            "\(scheduleName): the agent stopped before the prompt could be submitted in \(worktreeTitle)."
        }
    }

    /// The command line that starts `agent` in a terminal: on a remote host
    /// its configured binary, with `~/` left for the remote shell.
    public static func agentCommand(for agent: AgentDefinition, remote: Bool, useBypassPermissions: Bool) -> String {
        let binary = remote ? remoteShellBinary(agent.configuredBinary) : ShellQuoting.quote(agent.resolvedBinary)
        var arguments = agent.extraTerminalArgs ?? []
        if useBypassPermissions, let flag = agent.bypassPermissionsFlag {
            arguments.append(flag)
        }
        return ([binary] + arguments.map(ShellQuoting.quote)).joined(separator: " ")
    }

    private static func remoteShellBinary(_ configuredBinary: String) -> String {
        guard configuredBinary.hasPrefix("~/") else { return ShellQuoting.quote(configuredBinary) }
        return "\"$HOME\"/\(ShellQuoting.quote(String(configuredBinary.dropFirst(2))))"
    }

    /// Whether a project's terminal agents start with their bypass flag.
    public static func usesBypassPermissions(project: ProjectConfig, config: AppConfig) -> Bool {
        switch project.startupScripts.worktreeAgentMode {
        case .disabled:
            false
        case .useGlobal:
            config.agents.worktreeAutoLaunch.useBypassPermissions
        case .overrideGlobal, .appendToGlobal:
            project.startupScripts.worktreeAgentUseBypassPermissions
        }
    }
}
