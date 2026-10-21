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

    @Test func aLoginShellAnswersWhenTheInteractiveOneGivesNothing() async throws {
        let shell = try fakeShell("""
        case "$1" in -i) exit 1 ;; esac
        printf '%s' "___ALAS_PATH___/login/bin___ALAS_END___"
        """)
        defer { try? FileManager.default.removeItem(at: shell) }
        #expect(await ShellEnvResolver.discoverShellPath(candidates: [shell.path]) == "/login/bin")
    }
}
