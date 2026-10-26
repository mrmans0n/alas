import Foundation
import Testing
import AlasCore

struct ACPV2SessionStateTests {
    @Test func interleavedEntitiesKeepOneFirstObservationOrder() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2SessionState(context: context)
        let trace = [
            #"{"sessionUpdate":"agent_message","messageId":"same"}"#,
            #"{"sessionUpdate":"terminal_output_chunk","terminalId":"pre","data":""}"#,
            #"{"sessionUpdate":"tool_call_update","toolCallId":"same","content":[{"type":"terminal","terminalId":"a"},{"type":"terminal","terminalId":"pre"},{"type":"terminal","terminalId":"b"}]}"#,
            #"{"sessionUpdate":"user_message","messageId":"same"}"#,
            #"{"sessionUpdate":"plan_update","plan":{"type":"items","planId":"same","entries":[]}}"#,
            #"{"sessionUpdate":"agent_thought","messageId":"same"}"#,
            #"{"sessionUpdate":"terminal_update","terminalId":"same"}"#,
            #"{"sessionUpdate":"state_update","state":"running"}"#,
            #"{"sessionUpdate":"agent_message","messageId":"same","content":[{"type":"text","text":"replaced"}]}"#,
            #"{"sessionUpdate":"tool_call_update","toolCallId":"same","content":[]}"#,
        ]
        for json in trace {
            let update = try event(json)
            let result = try state.apply(update, source: .live, context: context)
            #expect(result.event == update)
            #expect(result.disposition == .applied)
        }
        #expect(state.order == [.message(.init(kind: .agent, messageID: "same")), .terminal("pre"),
            .toolCall("same"), .terminal("a"), .terminal("b"), .message(.init(kind: .user, messageID: "same")),
            .plan("same"), .message(.init(kind: .thought, messageID: "same")), .terminal("same")])
        #expect(state.activity.terminal(id: "a") != nil)
        #expect(state.transcript.messages.count == 3)
        #expect(state.lifecycle.foreground == .running)
        #expect(state.lifecycle.lastForegroundCompletion == nil)
    }

    @Test func stateProvenanceSeparatesSynchronizationFromCompletion() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2SessionState(context: context)
        let idle = try event(#"{"sessionUpdate":"state_update","state":"idle"}"#)
        _ = try state.apply(idle, source: .setupDefault, context: context)
        let running = try event(#"{"sessionUpdate":"state_update","state":"running","future":1e999}"#)
        _ = try state.apply(running, source: .live, context: context)
        #expect(try state.apply(idle, source: .setupDefault, context: context).effects.isEmpty)
        #expect(state.latestStateObservation?.event == running)
        #expect(state.latestStateObservation?.source == .live)
        _ = try state.apply(idle, source: .snapshot, context: context)
        #expect(state.lifecycle.lastForegroundCompletion == nil)
        _ = try state.apply(running, source: .live, context: context)
        let end = try event(#"{"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn"}"#)
        let result = try state.apply(end, source: .live, context: context)
        #expect(result.effects == [.lifecycle(.foregroundChanged(.idle)),
            .lifecycle(.foregroundEnded(.init(generation: 2, result: .completed)))])
        let repeated = try event(#"{"sessionUpdate":"state_update","state":"idle","stopReason":"cancelled","future":1e999}"#)
        #expect(try state.apply(repeated, source: .live, context: context).effects.isEmpty)
        #expect(state.latestStateObservation?.event == repeated)
        #expect(state.lifecycle.lastForegroundCompletion?.result == .completed)
        _ = try state.apply(try event(#"{"sessionUpdate":"state_update","state":"_future"}"#), source: .live, context: context)
        #expect(state.lifecycle.foreground == .unrecognized("_future"))
    }

    @Test(arguments: [
        #"{"sessionUpdate":"state_update","state":"running"}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"t"}"#,
    ])
    func invalidSetupDefaultsCannotMutateState(json: String) throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2SessionState(context: context)
        #expect(throws: ACPV2SessionState.ApplicationError.self) {
            try state.apply(event(json), source: .setupDefault, context: context)
        }
        #expect(state.latestStateObservation == nil)
        #expect(state.lifecycle.foreground == .unknown)
        #expect(state.order.isEmpty)
    }

    @Test(arguments: [false, true])
    func staleNotificationsCannotChangeEntitiesOrForeground(otherSession: Bool) throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2SessionState(context: context)
        let running = try event(#"{"sessionUpdate":"state_update","state":"running"}"#)
        _ = try state.apply(running, source: .live, context: context)
        let supplied = otherSession ? context : .init(sessionID: "s", connectionID: UUID())
        for json in [#"{"sessionUpdate":"tool_call_update","toolCallId":"t","content":[{"type":"terminal","terminalId":"x"}]}"#,
                     #"{"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn"}"#] {
            let update = try event(json, sessionID: otherSession ? "other" : "s")
            let result = try state.apply(update, source: .live, context: supplied)
            #expect(result.disposition == .staleContext)
            #expect(result.effects.isEmpty)
        }
        #expect(state.order.isEmpty)
        #expect(state.activity.order.isEmpty)
        #expect(state.lifecycle.foreground == .running)
        #expect(state.latestStateObservation?.event == running)
        #expect(state.lifecycle.lastForegroundCompletion == nil)
    }

    @Test func unknownUpdatesRemainRawWithoutChangingState() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2SessionState(context: context)
        let unknown = try event(#"{"sessionUpdate":"_future","data":1e999}"#)
        let result = try state.apply(unknown, source: .live, context: context)
        #expect(result.disposition == .unhandled)
        #expect(result.event == unknown)
        #expect(result.effects.isEmpty)
        #expect(state.order.isEmpty)
        #expect(state.latestStateObservation == nil)
    }

    @Test(arguments: [false, true])
    func acceptanceReconcilesTheObservedMessageInEitherOrder(echoFirst: Bool) throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2SessionState(context: context)
        let row = UUID(), key = ACPV2MessageTranscript.Key(kind: .user, messageID: "m")
        #expect(state.register(requestID: 1, localRowID: row, context: context).disposition == .registered)
        let echo = try event(#"{"sessionUpdate":"user_message","messageId":"m","content":[{"type":"text","text":"hello"}]}"#)
        if echoFirst { _ = try state.apply(echo, source: .live, context: context) }
        let response = try accepted("m")
        let result = state.accept(requestID: 1, response: response, context: context)
        #expect(result.response == response)
        #expect(result.disposition == .accepted)
        if echoFirst {
            let message = try #require(state.transcript.message(for: key))
            #expect(result.effects == [.message(.reconcile(key: key, localRowID: row)), .message(.messageChanged(message)),
                .lifecycle(.accepted(requestID: 1, messageID: "m"))])
        } else {
            #expect(state.order.isEmpty)
            #expect(result.effects == [.lifecycle(.accepted(requestID: 1, messageID: "m"))])
            _ = try state.apply(echo, source: .live, context: context)
        }
        #expect(state.transcript.message(for: key)?.localRowID == row)
        #expect(state.order == [.message(key)])
        #expect(state.lifecycle.submission(1) == .accepted(messageID: "m"))
        #expect(state.lifecycle.lastForegroundCompletion == nil)
        #expect(state.accept(requestID: 1, response: response, context: context).effects.isEmpty)
    }

    @Test func identicalSubmissionsBindByRequestWithReversedResponses() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2SessionState(context: context)
        let rows = [UUID(), UUID()]
        for (offset, id) in ["a", "b"].enumerated() {
            _ = state.register(requestID: offset, localRowID: rows[offset], context: context)
            _ = try state.apply(event(#"{"sessionUpdate":"user_message","messageId":"\#(id)","content":[{"type":"text","text":"same"}]}"#), source: .live, context: context)
        }
        _ = state.accept(requestID: 1, response: try accepted("b"), context: context)
        _ = state.accept(requestID: 0, response: try accepted("a"), context: context)
        #expect(state.transcript.messages.map(\.localRowID) == rows.map(Optional.some))
    }

    @Test func conflictingPromptOutcomesChangeNeitherBindingNorLifecycle() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2SessionState(context: context)
        let firstRow = UUID(), secondRow = UUID()
        _ = state.register(requestID: 1, localRowID: firstRow, context: context)
        #expect(state.register(requestID: 1, localRowID: secondRow, context: context).disposition == .conflict)
        #expect(state.register(requestID: 2, localRowID: firstRow, context: context).disposition == .conflict)
        #expect(state.lifecycle.submission(2) == nil)
        _ = state.register(requestID: 2, localRowID: secondRow, context: context)
        _ = state.accept(requestID: 2, response: try accepted("shared"), context: context)
        #expect(state.accept(requestID: 1, response: try accepted("shared"), context: context).disposition == .conflict)
        #expect(state.lifecycle.submission(1) == .pending)
        _ = state.reject(requestID: 1, context: context)
        #expect(state.accept(requestID: 1, response: try accepted("free"), context: context).disposition == .conflict)
        #expect(state.reject(requestID: 2, context: context).disposition == .conflict)
        #expect(state.accept(requestID: 2, response: try accepted("different"), context: context).disposition == .conflict)
        _ = state.register(requestID: 1, localRowID: firstRow, context: context)
        #expect(state.lifecycle.submission(1) == .rejected)
        #expect(state.lifecycle.submission(2) == .accepted(messageID: "shared"))
        for id in ["shared", "free", "different"] {
            _ = try state.apply(event(#"{"sessionUpdate":"user_message","messageId":"\#(id)"}"#), source: .live, context: context)
        }
        #expect(state.transcript.messages.map(\.localRowID) == [secondRow, nil, nil])
        #expect(state.accept(requestID: 99, response: try accepted("free"), context: context).disposition == .unmatched)
        #expect(state.reject(requestID: 99, context: context).disposition == .unmatched)
        #expect(state.reject(requestID: 1, context: context).effects.isEmpty)
    }

    @Test(arguments: [false, true])
    func acceptanceCannotFinishForegroundWorkBeforeOrAfterIdle(idleFirst: Bool) throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2SessionState(context: context)
        _ = state.register(requestID: 1, localRowID: UUID(), context: context)
        _ = try state.apply(event(#"{"sessionUpdate":"state_update","state":"running"}"#), source: .live, context: context)
        let end = try event(#"{"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn"}"#)
        if idleFirst { _ = try state.apply(end, source: .live, context: context) }
        let prior = state.lifecycle.lastForegroundCompletion
        #expect(state.accept(requestID: 1, response: try accepted("m"), context: context).effects == [.lifecycle(.accepted(requestID: 1, messageID: "m"))])
        #expect(state.lifecycle.lastForegroundCompletion == prior)
        if !idleFirst { _ = try state.apply(end, source: .live, context: context) }
        #expect(try state.apply(end, source: .live, context: context).effects.isEmpty)
        #expect(state.lifecycle.lastForegroundCompletion == .init(generation: 1, result: .completed))
    }

    @Test func rejectionAndObservationLossCannotInventForegroundCompletion() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2SessionState(context: context)
        for id in 1...3 { _ = state.register(requestID: id, localRowID: UUID(), context: context) }
        _ = state.accept(requestID: 3, response: try accepted("accepted"), context: context)
        _ = try state.apply(event(#"{"sessionUpdate":"tool_call_update","toolCallId":"t","content":[{"type":"terminal","terminalId":"x"}]}"#), source: .live, context: context)
        let running = try event(#"{"sessionUpdate":"state_update","state":"running"}"#)
        _ = try state.apply(running, source: .live, context: context)
        _ = state.reject(requestID: 1, context: context)
        #expect(state.lifecycle.foreground == .running)
        let order = state.order
        #expect(state.loseObservation(context: context) == [.lifecycle(.uncertain(requestID: 2)), .lifecycle(.foregroundChanged(.unknown))])
        #expect(state.lifecycle.submission(1) == .rejected)
        #expect(state.lifecycle.submission(2) == .uncertain)
        #expect(state.lifecycle.submission(3) == .accepted(messageID: "accepted"))
        #expect(state.lifecycle.lastForegroundCompletion == nil)
        #expect(state.order == order)
        #expect(state.latestStateObservation?.event == running)
        _ = try state.apply(event(#"{"sessionUpdate":"state_update","state":"idle"}"#), source: .setupDefault, context: context)
        #expect(state.lifecycle.foreground == .unknown)
        #expect(state.latestStateObservation?.event == running)
        #expect(state.accept(requestID: 2, response: try accepted("late"), context: context).disposition == .accepted)
    }

    @Test(arguments: [false, true])
    func stalePromptOperationsCannotRegisterBindRejectOrLoseObservation(otherSession: Bool) throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        let stale = ACPV2MessageTranscript.Context(sessionID: otherSession ? "other" : "s", connectionID: otherSession ? context.connectionID : UUID())
        var state = ACPV2SessionState(context: context)
        let row = UUID()
        #expect(state.register(requestID: 1, localRowID: row, context: stale).disposition == .staleContext)
        #expect(state.lifecycle.submission(1) == nil)
        _ = state.register(requestID: 1, localRowID: row, context: context)
        #expect(state.accept(requestID: 1, response: try accepted("m"), context: stale).effects.isEmpty)
        #expect(state.reject(requestID: 1, context: stale).disposition == .staleContext)
        _ = try state.apply(event(#"{"sessionUpdate":"user_message","messageId":"m"}"#), source: .live, context: context)
        _ = try state.apply(event(#"{"sessionUpdate":"state_update","state":"running"}"#), source: .live, context: context)
        #expect(state.loseObservation(context: stale).isEmpty)
        #expect(state.transcript.messages.first?.localRowID == nil)
        #expect(state.lifecycle.submission(1) == .pending)
        #expect(state.lifecycle.foreground == .running)
    }

    private func accepted(_ messageID: String) throws -> ACPV2PromptAccepted {
        try ACPV2PromptAccepted(rawValue: .object(["messageId": .string(messageID)]))
    }

    private func event(_ update: String, sessionID: String = "s") throws -> ACPV2SessionUpdateEnvelope {
        try ACPV2SessionUpdateEnvelope.decode(from: Data("{\"sessionId\":\"\(sessionID)\",\"update\":\(update)}".utf8))
    }
}
