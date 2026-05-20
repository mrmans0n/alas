import Testing
import Foundation
@testable import Alas

struct AlasHookCommandTests {
    static let sentinel = "# alas-managed-hook"

    /// Run `bodyEnvelopePythonScript` end-to-end so we can assert behavior of
    /// the embedded python script (graceful degradation, body extraction)
    /// rather than just its source-string shape.
    private func runBodyEnvelope(
        stdin payload: String,
        event: ActivityEvent = .idle,
        agent: AgentKind = .cursor
    ) throws -> [String: Any] {
        let script = AlasHookCommand.bodyEnvelopePythonScript(event: event, agent: agent)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-c", script, "99"]
        var env = ProcessInfo.processInfo.environment
        env["ALAS_SESSION_ID"] = "test-session"
        proc.environment = env
        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        try proc.run()
        try inPipe.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
        try inPipe.fileHandleForWriting.close()
        proc.waitUntilExit()
        let data = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "AlasHookCommandTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "script produced no JSON: \(String(data: data, encoding: .utf8) ?? "<nil>")"]
            )
        }
        return obj
    }

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

    @Test func stdoutResponse_isAbsentByDefault() {
        let cmd = AlasHookCommand.compositeCommand(
            events: [.busy], agent: .codex, forwardStdinAsBody: false
        )
        #expect(!cmd.contains("printf '%s\\n'"))
    }

    @Test func stdoutResponse_printsBeforeHookDelivery() {
        let cmd = AlasHookCommand.compositeCommand(
            events: [.busy],
            agent: .codex,
            forwardStdinAsBody: false,
            stdoutResponse: #"{"continue":true}"#
        )
        let responseStep = #"printf '%s\n' '{"continue":true}'"#
        let deliveryStep = #"printf '{"v":1,"event":"busy""#

        #expect(cmd.contains("{ \(responseStep);"))
        #expect(cmd.contains(deliveryStep))
        #expect(cmd.range(of: responseStep)!.lowerBound < cmd.range(of: deliveryStep)!.lowerBound)
    }

    @Test func stdoutResponse_escapesSingleQuotes() {
        let cmd = AlasHookCommand.compositeCommand(
            events: [.busy],
            agent: .codex,
            forwardStdinAsBody: false,
            stdoutResponse: "can't"
        )
        #expect(cmd.contains(#"printf '%s\n' 'can'\''t'"#))
    }

    @Test func stdoutResponse_preservesSentinelSuffix() {
        let cmd = AlasHookCommand.compositeCommand(
            events: [.busy],
            agent: .codex,
            forwardStdinAsBody: false,
            stdoutResponse: "{}"
        )
        #expect(cmd.hasSuffix(Self.sentinel))
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

    @Test func bodyEnvelope_extractsStringMessage() throws {
        let env = try runBodyEnvelope(stdin: #"{"message":"hello from cursor"}"#)
        #expect(env["event"] as? String == "idle")
        #expect(env["agent"] as? String == "cursor")
        #expect(env["body"] as? String == "hello from cursor")
    }

    @Test func bodyEnvelope_fallsBackToLastAssistantMessage() throws {
        let env = try runBodyEnvelope(stdin: #"{"last_assistant_message":"fallback"}"#)
        #expect(env["body"] as? String == "fallback")
    }

    @Test func bodyEnvelope_truncatesBodyAt500Chars() throws {
        let long = String(repeating: "x", count: 1000)
        let env = try runBodyEnvelope(stdin: #"{"message":"\#(long)"}"#)
        #expect((env["body"] as? String)?.count == 500)
    }

    /// Codex review on #211: a non-string `message` (e.g. `{"message":123}`)
    /// previously raised `TypeError` and silently dropped the hook event.
    /// The original two-python implementation degraded to an empty body in
    /// that case; preserve that contract here.
    @Test func bodyEnvelope_emitsEmptyBodyForNonStringMessage() throws {
        let env = try runBodyEnvelope(stdin: #"{"message":123}"#)
        #expect(env["event"] as? String == "idle")
        #expect(env["agent"] as? String == "cursor")
        #expect(env["body"] as? String == "")
    }

    @Test func bodyEnvelope_emitsEmptyBodyForObjectMessage() throws {
        let env = try runBodyEnvelope(stdin: #"{"message":{"nested":"obj"}}"#)
        #expect(env["body"] as? String == "")
    }

    @Test func bodyEnvelope_emitsEmptyBodyForMalformedJSON() throws {
        let env = try runBodyEnvelope(stdin: "not json")
        #expect(env["body"] as? String == "")
        #expect(env["event"] as? String == "idle")
    }

    @Test func bodyEnvelope_emitsEmptyBodyForJSONArray() throws {
        let env = try runBodyEnvelope(stdin: "[]")
        #expect(env["body"] as? String == "")
    }
}
