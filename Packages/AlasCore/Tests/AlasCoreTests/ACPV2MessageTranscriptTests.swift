import Foundation
import Testing
import AlasCore

struct ACPV2MessageTranscriptTests {
    @Test(arguments: ["user_message", "agent_message", "agent_thought",
        "user_message_chunk", "agent_message_chunk", "agent_thought_chunk"])
    func messageEnvelopesKeepRawFields(variant: String) throws {
        let block: LSPJSONValue = .object(["type": .string("_future"), "value": .number("1e999")])
        let chunk = variant.hasSuffix("_chunk")
        let raw: LSPJSONValue = .object([
            "sessionId": .string("s"), "_meta": .object(["event": .null]), "future": .bool(true),
            "update": .object(["sessionUpdate": .string(variant), "messageId": .string("m"),
                "content": chunk ? block : .array([block]), "future": .string("keep"),
                "_meta": .object(["scope": .string("update")])])])
        let event = try ACPV2SessionUpdateEnvelope.decode(from: raw.encodedData())
        let message = try #require(event.message)
        #expect(message.messageID == "m")
        #expect(message.content == (chunk ? .append(block) : .replace([block])))
        #expect(message.metadata == (chunk ? .unchanged : .patch(["scope": .string("update")])))
        #expect(try LSPJSONValue.decode(from: event.encodedData()) == raw)
    }

    @Test(arguments: ["_future", "state_update", "notice"])
    func unhandledUpdatesStayLossless(variant: String) throws {
        let raw: LSPJSONValue = .object(["sessionId": .string("s"),
            "update": .object(["sessionUpdate": .string(variant), "future": .number("1234567890123456789012345678901234567890")])])
        let event = try ACPV2SessionUpdateEnvelope.decode(from: raw.encodedData())
        #expect(event.message == nil)
        #expect(try LSPJSONValue.decode(from: event.encodedData()) == raw)
    }

