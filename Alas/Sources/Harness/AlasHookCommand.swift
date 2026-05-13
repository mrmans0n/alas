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
        let bodyExtract = #"body=$(printf '%s' "$payload" | /usr/bin/python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print((d.get("message") or d.get("last_assistant_message") or d.get("assistant_response") or "")[:500])' 2>/dev/null)"#
        let jsonBody = #"$(printf '%s' "$body" | /usr/bin/python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"#
        let envelope =
            #"{"v":1,"event":"\#(event.rawValue)","agent":"\#(agent.rawValue)","session_id":"%s","pid":%s,"body":%s}"#
        let printfCmd = #"printf '\#(envelope)\n' "$ALAS_SESSION_ID" "$PPID" "\#(jsonBody)" | /usr/bin/nc -U -w1 "$ALAS_SOCKET_PATH""#
        return "\(bodyExtract); \(printfCmd)"
    }
}
