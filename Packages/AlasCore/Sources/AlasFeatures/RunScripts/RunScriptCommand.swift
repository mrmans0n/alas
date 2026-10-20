import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

public enum ACPAuthTerminalLaunchError: LocalizedError, Equatable, Sendable {
    case invalidEnvKey(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEnvKey(let key):
            return "Invalid auth environment variable name: \(key)"
        }
    }
}

/// Identity of the run record that owns a script invocation, available before user code runs.
public struct RunScriptExecutionIdentity: Sendable {
    public let runID: String
    public let worktreeID: String
    public let projectID: String

    public init(runID: String, worktreeID: String, projectID: String) {
        self.runID = runID
        self.worktreeID = worktreeID
        self.projectID = projectID
    }
}

/// Builds the shell text a run executes, in a terminal or headless.
public enum RunScriptCommand {
    /// Composes the startup-script suffix for a run: explicit `cd` (the
    /// terminal default cwd can be `lastUsed`), env exports scoped to the
    /// command line, then the invocation. Executables run directly so their
    /// shebang applies; other files run via /bin/sh.
    public static func runScriptStartupScript(
        script: RunScript,
        worktreeRoot: URL,
        branch: String,
        projectName: String,
        repoRoot: String,
        capturePaths: RunScriptCapturePaths? = nil,
        executionIdentity: RunScriptExecutionIdentity? = nil
    ) throws -> String {
        let cwd = script.cwd.map { worktreeRoot.appendingPathComponent($0).path } ?? worktreeRoot.path
        var env = [
            "ALAS_WORKTREE_ROOT": worktreeRoot.path,
            "ALAS_REPO_ROOT": repoRoot,
            "ALAS_BRANCH": branch,
            "ALAS_PROJECT_NAME": projectName,
        ]
        if let executionIdentity {
            env["ALAS_RUN_ID"] = executionIdentity.runID
            env["ALAS_RUN_SCRIPT_KEY"] = script.key
            env["ALAS_WORKTREE_ID"] = executionIdentity.worktreeID
            env["ALAS_PROJECT_ID"] = executionIdentity.projectID
        }
        let command: String
        let args: [String]
        if script.isExecutable {
            command = script.fileURL.path
            args = []
        } else {
            command = "/bin/sh"
            args = [script.fileURL.path]
        }
        let run = try Self.shellCommand(
            command: command,
            args: args,
            env: env,
            exitOnCompletion: script.onExit == .close
        )
        let commandLine = try Self.shellCommand(command: command, args: args, env: env)
        // A missing/misspelled `alas-cwd` must stop the run rather than fall
        // through and execute the script from wherever the shell happened to
        // start — that's silently dangerous for build/cleanup scripts.
        let prefix = "cd \(ShellQuoting.quote(cwd)) || exit 1\n"
        guard let capturePaths else { return prefix + run }
        return capturedRunScript(
            commandLine: commandLine,
            workingDirectory: ShellQuoting.quote(cwd),
            capturePaths: capturePaths,
            exitOnCompletion: script.onExit == .close
        )
    }