    @Test(arguments: [
        "null", #"{"sessionId":null,"update":{}}"#,
        #"{"sessionId":"s","update":null}"#,
        #"{"sessionId":"s","update":{"sessionUpdate":false}}"#,
        #"{"sessionId":"s","_meta":[],"update":{"sessionUpdate":"_future"}}"#,
        #"{"sessionId":"s","update":{"sessionUpdate":"agent_message"}}"#,
        #"{"sessionId":"s","update":{"sessionUpdate":"agent_message","messageId":null}}"#,
        #"{"sessionId":"s","update":{"sessionUpdate":"agent_message","messageId":true}}"#,
        #"{"sessionId":"s","update":{"sessionUpdate":"agent_message","messageId":"m","content":{}}}"#,
        #"{"sessionId":"s","update":{"sessionUpdate":"agent_message","messageId":"m","content":[{"type":null}]}}"#,
        #"{"sessionId":"s","update":{"sessionUpdate":"agent_message","messageId":"m","_meta":true}}"#,
        #"{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","messageId":"m"}}"#,
        #"{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","messageId":"m","content":null}}"#,
        #"{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","messageId":"m","content":[]}}"#,
        #"{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","messageId":"m","content":{"type":"text"},"_meta":[]}}"#,
    ])
    func malformedKnownShapesAreRejected(json: String) {
        #expect(throws: DecodingError.self) {
            try ACPV2SessionUpdateEnvelope.decode(from: Data(json.utf8))
        }
    }

    @Test(arguments: [("", false), (#", "content":null"#, true), (#", "content":[]"#, true)])
    func omittedAndClearedContentStayDistinct(field: String, clears: Bool) throws {
        let event = try decode(#"{"sessionUpdate":"user_message","messageId":"m"\#(field)}"#)
        #expect(event.message?.content == (clears ? .replace([]) : .unchanged))
    }

    @Test func contentMutationsFollowReceiveOrderWithoutDeduplicatingChunks() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var transcript = ACPV2MessageTranscript(context: context)
        let key = ACPV2MessageTranscript.Key(kind: .agent, messageID: "m")
        let trace: [(String, [LSPJSONValue])] = [
            (#"{"sessionUpdate":"agent_message_chunk","messageId":"m","content":{"type":"text","text":"A"}}"#, [text("A")]),
            (#"{"sessionUpdate":"agent_message_chunk","messageId":"m","content":{"type":"text","text":"A"}}"#, [text("A"), text("A")]),
            (#"{"sessionUpdate":"agent_message","messageId":"m","content":[{"type":"text","text":"B"}]}"#, [text("B")]),
            (#"{"sessionUpdate":"agent_message","messageId":"m"}"#, [text("B")]),
            (#"{"sessionUpdate":"agent_message_chunk","messageId":"m","content":{"type":"text","text":"C"}}"#, [text("B"), text("C")]),
            (#"{"sessionUpdate":"agent_message","messageId":"m","content":null}"#, []),
            (#"{"sessionUpdate":"agent_message_chunk","messageId":"m","content":{"type":"text","text":"D"}}"#, [text("D")]),
            (#"{"sessionUpdate":"agent_message","messageId":"m","content":[]}"#, []),
        ]
        for (json, expected) in trace {
            let event = try decode(json)
            let result = transcript.apply(event, context: context)
            #expect(result.event == event)
            #expect(result.disposition == .applied)
            #expect(transcript.message(for: key)?.content == expected)
        }
        #expect(transcript.messages.count == 1)
    }

    @Test func metadataPatchesRespectTopLevelKeysAndEventScope() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var transcript = ACPV2MessageTranscript(context: context)
        let trace: [(String, [String: LSPJSONValue])] = [
            (#"{"_meta":{"keep":true,"remove":1,"nested":{"old":1}}}"#,
                ["keep": .bool(true), "remove": .number("1"), "nested": .object(["old": .number("1")])]),
            (#"{"content":[],"_meta":{"remove":null,"nested":{"new":null}}}"#,
                ["keep": .bool(true), "nested": .object(["new": .null])]),
            (#"{"_meta":{}}"#, ["keep": .bool(true), "nested": .object(["new": .null])]),
            (#"{"content":null}"#, ["keep": .bool(true), "nested": .object(["new": .null])]),
            (#"{"_meta":null}"#, [:]),
            (#"{"_meta":{"absent":null}}"#, [:]),
        ]
        for (fields, expected) in trace {
            guard case .object(let patches) = try LSPJSONValue.decode(from: Data(fields.utf8)) else {
                Issue.record("Invalid fixture")
                return
            }
            let update = patches.merging(["sessionUpdate": .string("user_message"), "messageId": .string("m")]) { _, new in new }
            _ = transcript.apply(try envelope(update), context: context)
            #expect(transcript.messages.first?.metadata == expected)
        }
        _ = transcript.apply(try decode(#"{"sessionUpdate":"user_message_chunk","messageId":"m","content":{"type":"text","text":"x"},"_meta":{"chunk":true}}"#), context: context)
        #expect(transcript.messages.first?.metadata == [:])
    }

    @Test func entityTypeAndFirstObservationDetermineIdentityAndOrder() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var transcript = ACPV2MessageTranscript(context: context)
        for variant in ["agent_thought", "user_message", "agent_message"] {
            _ = transcript.apply(try envelope(["sessionUpdate": .string(variant), "messageId": .string("same"),
                "content": .array([text(variant)])]), context: context)
        }
        let replacement = try decode(#"{"sessionUpdate":"agent_thought","messageId":"same","content":[{"type":"text","text":"new"}]}"#)
        _ = transcript.apply(replacement, context: context)
        #expect(transcript.apply(replacement, context: context).effects.isEmpty)
        #expect(transcript.messages.map(\.key.kind) == [.thought, .user, .agent])
        #expect(transcript.messages.map(\.content) == [[text("new")], [text("user_message")], [text("agent_message")]])
    }

    @Test(arguments: [false, true])
    func foreignContextCannotMutateTranscript(otherSession: Bool) throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var transcript = ACPV2MessageTranscript(context: context)
        let event = try decode(#"{"sessionUpdate":"user_message","messageId":"m"}"#,
            sessionID: otherSession ? "other" : "s")
        let supplied = otherSession ? context
            : ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        let result = transcript.apply(event, context: supplied)
        #expect(result.disposition == .staleContext)
        #expect(result.event == event)
        #expect(result.effects.isEmpty)
        #expect(transcript.messages.isEmpty)
    }

    @Test func unhandledEventHasNoMessageEffects() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var transcript = ACPV2MessageTranscript(context: context)
        let event = try decode(#"{"sessionUpdate":"state_update","state":"idle"}"#)
        let result = transcript.apply(event, context: context)
        #expect(result.disposition == .unhandled)
        #expect(result.event == event)
        #expect(result.effects.isEmpty)
        #expect(transcript.messages.isEmpty)
    }

    @Test(arguments: [false, true])
    func acceptanceBindsItsExactRowInEitherDeliveryOrder(echoFirst: Bool) throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var transcript = ACPV2MessageTranscript(context: context)
        let row = UUID()
        let key = ACPV2MessageTranscript.Key(kind: .user, messageID: "m")
        #expect(transcript.register(requestID: 1, localRowID: row, context: context) == .registered)
        let event = try decode(#"{"sessionUpdate":"user_message_chunk","messageId":"m","content":{"type":"text","text":"server echo"}}"#)
        if echoFirst { _ = transcript.apply(event, context: context) }
        let result = transcript.accept(requestID: 1, response: try accepted("m"), context: context)
        #expect(result == (echoFirst ? .reconciled(key: key, localRowID: row) : .bound))
        if !echoFirst {
            #expect(transcript.messages.isEmpty)
            let effects = transcript.apply(event, context: context).effects
            #expect(effects.first == .reconcile(key: key, localRowID: row))
        }
        #expect(transcript.messages.count == 1)
        #expect(transcript.message(for: key)?.localRowID == row)
        #expect(transcript.message(for: key)?.content == [text("server echo")])
        #expect(transcript.accept(requestID: 1, response: try accepted("m"), context: context) == .unchanged)
        let metadataOnly = try decode(#"{"sessionUpdate":"user_message","messageId":"m","_meta":{}}"#)
        #expect(transcript.apply(metadataOnly, context: context).effects.isEmpty)
    }

    @Test func identicalSubmissionsBindByResponseIdentityRatherThanArrivalOrder() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var transcript = ACPV2MessageTranscript(context: context)
        let first = UUID(), second = UUID()
        _ = transcript.register(requestID: 1, localRowID: first, context: context)
        _ = transcript.register(requestID: 2, localRowID: second, context: context)
        for id in ["b", "a"] {
            _ = transcript.apply(try envelope(["sessionUpdate": .string("user_message"), "messageId": .string(id),
                "content": .array([text("identical")])]), context: context)
        }
        _ = transcript.accept(requestID: 2, response: try accepted("a"), context: context)
        _ = transcript.accept(requestID: 1, response: try accepted("b"), context: context)
        #expect(transcript.messages.map(\.key.messageID) == ["b", "a"])
        #expect(transcript.messages.map(\.localRowID) == [first, second])
        #expect(transcript.messages.map(\.content) == [[text("identical")], [text("identical")]])
    }

    @Test func conflictingAcceptancesLeaveValidBindingsIntact() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var transcript = ACPV2MessageTranscript(context: context)
        let first = UUID(), second = UUID()
        _ = transcript.register(requestID: 1, localRowID: first, context: context)
        _ = transcript.register(requestID: 2, localRowID: second, context: context)
        #expect(transcript.accept(requestID: 1, response: try accepted("a"), context: context) == .bound)
        #expect(transcript.accept(requestID: 1, response: try accepted("b"), context: context) == .conflict)
        #expect(transcript.accept(requestID: 2, response: try accepted("a"), context: context) == .conflict)
        #expect(transcript.accept(requestID: 2, response: try accepted("b"), context: context) == .bound)
        for id in ["a", "b"] {
            _ = transcript.apply(try envelope(["sessionUpdate": .string("user_message"), "messageId": .string(id)]), context: context)
        }
        #expect(transcript.messages.map(\.localRowID) == [first, second])
        _ = transcript.apply(try decode(#"{"sessionUpdate":"agent_message","messageId":"a"}"#), context: context)
        #expect(transcript.messages.last?.localRowID == nil)
    }

    @Test func localRowsCannotBeReassignedOrSharedByRequests() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var transcript = ACPV2MessageTranscript(context: context)
        let first = UUID(), second = UUID()
        #expect(transcript.register(requestID: 1, localRowID: first, context: context) == .registered)
        #expect(transcript.register(requestID: 1, localRowID: first, context: context) == .unchanged)
        #expect(transcript.register(requestID: 1, localRowID: second, context: context) == .conflict)
        #expect(transcript.register(requestID: 2, localRowID: first, context: context) == .conflict)
        #expect(transcript.register(requestID: 2, localRowID: second, context: context) == .registered)
        _ = transcript.accept(requestID: 1, response: try accepted("a"), context: context)
        _ = transcript.accept(requestID: 2, response: try accepted("b"), context: context)
        for id in ["a", "b"] {
            _ = transcript.apply(try envelope(["sessionUpdate": .string("user_message"), "messageId": .string(id)]), context: context)
        }
        #expect(transcript.messages.map(\.localRowID) == [first, second])
    }

    @Test func staleOrUnregisteredResponsesCannotClaimCurrentRequests() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        let old = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var transcript = ACPV2MessageTranscript(context: context)
        let row = UUID()
        _ = transcript.register(requestID: 1, localRowID: row, context: context)
        #expect(transcript.register(requestID: 1, localRowID: UUID(), context: old) == .staleContext)
        #expect(transcript.accept(requestID: 1, response: try accepted("m"), context: old) == .staleContext)
        #expect(transcript.accept(requestID: 2, response: try accepted("m"), context: context) == .unmatched)
        #expect(transcript.accept(requestID: 1, response: try accepted("m"), context: context) == .bound)
        _ = transcript.apply(try decode(#"{"sessionUpdate":"user_message","messageId":"m"}"#), context: context)
        #expect(transcript.messages.first?.localRowID == row)
    }

    @Test(arguments: [
        #"{"sessionUpdate":"tool_call_update","toolCallId":"shared","rawInput":{"opaque":1e999}}"#,
        #"{"sessionUpdate":"tool_call_content_chunk","toolCallId":"shared","content":{"type":"_future","value":1e999},"_meta":{"chunk":null}}"#,
        #"{"sessionUpdate":"plan_update","plan":{"type":"items","planId":"shared","entries":[{"content":"x","priority":"_future","status":"future"}],"_meta":{"plan":null}}}"#,
        #"{"sessionUpdate":"terminal_update","terminalId":"shared","output":{"data":"YQ==","_meta":{"snapshot":null}},"exitStatus":{}}"#,
        #"{"sessionUpdate":"terminal_output_chunk","terminalId":"shared","data":"Yg==","_meta":{"chunk":null}}"#,
    ])
    func activityEnvelopesKeepTypedAndRawValues(update: String) throws {
        let event = try decode(update)
        guard case .object(let fields) = try LSPJSONValue.decode(from: Data(update.utf8)) else {
            Issue.record("Invalid fixture")
            return
        }
        switch (fields["sessionUpdate"], event.payload) {
        case (.string("tool_call_update"), .toolCall(let value)):
            #expect(value.toolCallID == "shared")
            #expect(value.rawInput == .value(.object(["opaque": .number("1e999")])))
        case (.string("tool_call_content_chunk"), .toolContentChunk(let value)):
            #expect(value.toolCallID == "shared")
            #expect(value.content.rawValue == .object(["type": .string("_future"), "value": .number("1e999")]))
        case (.string("plan_update"), .plan(let value)):
            #expect(value.planID == "shared")
            #expect(value.entries?.count == 1)
        case (.string("terminal_update"), .terminal(let value)):
            guard case .value(let output) = value.output else {
                Issue.record("Snapshot was not decoded")
                return
            }
            #expect(output.data == Data([0x61]))
            #expect(output.metadata == ["snapshot": .null])
        case (.string("terminal_output_chunk"), .terminalOutputChunk(let value)):
            #expect(value.terminalID == "shared")
            #expect(value.data == Data([0x62]))
        default: Issue.record("Wrong typed activity payload")
        }
        #expect(event.message == nil)
        #expect(try LSPJSONValue.decode(from: event.encodedData()) == event.rawValue)
    }

    @Test(arguments: [
        #"{"sessionUpdate":"tool_call_update","toolCallId":null}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"t","status":7}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"t","content":{}}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"t","locations":[{"path":"p","line":-1}]}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"t","locations":[{"path":7}]}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"t","_meta":[]}"#,
        #"{"sessionUpdate":"tool_call_content_chunk","toolCallId":"t"}"#,
        #"{"sessionUpdate":"tool_call_content_chunk","toolCallId":"t","content":{"type":"terminal"}}"#,
        #"{"sessionUpdate":"tool_call_content_chunk","toolCallId":"t","content":{"type":"_future","_meta":[]}}"#,
        #"{"sessionUpdate":"plan_update"}"#,
        #"{"sessionUpdate":"plan_update","plan":{"type":"_future"}}"#,
        #"{"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p","entries":null}}"#,
        #"{"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p","entries":[{"content":"x","status":"pending"}]}}"#,
        #"{"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p","entries":[{"content":"x","priority":"high","status":false}]}}"#,
        #"{"sessionUpdate":"plan_update","plan":{"type":"_future","planId":"p","_meta":[]}}"#,
        #"{"sessionUpdate":"terminal_update","terminalId":false}"#,
        #"{"sessionUpdate":"terminal_update","terminalId":"t","command":2}"#,
        #"{"sessionUpdate":"terminal_update","terminalId":"t","cwd":[]}"#,
        #"{"sessionUpdate":"terminal_update","terminalId":"t","output":{}}"#,
        #"{"sessionUpdate":"terminal_update","terminalId":"t","output":{"data":"%%%"}}"#,
        #"{"sessionUpdate":"terminal_update","terminalId":"t","output":{"data":"","_meta":[]}}"#,
        #"{"sessionUpdate":"terminal_update","terminalId":"t","exitStatus":{"signal":true}}"#,
        #"{"sessionUpdate":"terminal_update","terminalId":"t","exitStatus":{"_meta":[]}}"#,
        #"{"sessionUpdate":"terminal_output_chunk","terminalId":"t"}"#,
        #"{"sessionUpdate":"terminal_output_chunk","terminalId":"t","data":null}"#,
        #"{"sessionUpdate":"terminal_output_chunk","terminalId":"t","data":"YR=="}"#,
    ])
    func malformedActivityFieldsAreRejected(update: String) {
        #expect(throws: DecodingError.self) { try decode(update) }
    }

    @Test(arguments: [
        ("0", UInt32?.some(0)), ("-0", .some(0)), ("1e2", .some(100)),
        ("1.0", .some(1)), ("4294967295", .some(UInt32.max)),
        ("-1", nil), ("1.5", nil), ("4294967296", nil), ("1e999", nil),
        ("4294967295.00000000000000000000000000000000000001", nil),
        ("1e-999999999999999999999999999999999999999", nil),
    ])
    func unsignedFieldsFollowNumericValueRatherThanTokenSpelling(token: String, expected: UInt32?) throws {
        let json = #"{"sessionUpdate":"terminal_update","terminalId":"t","exitStatus":{"exitCode":\#(token)}}"#
        if let expected {
            let event = try decode(json)
            guard case .terminal(let terminal) = event.payload, case .value(let exit) = terminal.exitStatus else {
                Issue.record("Expected a typed exit report")
                return
            }
            #expect(exit.exitCode == expected)
        } else {
            #expect(throws: DecodingError.self) { try decode(json) }
        }
    }

    @Test(arguments: ["1-2", "00", "1.", "0e", "--0", " 1"])
    func malformedRawNumberTokensAreRejectedBeforeInterpretation(token: String) {
        #expect(throws: DecodingError.self) {
            try envelope(["sessionUpdate": .string("terminal_update"), "terminalId": .string("t"),
                "exitStatus": .object(["exitCode": .number(token)])])
        }
    }

    private func accepted(_ messageID: String) throws -> ACPV2PromptAccepted {
        try JSONDecoder().decode(ACPV2PromptAccepted.self,
            from: LSPJSONValue.object(["messageId": .string(messageID)]).encodedData())
    }

    private func text(_ value: String) -> LSPJSONValue { .object(["type": .string("text"), "text": .string(value)]) }

    private func envelope(_ update: [String: LSPJSONValue]) throws -> ACPV2SessionUpdateEnvelope {
        try ACPV2SessionUpdateEnvelope(rawValue: .object(["sessionId": .string("s"), "update": .object(update)]))
    }

    private func decode(_ update: String, sessionID: String = "s") throws -> ACPV2SessionUpdateEnvelope {
        try ACPV2SessionUpdateEnvelope.decode(from: Data("{\"sessionId\":\"\(sessionID)\",\"update\":\(update)}".utf8))
    }
}
