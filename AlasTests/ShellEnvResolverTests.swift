import Testing
import Foundation
@testable import Alas
@testable import AlasPlatform

struct ShellEnvResolverTests {
    /// A shell at a temporary path running `script`, which sees the
    /// resolver's arguments as "$@".
    private func fakeShell(_ script: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-shell-\(UUID().uuidString)")
        try "#!/bin/sh\n\(script)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// nvm and mise are set up in `.zshrc`, which zsh reads only when
    /// interactive; startup files may print and fail a command on the way.
    @Test func thePathComesFromAnInteractiveLoginShellDespiteNoiseAndFailures() async throws {
        let shell = try fakeShell("""
        case "$1" in -i) ;; *) exit 0 ;; esac
        echo "loading nvm..."
        printf '%s' "___ALAS_PATH___/nvm/bin:/usr/bin___ALAS_END___"
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: shell) }
        #expect(await ShellEnvResolver.discoverShellPath(candidates: [shell.path]) == "/nvm/bin:/usr/bin")
    }

    /// An interactive shell's startup files must not reach the terminal the
    /// caller runs in (`alas-host setup` over SSH): the shell leads a session
    /// of its own, which has no terminal.
    @Test func theShellRunsInASessionOfItsOwn() async throws {
        let shell = try fakeShell("""
        if /usr/bin/python3 -c "import os,sys; sys.exit(0 if os.getsid($$) == $$ else 1)"; then where=/own-session; else where=/callers-session; fi
        printf '%s' "___ALAS_PATH___${where}___ALAS_END___"
        """)
        defer { try? FileManager.default.removeItem(at: shell) }
        #expect(await ShellEnvResolver.discoverShellPath(candidates: [shell.path]) == "/own-session")
    }

    /// Startup files can leave a helper behind that keeps the output open
    /// after the shell exits; the lookup ends at the PATH it printed, and the
    /// helper does not outlive it.
    @Test(.timeLimit(.minutes(1)))
    func aHelperThatKeepsTheOutputOpenDoesNotHoldTheLookupOrOutliveIt() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("helper-\(UUID().uuidString)")
        let shell = try fakeShell("""
        sleep 300 &
        echo $! > '\(pidFile.path)'
        printf '%s' "___ALAS_PATH___/with/helper___ALAS_END___"
        """)
        defer {
            try? FileManager.default.removeItem(at: shell)
            try? FileManager.default.removeItem(at: pidFile)
        }
        #expect(await ShellEnvResolver.discoverShellPath(candidates: [shell.path]) == "/with/helper")
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
        printf '%s' "___ALAS_PATH___/login/bin___ALAS_END___"
        """)
        defer { try? FileManager.default.removeItem(at: shell) }
        #expect(await ShellEnvResolver.discoverShellPath(candidates: [shell.path]) == "/login/bin")
    }
}
