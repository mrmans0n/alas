import Testing
@testable import Alas

struct AlasHookCommandTests {
    static let sentinel = "# alas-managed-hook"

    @Test func busyWithoutBody_producesSimpleCommand() {
        let cmd = AlasHookCommand.compositeCommand(
            events: [.busy], agent: .codex, forwardStdinAsBody: false
        )
        #expect(cmd.contains(#""event":"busy""#))
        #expect(cmd.contains(#""agent":"codex""#))
        #expect(cmd.contains("$ALAS_SESSION_ID"))
        #expect(cmd.contains("$ALAS_SOCKET_PATH"))
        #expect(cmd.hasSuffix(Self.sentinel))
        #expect(!cmd.contains("payload=$(cat"))
    }

    @Test func idleWithBody_includesPayloadExtraction() {
        let cmd = AlasHookCommand.compositeCommand(
            events: [.idle], agent: .claude, forwardStdinAsBody: true
        )
        #expect(cmd.contains(#""event":"idle""#))
        #expect(cmd.contains(#""agent":"claude""#))
        #expect(cmd.contains("payload=$(cat"))
        #expect(cmd.contains("python3"))
        #expect(cmd.hasSuffix(Self.sentinel))
    }

    @Test func multipleEvents_producesCompositeCommand() {
        let cmd = AlasHookCommand.compositeCommand(
            events: [.idle], agent: .claude, forwardStdinAsBody: true
        )
        #expect(cmd.contains("nc -U -w1"))
        #expect(cmd.hasSuffix(Self.sentinel))
    }

    @Test func envCheckGuardsPrefixesCommand() {
        let cmd = AlasHookCommand.compositeCommand(
            events: [.busy], agent: .cursor, forwardStdinAsBody: false
        )
        #expect(cmd.hasPrefix(#"[ -n "${ALAS_SOCKET_PATH:-}" ]"#))
    }

    @Test func sentinel_isOwnershipMarker() {
        #expect(AlasHookCommand.ownershipSentinel == "# alas-managed-hook")
    }

    @Test func isManaged_matchesSentinel() {
        let cmd = AlasHookCommand.compositeCommand(
            events: [.busy], agent: .codex, forwardStdinAsBody: false
        )
        #expect(AlasHookCommand.isManagedCommand(cmd))
        #expect(!AlasHookCommand.isManagedCommand("echo hello"))
    }

    /// Each cursor hook event fires this command, so the subprocess cost
    /// matters: a body-bearing event with two python3 invocations doubles
    /// interpreter startup per event and contributes to the runaway load
    /// we saw with cursor-agent. Keep the body path to a single python3.
    @Test func bodyEnvelopePipeline_usesSinglePython3Invocation() {
        let cmd = AlasHookCommand.compositeCommand(
            events: [.idle], agent: .cursor, forwardStdinAsBody: true
        )
        let count = cmd.components(separatedBy: "/usr/bin/python3").count - 1
        #expect(count == 1)
    }
}
