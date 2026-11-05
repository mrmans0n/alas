import Foundation
import Testing
import AlasCore

struct ACPSessionLifecycleTests {
    @Test func v1PromptResponseKeepsServerCancellation() async throws {
        let client = ACPMockClient()
        client.script(method: "session/prompt") { _ in Data(#"{"stopReason":"cancelled"}"#.utf8) }
        let outcome = try await ACPConnection(client: client).prompt(sessionId: "s", blocks: [])
        #expect(outcome.stopReason.rawValue == .string("cancelled"))
        #expect(outcome.stopReason.v1Result == .cancelled)
        let context = ACPDelegatedOutcomeText.Context(childSessionId: "s", agentId: "test", worktreeName: nil)
        #expect(ACPDelegatedOutcomeText.cancelled(context) == "Delegated session s (test) had its turn cancelled.")
    }

    @Test(arguments: ["end_turn", "cancelled", "max_tokens", "max_turn_requests", "refusal", "future", "_custom"])
    func v1StopReasonsStayDistinct(reason: String) throws {
        let result = try JSONDecoder().decode(ACPSessionPromptResult.self,
            from: Data("{\"stopReason\":\"\(reason)\"}".utf8))
        let expected: ACPTurnCompletion.Result = switch reason {
        case "end_turn": .completed
        case "cancelled": .cancelled
        default: .stopped(.init(rawValue: .string(reason)))
        }
        #expect(result.stopReason.v1Result == expected)
    }

    @Test(arguments: ["{}", #"{"stopReason":null}"#, #"{"stopReason":true}"#, #"{"stopReason":{"future":1}}"#])
    func unknownStopOutcomesKeepTheirRawValue(json: String) throws {
        let root = try LSPJSONValue.decode(from: Data(json.utf8))
        guard case .object(let fields) = root else { return }
        let result = try JSONDecoder().decode(ACPSessionPromptResult.self, from: Data(json.utf8))
        #expect(result.stopReason.rawValue == fields["stopReason"])
        #expect(result.stopReason.v1Result == .stopped(.init(rawValue: fields["stopReason"])))
    }

    @Test(arguments: ["{}", #"{"messageId":null}"#, #"{"messageId":true}"#, #"{"messageId":"m","_meta":[]}"#])
    func acceptanceRequiresValidIdentityAndMetadata(json: String) {
        #expect(throws: DecodingError.self) {
            try ACPV2PromptAccepted.decode(from: Data(json.utf8))
        }
    }

    @Test(arguments: [0, 1, 2])
    func acceptanceNeverCompletesForegroundWork(responsePosition: Int) throws {
        var lifecycle = ACPSessionLifecycle(protocolVersion: .v2)
        lifecycle.submit(7)
        let response = try JSONDecoder().decode(ACPV2PromptAccepted.self,
            from: Data(#"{"messageId":"user-7","future":{"keep":true}}"#.utf8))
        if responsePosition > 0 { _ = lifecycle.update(try state("running"), source: .live) }
        if responsePosition > 1 { _ = lifecycle.update(try state("idle", reason: "end_turn"), source: .live) }
        let previousCompletion = lifecycle.lastForegroundCompletion
        #expect(lifecycle.accept(7, response: response) == [.accepted(requestID: 7, messageID: "user-7")])
        #expect(lifecycle.submission(7) == .accepted(messageID: "user-7"))
        #expect(lifecycle.lastForegroundCompletion == previousCompletion)
        #expect(lifecycle.accept(7, response: response).isEmpty)
        guard case .object(let raw) = response.rawValue else { return }
        #expect(raw["future"] == .object(["keep": .bool(true)]))
    }

    @Test(arguments: ["running", "requires_action"])
    func foregroundWorkWithoutASubmissionEndsOnce(initial: String) throws {
        var lifecycle = ACPSessionLifecycle(protocolVersion: .v2)
        #expect(lifecycle.update(try state("idle"), source: .snapshot).count == 1)
        _ = lifecycle.update(try state(initial), source: .live)
        let ended = lifecycle.update(try state("idle", reason: "cancelled"), source: .live)
        #expect(ended == [.foregroundChanged(.idle), .foregroundEnded(.init(generation: 1, result: .cancelled))])
        #expect(lifecycle.update(try state("idle", reason: "end_turn"), source: .live).isEmpty)
        #expect(lifecycle.lastForegroundCompletion?.result == .cancelled)
        _ = lifecycle.update(try state("running"), source: .live)
        _ = lifecycle.update(try state("idle", reason: "end_turn"), source: .live)
        #expect(lifecycle.lastForegroundCompletion == .init(generation: 2, result: .completed))
    }

    @Test func snapshotsAndSetupResponsesCannotInventCompletion() throws {
        var lifecycle = ACPSessionLifecycle(protocolVersion: .v2)
        _ = lifecycle.update(try state("running"), source: .live)
        #expect(lifecycle.update(try state("idle"), source: .setupDefault).isEmpty)
        #expect(lifecycle.foreground == .running)
        #expect(lifecycle.update(try state("idle", reason: "end_turn"), source: .snapshot) == [.foregroundChanged(.idle)])
        #expect(lifecycle.lastForegroundCompletion == nil)
        _ = lifecycle.update(try state("requires_action"), source: .snapshot)
        _ = lifecycle.update(try state("running"), source: .live)
        _ = lifecycle.update(try state("idle"), source: .live)
        #expect(lifecycle.lastForegroundCompletion?.result == .stopped(.init()))
    }

    @Test func unknownStateAndFailurePayloadStayExplicit() throws {
        var lifecycle = ACPSessionLifecycle(protocolVersion: .v2)
        _ = lifecycle.update(try state("running"), source: .live)
        _ = lifecycle.update(try state("_future"), source: .live)
        #expect(lifecycle.foreground == .unrecognized("_future"))
        #expect(lifecycle.lastForegroundCompletion == nil)
        let update = try JSONDecoder().decode(ACPV2StateUpdate.self, from: Data(#"{"sessionUpdate":"state_update","state":"idle","stopReason":"error","error":{"code":-32000,"message":"Sign in","data":{"future":true}},"future":1}"#.utf8))
        _ = lifecycle.update(update, source: .live)
        #expect(lifecycle.lastForegroundCompletion?.result == .failed("Sign in"))
        #expect(update.error?.code == -32000)
        guard case .object(let raw) = update.rawValue else { return }
        #expect(raw["future"] == .number("1"))
    }

    @Test(arguments: [false, true])
    func lostObservationDoesNotRejectOrReplayAnInsertedMessage(accepted: Bool) throws {
        var lifecycle = ACPSessionLifecycle(protocolVersion: .v2)
        lifecycle.submit(1)
        if accepted {
            _ = lifecycle.accept(1, response: try JSONDecoder().decode(ACPV2PromptAccepted.self,
                from: Data(#"{"messageId":"m1"}"#.utf8)))
        }
        lifecycle.requestCancellation(1)
        #expect(lifecycle.lastForegroundCompletion == nil)
        _ = lifecycle.loseObservation()
        #expect(lifecycle.submission(1) == (accepted ? .accepted(messageID: "m1") : .uncertain))
        #expect(lifecycle.foreground == .unknown)
        #expect(lifecycle.lastForegroundCompletion == nil)
    }

    @Test func rejectionDoesNotEndExistingForegroundWork() throws {
        var lifecycle = ACPSessionLifecycle(protocolVersion: .v2)
        _ = lifecycle.update(try state("running"), source: .live)
        lifecycle.submit(1)
        #expect(lifecycle.reject(1) == [.rejected(requestID: 1)])
        #expect(lifecycle.submission(1) == .rejected)
        #expect(lifecycle.foreground == .running)
        #expect(lifecycle.lastForegroundCompletion == nil)
    }

    @Test func v1CancellationAndLateResponseHaveOneTerminalOutcome() {
        var lifecycle = ACPSessionLifecycle(protocolVersion: .v1)
        lifecycle.submit(1)
        lifecycle.requestCancellation(1)
        #expect(lifecycle.finishV1(1, result: .completed) == .cancelled)
        #expect(lifecycle.finishV1(1, result: .completed) == nil)
        lifecycle.submit(2)
        lifecycle.forget(2)
        #expect(lifecycle.finishV1(2, result: .completed) == nil)
    }

    @Test(arguments: [
        ("max_tokens" as String?, "max_tokens", RunScheduleOutcome.agentFailed("Maximum token limit reached")),
        ("max_turn_requests", "max_turn_requests", .agentFailed("Maximum model-request limit reached")),
        ("refusal", "refusal", .agentFailed("Agent declined to continue")),
        ("_future", "unknown", .unknown),
        (nil, "unknown", .unknown),
    ])
    func stoppedOutcomesReachCompletionConsumers(reason: String?, usage: String, schedule: RunScheduleOutcome) {
        let result = ACPTurnCompletion.Result.stopped(.init(rawValue: reason.map(LSPJSONValue.string)))
        let completion = ACPTurnCompletion(
            sessionId: "s", startedAt: 1, result: result, delegatedSource: nil, lastAgentText: nil)
        let input = UsageTurnInput(completion: completion, agent: "test", model: nil,
            cumulativeCost: nil, project: nil, worktree: nil, endedAt: 2)
        #expect(input.result == usage)
        #expect(RunScheduleOutcome(result) == schedule)
        #expect(ACPSessionOrchestrationPolicy.outcomeDisposition(
            result: result, lastParentReportAt: 2, turnStartedAt: 1) == .wake)
    }

    @Test func lifecycleWireInputsKeepOpaqueNumbersAndFailureMessages() throws {
        let acceptedInput = Data(#"{"messageId":"m","_meta":{"n":1e999},"big":123456789012345678901234567890}"#.utf8)
        let accepted = try ACPV2PromptAccepted.decode(from: acceptedInput)
        #expect(accepted.rawValue == (try LSPJSONValue.decode(from: acceptedInput)))
        #expect(try LSPJSONValue.decode(from: accepted.encodedData()) == accepted.rawValue)
        let stateInput = Data(#"{"sessionUpdate":"state_update","state":"idle","stopReason":"error","error":{"code":-32000,"message":"Sign in","data":{"n":1e999}},"_meta":{"big":123456789012345678901234567890}}"#.utf8)
        let update = try ACPV2StateUpdate.decode(from: stateInput)
        #expect(update.rawValue == (try LSPJSONValue.decode(from: stateInput)))
        #expect(update.failure?.code == -32000)
        #expect(update.failure?.data == .object(["n": .number("1e999")]))
        #expect(update.result == .failed("Sign in"))
        #expect(try LSPJSONValue.decode(from: update.encodedData()) == update.rawValue)
        let malformedReason = try ACPV2StateUpdate.decode(from: Data(#"{"sessionUpdate":"state_update","state":"idle","stopReason":{"n":1e999}}"#.utf8))
        #expect(malformedReason.stopReason.rawValue == .object(["n": .number("1e999")]))
        #expect(malformedReason.result == .stopped(malformedReason.stopReason))
    }

    @Test(arguments: [
        #"{"sessionUpdate":"state_update","state":null}"#,
        #"{"sessionUpdate":"other","state":"idle"}"#,
        #"{"sessionUpdate":"state_update","state":"idle","_meta":[]}"#,
    ])
    func malformedLifecycleWireContainersAreRejected(json: String) {
        #expect(throws: DecodingError.self) { try ACPV2StateUpdate.decode(from: Data(json.utf8)) }
    }

    @Test(arguments: [
        ("-2147483648", Int32?.some(Int32.min)), ("2147483647", .some(Int32.max)),
        ("-3.2e4", .some(-32000)), ("-0", .some(0)),
        ("-2147483649", nil), ("2147483648", nil), ("1.5", nil), ("1e999", nil),
        ("1.00000000000000000000000000000001", nil), ("1-2", nil), ("00", nil),
    ])
    func optionalFailureCodesRequireExactInt32Values(token: String, expected: Int32?) throws {
        let raw: LSPJSONValue = .object(["sessionUpdate": .string("state_update"), "state": .string("idle"),
            "stopReason": .string("error"), "error": .object(["code": .number(token), "message": .string("Failure")])])
        let update = try ACPV2StateUpdate(rawValue: raw)
        #expect(update.state == .idle)
        #expect(update.rawValue == raw)
        #expect(update.failure?.code == expected)
        #expect(update.result == .failed(expected == nil ? "Agent foreground work failed." : "Failure"))
    }

    @Test(arguments: ["null", "[]", #"{"code":1}"#, #"{"code":1,"message":7}"#])
    func malformedOptionalFailureDetailsDoNotHideIdleState(error: String) throws {
        let update = try ACPV2StateUpdate.decode(from: Data(#"{"sessionUpdate":"state_update","state":"idle","stopReason":"error","error":\#(error)}"#.utf8))
        #expect(update.state == .idle)
        #expect(update.failure == nil)
        #expect(update.result == .failed("Agent foreground work failed."))
    }

    struct ExpectedFailureFields: Sendable {
        var category = "limit"
        var knownCategory = ACPSessionFailureRecord.Category.limit
        var severity = ACPSessionFailureRecord.Severity.error
        var details: String?
        var reason: String?
        var actions: [String] = []
        var kind: String?
    }

    /// The fields every readable row needs, with `extra` appended.
    private static func failure(_ extra: String = "") -> String {
        #"{"version":1,"id":"t:error","revision":2,"title":"boom"\#(extra)}"#
    }

    @Test(arguments: [
        // Claude, everything present.
        (failure(#","category":"limit","severity":"error","details":"more","reason":"why","actions":["retry","new_session"],"kind":"rate_limited""#),
         ExpectedFailureFields(details: "more", reason: "why", actions: ["retry", "new_session"], kind: "rate_limited")),
        // Codex sends neither details nor reason.
        (failure(#","category":"limit","severity":"warning","actions":[]"#),
         ExpectedFailureFields(severity: .warning)),
        (failure(#","category":"future""#),
         ExpectedFailureFields(category: "future", knownCategory: .unknown)),
        (failure(), ExpectedFailureFields(category: "unknown", knownCategory: .unknown)),
        (failure(#","category":"limit","severity":"fatal""#), ExpectedFailureFields()),
        (failure(#","category":"limit","actions":["retry","future","retry",3]"#),
         ExpectedFailureFields(actions: ["retry", "future", "retry"])),
        (failure(#","category":"limit","actions":"retry""#), ExpectedFailureFields()),
        (failure(#","category":"limit","details":"  ","reason":3,"kind":[]"#), ExpectedFailureFields()),
        // Unreadable: a required field is wrong, or the value is no record at all.
        (#"{"version":2,"id":"t:error","revision":1,"title":"boom"}"#, nil),
        (#"{"id":"t:error","revision":1,"title":"boom"}"#, nil),
        (#"{"version":1,"revision":1,"title":"boom"}"#, nil),
        (#"{"version":1,"id":"","revision":1,"title":"boom"}"#, nil),
        (#"{"version":1,"id":"t:error","revision":0,"title":"boom"}"#, nil),
        (#"{"version":1,"id":"t:error","revision":1.5,"title":"boom"}"#, nil),
        (#"{"version":1,"id":"t:error","revision":1,"title":"  "}"#, nil),
        (#""boom""#, nil),
    ] as [(String, ExpectedFailureFields?)])
    func sessionFailureRecordDecoding(json: String, expected: ExpectedFailureFields?) throws {
        let signal = try failureSignal(meta: #"{"sessionFailure":\#(json)}"#)
        guard let expected else {
            #expect(signal == .unreadable)
            return
        }
        guard case .record(let record) = signal else {
            Issue.record("expected a record, got \(signal)")
            return
        }
        #expect(record.version == 1)
        #expect(record.id == "t:error")
        #expect(record.revision == 2)
        #expect(record.title == "boom")
        #expect(record.category == expected.category)
        #expect(record.knownCategory == expected.knownCategory)
        #expect(record.severity == expected.severity)
        #expect(record.details == expected.details)
        #expect(record.reason == expected.reason)
        #expect(record.actions == expected.actions)
        #expect(record.kind == expected.kind)
        // Rows persist through the same Codable pair, raw values included.
        #expect(try JSONDecoder().decode(ACPSessionFailureRecord.self, from: JSONEncoder().encode(record)) == record)
    }

    @Test(arguments: [
        "{}",
        #"{"sessionFailure":null}"#,
        // The AIR location of the same record is never read.
        #"{"jetbrains":{"air":{"version":1,"sessionFailure":\#(failure())}}}"#,
    ])
    func sessionFailureSignalIsAbsentWithoutItsKey(meta: String) throws {
        #expect(try failureSignal(meta: meta) == .absent)
    }

    private static let errorFailure = failure(#","severity":"error""#)
    private static let warningFailure = failure(#","severity":"warning""#)
    private static let quotaError = failure(#","severity":"error","kind":"quota_exhausted""#)
    private static let quotaWarning = failure(#","severity":"warning","kind":"quota_exhausted""#)

    @Test(arguments: [
        ("end_turn", nil, .completed),
        ("end_turn", warningFailure, .completed),
        ("end_turn", errorFailure, .failed("boom")),
        ("end_turn", quotaError, .limited),
        ("end_turn", quotaWarning, .completed),
        ("end_turn", #""boom""#, .failed(ACPSessionFailureSignal.unreadableMessage)),
        ("cancelled", errorFailure, .cancelled),
        ("cancelled", #""boom""#, .cancelled),
        ("max_tokens", errorFailure, .stopped(.init(rawValue: .string("max_tokens")))),
        (nil, errorFailure, .stopped(.init())),
    ] as [(String?, String?, ACPTurnCompletion.Result)])
    func terminalResolution(stopReason: String?, failure: String?, expected: ACPTurnCompletion.Result) throws {
        let signal = try failureSignal(meta: failure.map { #"{"sessionFailure":\#($0)}"# } ?? "{}")
        let stop = ACPStopReason(rawValue: stopReason.map(LSPJSONValue.string))
        #expect(stop.v1Result(failure: signal) == expected)
    }

    private func failureSignal(meta: String) throws -> ACPSessionFailureSignal {
        try ACPSessionFailureSignal.from(metadata: JSONDecoder().decode(AnyCodable.self, from: Data(meta.utf8)))
    }

    private func state(_ value: String, reason: String? = nil) throws -> ACPV2StateUpdate {
        var fields: [String: String] = ["sessionUpdate": "state_update", "state": value]
        fields["stopReason"] = reason
        return try JSONDecoder().decode(ACPV2StateUpdate.self, from: JSONEncoder().encode(fields))
    }
}
