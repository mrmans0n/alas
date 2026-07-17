import Testing
@testable import Alas

@Suite("AlasCLIEnvInjection")
struct AlasCLIEnvInjectionTests {
    @Test("builds the full env with PATH prepend")
    func buildsEnv() throws {
        let env = try #require(AlasCLIEnvInjection.environment(
            enabled: true, binDirPath: "/managed/bin", socketPath: "/tmp/a.sock",
            worktreePath: "/repos/p/wt", sessionId: "s1",
            parentSessionId: nil, basePATH: "/usr/bin"))
        #expect(env["ALAS_SOCKET_PATH"] == "/tmp/a.sock")
        #expect(env["ALAS_WORKTREE_DIR"] == "/repos/p/wt")
        #expect(env["ALAS_SESSION_ID"] == "s1")
        #expect(env["ALAS_PARENT_SESSION_ID"] == nil)
        #expect(env["PATH"] == "/managed/bin:/usr/bin")
    }

    @Test("delegated sessions carry the parent id")
    func delegated() throws {
        let env = try #require(AlasCLIEnvInjection.environment(
            enabled: true, binDirPath: "/b", socketPath: "/s",
            worktreePath: "/w", sessionId: "child",
            parentSessionId: "parent", basePATH: nil))
        #expect(env["ALAS_PARENT_SESSION_ID"] == "parent")
        // basePATH: nil falls back to TerminalCLIInjection's system PATH
        // (see TerminalCLIInjectionTests.pathValueUsesSystemFallbackWhenCurrentPathIsEmpty),
        // not an empty base — the prepended dir is still first.
        #expect(env["PATH"]?.hasPrefix("/b:") == true)
        #expect(env["PATH"]?.contains("/usr/bin") == true)
    }

    @Test("unavailable inputs produce nil")
    func unavailable() {
        #expect(AlasCLIEnvInjection.environment(
            enabled: false, binDirPath: "/b", socketPath: "/s",
            worktreePath: "/w", sessionId: "s", parentSessionId: nil, basePATH: nil) == nil)
        #expect(AlasCLIEnvInjection.environment(
            enabled: true, binDirPath: nil, socketPath: "/s",
            worktreePath: "/w", sessionId: "s", parentSessionId: nil, basePATH: nil) == nil)
        #expect(AlasCLIEnvInjection.environment(
            enabled: true, binDirPath: "/b", socketPath: nil,
            worktreePath: "/w", sessionId: "s", parentSessionId: nil, basePATH: nil) == nil)
    }
}
