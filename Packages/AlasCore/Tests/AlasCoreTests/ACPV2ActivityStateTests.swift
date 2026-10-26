import Foundation
import Testing
import AlasCore

struct ACPV2ActivityStateTests {
    @Test func toolUpdatesClearOnlySuppliedFieldsAndPatchMetadata() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2ActivityState(context: context)
        _ = state.apply(try event(#"{"sessionUpdate":"tool_call_update","toolCallId":"t","name":"read","title":"Reading","kind":"_future","status":"in_progress","rawInput":{"large":1e999},"rawOutput":7,"locations":[{"path":"/remote/file","line":1e2}],"_meta":{"keep":true,"remove":1,"nested":{"old":1}}}"#), context: context)
        _ = state.apply(try event(#"{"sessionUpdate":"tool_call_update","toolCallId":"t","name":null,"rawInput":null,"locations":null,"status":"future","_meta":{"remove":null,"nested":{"new":null}}}"#), context: context)
        let tool = try #require(state.toolCall(id: "t"))
        #expect(tool.name == nil)
        #expect(tool.title == "Reading")
        #expect(tool.kind == "_future")
        #expect(tool.status == "future")
        #expect(tool.rawInput == nil)
        #expect(tool.rawOutput == .number("7"))
        #expect(tool.locations.isEmpty)
        #expect(tool.metadata == ["keep": .bool(true), "nested": .object(["new": .null])])
        _ = state.apply(try event(#"{"sessionUpdate":"tool_call_update","toolCallId":"t","status":null,"kind":null,"rawOutput":null}"#), context: context)
        #expect(state.toolCall(id: "t")?.status == nil)
        #expect(state.toolCall(id: "t")?.kind == nil)
        #expect(state.toolCall(id: "t")?.rawOutput == nil)
        #expect(state.toolCall(id: "t")?.title == "Reading")
    }

    @Test func toolChunksCreateCallsAndLaterReplacementsDiscardEarlierContent() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2ActivityState(context: context)
        let chunk = try event(#"{"sessionUpdate":"tool_call_content_chunk","toolCallId":"t","content":{"type":"_future","value":"A"}}"#)
        _ = state.apply(chunk, context: context)
        _ = state.apply(chunk, context: context)
        #expect(state.toolCall(id: "t")?.content.map(\.rawValue) == [item("A"), item("A")])
        #expect(state.toolCall(id: "t")?.status == "pending")
        #expect(state.toolCall(id: "t")?.kind == "other")
        let replacement = try event(#"{"sessionUpdate":"tool_call_update","toolCallId":"t","content":[{"type":"_future","value":"B"}]}"#)
        _ = state.apply(replacement, context: context)
        #expect(state.apply(replacement, context: context).effects.isEmpty)
        _ = state.apply(chunk, context: context)
        #expect(state.toolCall(id: "t")?.content.map(\.rawValue) == [item("B"), item("A")])
        _ = state.apply(try event(#"{"sessionUpdate":"tool_call_update","toolCallId":"t","content":null}"#), context: context)
        #expect(state.toolCall(id: "t")?.content.isEmpty == true)
    }

    @Test func toolChunkAndContentMetadataDoNotPatchTheEntity() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2ActivityState(context: context)
        _ = state.apply(try event(#"{"sessionUpdate":"tool_call_update","toolCallId":"t","_meta":{"entity":true}}"#), context: context)
        let chunk = try event(#"{"sessionUpdate":"tool_call_content_chunk","toolCallId":"t","content":{"type":"_future","_meta":{"content":true}},"_meta":{"chunk":true}}"#)
        let reduction = state.apply(chunk, context: context)
        #expect(reduction.event == chunk)
        #expect(state.toolCall(id: "t")?.metadata == ["entity": .bool(true)])
        _ = state.apply(try event(#"{"sessionUpdate":"tool_call_update","toolCallId":"t","content":[],"_meta":{}}"#), context: context)
        #expect(state.toolCall(id: "t")?.metadata == ["entity": .bool(true)])
        _ = state.apply(try event(#"{"sessionUpdate":"tool_call_update","toolCallId":"t","_meta":null}"#), context: context)
        #expect(state.toolCall(id: "t")?.metadata == [:])
    }

    @Test func identifiedPlansReplaceTheirWholeValueIncludingOpaqueTypes() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2ActivityState(context: context)
        let first = try event(#"{"sessionUpdate":"plan_update","plan":{"type":"items","planId":"a","entries":[{"content":"Do","priority":"future","status":"_future"}],"_meta":{"old":true}}}"#)
        _ = state.apply(first, context: context)
        _ = state.apply(try event(#"{"sessionUpdate":"plan_update","plan":{"type":"items","planId":"b","entries":[]}}"#), context: context)
        #expect(state.plan(id: "a")?.entries?.count == 1)
        _ = state.apply(try event(#"{"sessionUpdate":"plan_update","plan":{"type":"_future","planId":"a","data":1e999}}"#), context: context)
        #expect(state.plan(id: "a")?.entries == nil)
        #expect(state.plan(id: "a")?.rawValue == .object(["type": .string("_future"), "planId": .string("a"), "data": .number("1e999")]))
        let empty = try event(#"{"sessionUpdate":"plan_update","plan":{"type":"items","planId":"a","entries":[]},"_meta":{"event":true}}"#)
        _ = state.apply(empty, context: context)
        #expect(state.apply(empty, context: context).effects.isEmpty)
        #expect(state.plan(id: "a")?.entries == [])
        #expect(state.plan(id: "b")?.entries == [])
        #expect(state.order == [.plan("a"), .plan("b")])
    }

    @Test func activityTypesAndMessagesKeepIndependentIdentities() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2ActivityState(context: context)
        var messages = ACPV2MessageTranscript(context: context)
        _ = state.apply(try event(#"{"sessionUpdate":"tool_call_update","toolCallId":"same"}"#), context: context)
        _ = state.apply(try event(#"{"sessionUpdate":"plan_update","plan":{"type":"items","planId":"same","entries":[]}}"#), context: context)
        let user = try event(#"{"sessionUpdate":"user_message","messageId":"same"}"#)
        #expect(state.apply(user, context: context).disposition == .unhandled)
        _ = messages.apply(user, context: context)
        #expect(state.order == [.toolCall("same"), .plan("same")])
        #expect(messages.messages.map(\.key.messageID) == ["same"])
        #expect(state.toolCall(id: "same")?.status == "pending")
        _ = state.apply(try event(#"{"sessionUpdate":"terminal_update","terminalId":"same"}"#), context: context)
        _ = state.apply(try event(#"{"sessionUpdate":"tool_call_content_chunk","toolCallId":"same","content":{"type":"_future","terminalId":"phantom"}}"#), context: context)
        #expect(state.order == [.toolCall("same"), .plan("same"), .terminal("same")])
        #expect(state.terminal(id: "phantom") == nil)
    }

    @Test(arguments: [false, true])
    func staleActivityAndUnhandledEventsLeaveStateUnchanged(otherSession: Bool) throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2ActivityState(context: context)
        let supplied = otherSession ? context : ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        let update = try event(#"{"sessionUpdate":"tool_call_update","toolCallId":"t"}"#, sessionID: otherSession ? "other" : "s")
        let result = state.apply(update, context: supplied)
        #expect(result.disposition == .staleContext)
        #expect(result.event == update)
        #expect(result.effects.isEmpty)
        let notice = try event(#"{"sessionUpdate":"notice","title":"x"}"#)
        #expect(state.apply(notice, context: context).disposition == .unhandled)
        #expect(state.order.isEmpty)
    }

    @Test func aDisplayTerminalUpdateCreatesStateWithoutAToolReference() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2ActivityState(context: context)
        let update = try event(#"{"sessionUpdate":"terminal_update","terminalId":"t","output":{"data":"YQ=="}}"#)
        #expect(state.apply(update, context: context).disposition == .applied)
        #expect(state.order == [.terminal("t")])
    }

    @Test(arguments: [false, true])
    func terminalReferencesResolveInEitherOrderAndSurviveReferenceRemoval(referenceFirst: Bool) throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2ActivityState(context: context)
        let reference = try event(#"{"sessionUpdate":"tool_call_content_chunk","toolCallId":"same","content":{"type":"terminal","terminalId":"same","_meta":{"anchor":true}}}"#)
        let update = try event(#"{"sessionUpdate":"terminal_update","terminalId":"same","command":"remote command","cwd":"C:\\remote","output":{"data":"YQ=="},"_meta":{"terminal":true}}"#)
        if referenceFirst {
            _ = state.apply(reference, context: context)
            let placeholder = try #require(state.terminal(id: "same"))
            #expect(placeholder.output.isEmpty)
            #expect(placeholder.exitStatus == nil)
            _ = state.apply(update, context: context)
        } else {
            _ = state.apply(update, context: context)
            _ = state.apply(reference, context: context)
        }
        #expect(state.order == (referenceFirst ? [.toolCall("same"), .terminal("same")] : [.terminal("same"), .toolCall("same")]))
        #expect(state.terminal(id: "same")?.output == Data([0x61]))
        #expect(state.terminal(id: "same")?.command == "remote command")
        #expect(state.terminal(id: "same")?.cwd == "C:\\remote")
        #expect(state.terminal(id: "same")?.metadata == ["terminal": .bool(true)])
        _ = state.apply(try event(#"{"sessionUpdate":"tool_call_update","toolCallId":"same","content":[]}"#), context: context)
        _ = state.apply(try event(#"{"sessionUpdate":"terminal_update","terminalId":"same","command":null}"#), context: context)
        #expect(state.terminal(id: "same")?.command == nil)
        #expect(state.terminal(id: "same")?.cwd == "C:\\remote")
        _ = state.apply(try event(#"{"sessionUpdate":"terminal_update","terminalId":"same","cwd":null}"#), context: context)
        #expect(state.terminal(id: "same")?.cwd == nil)
        #expect(state.terminal(id: "same")?.output == Data([0x61]))
    }

    @Test func terminalBytesAppendPerChunkAndSnapshotsReplaceAllPriorBytes() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2ActivityState(context: context)
        let trace: [(String, [UInt8])] = [
            (#"{"sessionUpdate":"terminal_output_chunk","terminalId":"t","data":"4g=="}"#, [0xe2]),
            (#"{"sessionUpdate":"terminal_output_chunk","terminalId":"t","data":"gqw="}"#, [0xe2, 0x82, 0xac]),
            (#"{"sessionUpdate":"terminal_output_chunk","terminalId":"t","data":"G1s="}"#, [0xe2, 0x82, 0xac, 0x1b, 0x5b]),
            (#"{"sessionUpdate":"terminal_output_chunk","terminalId":"t","data":"MzFt"}"#, [0xe2, 0x82, 0xac, 0x1b, 0x5b, 0x33, 0x31, 0x6d]),
            (#"{"sessionUpdate":"terminal_output_chunk","terminalId":"t","data":"YQ=="}"#, [0xe2, 0x82, 0xac, 0x1b, 0x5b, 0x33, 0x31, 0x6d, 0x61]),
            (#"{"sessionUpdate":"terminal_output_chunk","terminalId":"t","data":"YQ=="}"#, [0xe2, 0x82, 0xac, 0x1b, 0x5b, 0x33, 0x31, 0x6d, 0x61, 0x61]),
            (#"{"sessionUpdate":"terminal_update","terminalId":"t","output":{"data":"Yg=="}}"#, [0x62]),
            (#"{"sessionUpdate":"terminal_output_chunk","terminalId":"t","data":"Yw=="}"#, [0x62, 0x63]),
            (#"{"sessionUpdate":"terminal_update","terminalId":"t","output":null}"#, []),
        ]
        for (json, bytes) in trace {
            let update = try event(json)
            #expect(state.apply(update, context: context).event == update)
            #expect(state.terminal(id: "t")?.output == Data(bytes))
        }
    }

    @Test func terminalMetadataKeepsEntitySnapshotChunkAndExitScopesSeparate() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2ActivityState(context: context)
        _ = state.apply(try event(#"{"sessionUpdate":"terminal_update","terminalId":"t","output":{"data":"YQ==","_meta":{"snapshot":null}},"_meta":{"entity":true}}"#), context: context)
        _ = state.apply(try event(#"{"sessionUpdate":"terminal_output_chunk","terminalId":"t","data":"Yg==","_meta":{"chunk":true}}"#), context: context)
        #expect(state.terminal(id: "t")?.snapshotMetadata == ["snapshot": .null])
        #expect(state.terminal(id: "t")?.metadata == ["entity": .bool(true)])
        _ = state.apply(try event(#"{"sessionUpdate":"terminal_update","terminalId":"t","_meta":{"nested":{"new":null}}}"#), context: context)
        #expect(state.terminal(id: "t")?.snapshotMetadata == ["snapshot": .null])
        _ = state.apply(try event(#"{"sessionUpdate":"terminal_update","terminalId":"t","output":{"data":"YQ==","_meta":{}}}"#), context: context)
        #expect(state.terminal(id: "t")?.snapshotMetadata == [:])
        let replacement = try event(#"{"sessionUpdate":"terminal_update","terminalId":"t","output":{"data":"YQ=="}}"#)
        _ = state.apply(replacement, context: context)
        #expect(state.apply(replacement, context: context).effects.isEmpty)
        #expect(state.terminal(id: "t")?.snapshotMetadata == nil)
        #expect(state.terminal(id: "t")?.metadata == ["entity": .bool(true), "nested": .object(["new": .null])])
        _ = state.apply(try event(#"{"sessionUpdate":"terminal_update","terminalId":"t","_meta":null,"exitStatus":{"_meta":{"exit":null}}}"#), context: context)
        #expect(state.terminal(id: "t")?.metadata == [:])
        #expect(state.terminal(id: "t")?.exitStatus?.metadata == ["exit": .null])
        #expect(state.terminal(id: "t")?.output == Data([0x61]))
    }

    @Test func terminalExitReportsReplaceRatherThanMergeAndNullClearsTheReport() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2ActivityState(context: context)
        let trace: [(String, LSPJSONValue?)] = [
            ("", nil),
            (#", "exitStatus":{}"#, .object([:])),
            (#", "exitStatus":{"exitCode":1}"#, .object(["exitCode": .number("1")])),
            (#", "exitStatus":{"signal":"SIGTERM"}"#, .object(["signal": .string("SIGTERM")])),
            ("", .object(["signal": .string("SIGTERM")])),
            (#", "exitStatus":null"#, nil),
        ]
        for (fields, expected) in trace {
            _ = state.apply(try event(#"{"sessionUpdate":"terminal_update","terminalId":"t"\#(fields)}"#), context: context)
            #expect(state.terminal(id: "t")?.exitStatus?.rawValue == expected)
        }
    }

    @Test func toolStatusAndTerminalExitNeverCompleteEachOther() throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2ActivityState(context: context)
        _ = state.apply(try event(#"{"sessionUpdate":"tool_call_update","toolCallId":"t","status":"completed","content":[{"type":"terminal","terminalId":"t"}]}"#), context: context)
        let terminal = try #require(state.terminal(id: "t"))
        #expect(terminal.exitStatus == nil)
        _ = state.apply(try event(#"{"sessionUpdate":"tool_call_update","toolCallId":"t","status":"in_progress"}"#), context: context)
        _ = state.apply(try event(#"{"sessionUpdate":"terminal_update","terminalId":"t","exitStatus":{"exitCode":0}}"#), context: context)
        #expect(state.toolCall(id: "t")?.status == "in_progress")
        #expect(state.terminal(id: "t")?.exitStatus?.exitCode == 0)
    }

    @Test(arguments: [false, true])
    func staleReferencesCreateNeitherToolsNorTerminals(otherSession: Bool) throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2ActivityState(context: context)
        let supplied = otherSession ? context : ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        let reference = try event(#"{"sessionUpdate":"tool_call_update","toolCallId":"t","content":[{"type":"terminal","terminalId":"x"}]}"#, sessionID: otherSession ? "other" : "s")
        #expect(state.apply(reference, context: supplied).disposition == .staleContext)
        #expect(state.terminal(id: "x") == nil)
        #expect(state.toolCall(id: "t") == nil)
        #expect(state.order.isEmpty)
    }

    @Test(arguments: [
        #"{"sessionUpdate":"terminal_update","terminalId":"t","command":"new","output":{"data":"!"},"_meta":null}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"t","title":"new","content":[{"type":"terminal","terminalId":"new"},{"type":"terminal","terminalId":null}]}"#,
    ])
    func malformedInterpretedFieldsCannotPartlyMutateState(update: String) throws {
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: UUID())
        var state = ACPV2ActivityState(context: context)
        _ = state.apply(try event(#"{"sessionUpdate":"tool_call_update","toolCallId":"t","title":"old","content":[{"type":"terminal","terminalId":"t"}]}"#), context: context)
        _ = state.apply(try event(#"{"sessionUpdate":"terminal_update","terminalId":"t","output":{"data":"YQ=="},"_meta":{"keep":true}}"#), context: context)
        let tool = state.toolCall(id: "t"), terminal = state.terminal(id: "t"), order = state.order
        #expect(throws: DecodingError.self) { state.apply(try event(update), context: context) }
        #expect(state.toolCall(id: "t") == tool)
        #expect(state.terminal(id: "t") == terminal)
        #expect(state.terminal(id: "new") == nil)
        #expect(state.order == order)
    }

    private func item(_ value: String) -> LSPJSONValue { .object(["type": .string("_future"), "value": .string(value)]) }

    private func event(_ update: String, sessionID: String = "s") throws -> ACPV2SessionUpdateEnvelope {
        try ACPV2SessionUpdateEnvelope.decode(from: Data("{\"sessionId\":\"\(sessionID)\",\"update\":\(update)}".utf8))
    }
}
