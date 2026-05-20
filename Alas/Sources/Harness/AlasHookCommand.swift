import Foundation

enum AlasHookCommand {
    static let ownershipSentinel = "# alas-managed-hook"

    private static let envCheck =
        #"[ -n "${ALAS_SOCKET_PATH:-}" ] && [ -n "${ALAS_SESSION_ID:-}" ]"#

    static func isManagedCommand(_ command: String) -> Bool {
        command.hasSuffix(ownershipSentinel)
    }

    static func compositeCommand(
        events: [ActivityEvent],
        agent: AgentKind,
        forwardStdinAsBody: Bool
    ) -> String {
        precondition(!events.isEmpty, "compositeCommand needs at least one event")

        if events.count == 1, !forwardStdinAsBody {
            return managed(envelopePipeline(event: events[0], agent: agent))
        }

        // When forwardStdinAsBody is true, the LAST event carries the body and
        // we MUST NOT also send a body-less envelope for it: HarnessService
        // only notifies on the first transition into awaiting_input, so the
        // earlier body-less event would consume that transition and drop the
        // agent's message from the notification. For idle, the same race can
        // enqueue a generic "finished" notification ahead of the body-bearing
        // one. Preceding events (if any) still emit body-less.
        var steps: [String] = []
        if forwardStdinAsBody {
            steps.append("payload=$(cat 2>/dev/null || true)")
        }
        let bodyless = forwardStdinAsBody ? events.dropLast() : ArraySlice(events)
        for event in bodyless {
            steps.append(envelopePipeline(event: event, agent: agent))
        }
        if forwardStdinAsBody {
            steps.append(bodyEnvelopePipeline(event: events.last!, agent: agent))
        }
        return managed("{ \(steps.joined(separator: "; ")); }")
    }

    private static func managed(_ pipeline: String) -> String {
        "\(envCheck) && \(pipeline) >/dev/null 2>&1 || true \(ownershipSentinel)"
    }

    private static func envelopePipeline(event: ActivityEvent, agent: AgentKind) -> String {
        let envelope =
            #"{"v":1,"event":"\#(event.rawValue)","agent":"\#(agent.rawValue)","session_id":"%s","pid":%s}"#
        return #"printf '\#(envelope)\n' "$ALAS_SESSION_ID" "$PPID" | /usr/bin/nc -U -w1 "$ALAS_SOCKET_PATH""#
    }

    private static func bodyEnvelopePipeline(event: ActivityEvent, agent: AgentKind) -> String {
        // One python3 invocation: parse stdin JSON, extract a message body,
        // and emit the full envelope. The previous implementation used TWO
        // python3 invocations per event (one to extract the body, one to
        // JSON-encode it), which doubled interpreter startup cost. cursor-agent
        // flaps these hooks fast enough that the duplicate cost contributed
        // to runaway system load. $PPID is passed as argv because python's
        // os.getppid() returns the surrounding shell, not the harness.
        let script = """
            import json,os,sys
            try: d=json.loads(sys.stdin.read() or "{}")
            except Exception: d={}
            b=(d.get("message") or d.get("last_assistant_message") or d.get("assistant_response") or "")[:500] if isinstance(d, dict) else ""
            print(json.dumps({"v":1,"event":"\(event.rawValue)","agent":"\(agent.rawValue)","session_id":os.environ.get("ALAS_SESSION_ID",""),"pid":int(sys.argv[1] or "0"),"body":b}))
            """
        return #"printf '%s' "$payload" | /usr/bin/python3 -c '\#(script)' "$PPID" 2>/dev/null | /usr/bin/nc -U -w1 "$ALAS_SOCKET_PATH""#
    }
}
