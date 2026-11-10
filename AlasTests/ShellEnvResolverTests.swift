import Testing
import Foundation
@testable import Alas
@testable import AlasPlatform

struct ShellEnvResolverTests {
    /// A shell at a temporary path running `script`, which sees the
    /// resolver's arguments as "$@". `runCommand` runs the resolver's
    /// command with whatever environment the script set up.
    private func fakeShell(_ script: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-shell-\(UUID().uuidString)")
        try "#!/bin/sh\n\(script)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private let runCommand = #"while [ "$1" != "-c" ]; do shift; done; /bin/sh "$@""#

    /// nvm and mise are set up in `.zshrc`, which zsh reads only when
    /// interactive; startup files may print and fail a command on the way.
    @Test func thePathComesFromAnInteractiveLoginShellDespiteNoiseAndFailures() async throws {
        let shell = try fakeShell("""
        case "$1" in -i) ;; *) exit 0 ;; esac
        echo "loading nvm..."
        export PATH=/nvm/bin:/usr/bin
        \(runCommand)
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: shell) }
        #expect(await ShellEnvResolver.discoverShellEnvironment(candidates: [shell.path])?["PATH"] == "/nvm/bin:/usr/bin")
    }

    /// An interactive shell's startup files must not reach the terminal the
    /// caller runs in (`alas-host setup` over SSH): the shell leads a session
    /// of its own, which has no terminal.
    @Test func theShellRunsInASessionOfItsOwn() async throws {
        let shell = try fakeShell("""
        # A session leader leads its process group too. Not python3: it is an Xcode
        # shim that can outlast the resolver's timeouts on a loaded machine.
        if [ "$(/bin/ps -o pgid= -p $$ | tr -d ' ')" = "$$" ]; then where=/own-session; else where=/callers-session; fi
        export PATH=$where
        \(runCommand)
        """)
        defer { try? FileManager.default.removeItem(at: shell) }
        #expect(await ShellEnvResolver.discoverShellEnvironment(candidates: [shell.path])?["PATH"] == "/own-session")
    }

    /// Startup files can leave a helper behind that keeps the output open
    /// after the shell exits; the lookup ends at the environment it printed,
    /// and the helper does not outlive it.
    @Test(.timeLimit(.minutes(1)))
    func aHelperThatKeepsTheOutputOpenDoesNotHoldTheLookupOrOutliveIt() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("helper-\(UUID().uuidString)")
        let shell = try fakeShell("""
        sleep 300 &
        echo $! > '\(pidFile.path)'
        export PATH=/with/helper
        \(runCommand)
        """)
        defer {
            try? FileManager.default.removeItem(at: shell)
            try? FileManager.default.removeItem(at: pidFile)
        }
        #expect(await ShellEnvResolver.discoverShellEnvironment(candidates: [shell.path])?["PATH"] == "/with/helper")
        let helper = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let deadline = ContinuousClock.now + .seconds(5)
        while kill(helper, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(helper, 0) != 0, "the helper outlived the lookup")
    }

    @Test func aLoginShellAnswersWhenTheInteractiveOneGivesNothing() async throws {
        let shell = try fakeShell("""
        case "$1" in -i) exit 1 ;; esac
        export PATH=/login/bin
        \(runCommand)
        """)
        defer { try? FileManager.default.removeItem(at: shell) }
        #expect(await ShellEnvResolver.discoverShellEnvironment(candidates: [shell.path])?["PATH"] == "/login/bin")
    }

    /// gg's lint hooks need what startup files set up beyond PATH, such as
    /// ANDROID_HOME for `./gradlew`. The shell's own PWD is not passed on,
    /// nor its editor, which can't run without a terminal.
    @Test func gitProcessesGetTheLoginShellsEnvironment() async throws {
        let shell = try fakeShell("""
        export ANDROID_HOME=/sdk GIT_EDITOR=nvim PATH="/rbenv/shims:$PATH"
        \(runCommand)
        """)
        defer { try? FileManager.default.removeItem(at: shell) }
        let shellEnvironment = await ShellEnvResolver.discoverShellEnvironment(candidates: [shell.path])

        let env = Process.gitEnv(base: ["PATH": "/usr/bin:/bin"], shellEnvironment: shellEnvironment)
        #expect(env["ANDROID_HOME"] == "/sdk")
        #expect(env["PATH"]?.hasPrefix("/rbenv/shims:") == true)
        #expect(env["PWD"] == nil)
        #expect(env["GIT_EDITOR"] == "true")
    }
}