    private static func capturedRunScript(
        commandLine: String,
        workingDirectory: String,
        capturePaths: RunScriptCapturePaths,
        exitOnCompletion: Bool
    ) -> String {
        let transcript = capturePathShellLiteral(capturePaths.transcript)
        let completion = capturePathShellLiteral(capturePaths.completion)
        let status = capturePathShellLiteral("\(capturePaths.completion).status")
        let transcriptDir = capturePathShellLiteral((capturePaths.transcript as NSString).deletingLastPathComponent)
        let completionDir = capturePathShellLiteral((capturePaths.completion as NSString).deletingLastPathComponent)
        let quotedCommandLine = ShellQuoting.quote(commandLine)
        let quotedDarwinCommandLine = ShellQuoting.quote("""
        \(commandLine)
        code=$?
        printf '%s\\n' "$code" > \(status)
        exit "$code"
        """)
        let finishLine = exitOnCompletion
            ? "\nexit \"$exit_code\""
            : "\nif [ \"$publish_failed\" = 1 ]; then\n  exit \"$exit_code\"\nfi\nreturn \"$exit_code\""
        return """
        __alas_run_script_errexit_was_set=0
        case $- in
          *e*) __alas_run_script_errexit_was_set=1 ;;
        esac
        if [ "$__alas_run_script_errexit_was_set" = 1 ]; then
          set +e
        fi
        __alas_run_script_capture() {
        local transcript=\(transcript)
        local completion=\(completion)
        local transcript_ready=0
        local completion_ready=0
        local publish_failed=0
        local setup_failed=0
        local alas_errexit_was_set=$__alas_run_script_errexit_was_set
        local private_umask result script_status exit_code tmp completed_at
        if [ "$alas_errexit_was_set" = 1 ]; then
          set +e
        fi
        if ! cd \(workingDirectory); then
          exit_code=1
          setup_failed=1
        fi
        if mkdir -p \(transcriptDir) 2>/dev/null && chmod 700 \(transcriptDir) 2>/dev/null; then
          transcript_ready=1
          find \(transcriptDir) -type f \\( -name '*.log' -o -name '*.done' -o -name '*.tmp' -o -name '*.body' -o -name '*.status' -o -name '*.snapshot' \\) -mtime +7 -exec rm -f {} + 2>/dev/null || true
        fi
        if mkdir -p \(completionDir) 2>/dev/null && chmod 700 \(completionDir) 2>/dev/null; then
          completion_ready=1
          find \(completionDir) -type f \\( -name '*.log' -o -name '*.done' -o -name '*.tmp' -o -name '*.body' -o -name '*.status' -o -name '*.snapshot' \\) -mtime +7 -exec rm -f {} + 2>/dev/null || true
        fi
        __alas_prepare_run_transcript() {
          private_umask=$(umask)
          umask 077
          : > "$transcript" 2>/dev/null && chmod 600 "$transcript" 2>/dev/null
          result=$?
          umask "$private_umask"
          return "$result"
        }
        if [ "$setup_failed" = 0 ] && [ "$transcript_ready" = 1 ] && command -v script >/dev/null 2>&1; then
          if [ "$(uname -s 2>/dev/null)" = Darwin ] && [ -x /usr/bin/script ]; then
            if __alas_prepare_run_transcript; then
              rm -f \(status)
              if /usr/bin/script -q "$transcript" /usr/bin/env -u SCRIPT /bin/sh -c \(quotedDarwinCommandLine); then
                script_status=0
              else
                script_status=$?
              fi
              if [ -f \(status) ]; then
                exit_code=$(cat \(status))
              else
                exit_code=$script_status
              fi
              rm -f \(status)
            else
              if \(commandLine); then
                exit_code=0
              else
                exit_code=$?
              fi
            fi
          elif script --version 2>/dev/null | grep -qi 'util-linux'; then
            if __alas_prepare_run_transcript; then
              if script -qefc \(quotedCommandLine) "$transcript"; then
                exit_code=0
              else
                exit_code=$?
              fi
            else
              if \(commandLine); then
                exit_code=0
              else
                exit_code=$?
              fi
            fi
          else
            if \(commandLine); then
              exit_code=0
            else
              exit_code=$?
            fi
          fi
        elif [ "$setup_failed" = 0 ]; then
          if \(commandLine); then
            exit_code=0
          else
            exit_code=$?
          fi
        fi
        if [ "$completion_ready" = 1 ]; then
          tmp="$completion.tmp"
          private_umask=$(umask)
          umask 077
          completed_at=$(perl -MTime::HiRes=time -e 'printf "%.6f\\n", time' 2>/dev/null || date +%s)
          if ! { printf '%s\\t%s\\n' "$exit_code" "$completed_at" > "$tmp" && mv "$tmp" "$completion"; }; then
            publish_failed=1
            rm -f "$tmp"
          fi
          umask "$private_umask"
        fi\(finishLine)
        }
        if __alas_run_script_capture; then
          __alas_run_script_status=0
        else
          __alas_run_script_status=$?
        fi
        __alas_finish_run_script_capture() {
          local captured_status=$1
          unset __alas_run_script_errexit_was_set __alas_run_script_status
          unset -f __alas_prepare_run_transcript __alas_run_script_capture __alas_finish_run_script_capture
          return "$captured_status"
        }
        if [ "$__alas_run_script_errexit_was_set" = 1 ]; then
          set +e
          if __alas_finish_run_script_capture "$__alas_run_script_status"; then
            __alas_run_script_final_status=0
          else
            __alas_run_script_final_status=$?
          fi
          __alas_run_script_return_status() {
            return "$__alas_run_script_final_status"
          }
          __alas_restore_run_script_errexit() {
            set -e
            if [ -n "${ZSH_VERSION-}" ]; then
              precmd_functions=("${precmd_functions[@]:#__alas_restore_run_script_errexit}")
            elif [ -n "${BASH_VERSION-}" ]; then
              case "$PROMPT_COMMAND" in
                "__alas_restore_run_script_errexit; "*) PROMPT_COMMAND=${PROMPT_COMMAND#__alas_restore_run_script_errexit; } ;;
                "__alas_restore_run_script_errexit") unset PROMPT_COMMAND ;;
              esac
            fi
            unset __alas_run_script_final_status
            unset -f __alas_run_script_return_status
            unset -f __alas_restore_run_script_errexit
          }
          if [ -n "${ZSH_VERSION-}" ]; then
            precmd_functions=(__alas_restore_run_script_errexit "${precmd_functions[@]}")
          elif [ -n "${BASH_VERSION-}" ]; then
            PROMPT_COMMAND="__alas_restore_run_script_errexit${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
          fi
          __alas_run_script_return_status
        else
          __alas_finish_run_script_capture "$__alas_run_script_status"
        fi
        """
    }

    private static func capturePathShellLiteral(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return ShellQuoting.quote(path) }
        return "\"$HOME/\(path.dropFirst(2).doubleQuotedShellEscaped)\""
    }

    /// The tab hosting this script in this worktree, live session or not.
    /// Stopping or restarting has to reach a stale tab too — otherwise a
    /// relaunch would leave the old one stranded beside the new one.

    public static func shellCommand(
        command: String,
        args: [String],
        env: [String: String],
        exitOnCompletion: Bool = false
    ) throws -> String {
        for key in env.keys where !isValidShellAssignmentName(key) {
            throw ACPAuthTerminalLaunchError.invalidEnvKey(key)
        }
        let envPrefix = env
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(ShellQuoting.quote($0.value))" }
        let commandLine = (envPrefix + [ShellQuoting.quote(command)] + args.map(ShellQuoting.quote)).joined(separator: " ")
        guard exitOnCompletion else { return commandLine }
        return "\(commandLine)\nexit_code=$?\nexit \"$exit_code\""
    }

    private static func isValidShellAssignmentName(_ key: String) -> Bool {
        key.range(
            of: #"^[A-Za-z_][A-Za-z0-9_]*$"#,
            options: .regularExpression
        ) != nil
    }
}
