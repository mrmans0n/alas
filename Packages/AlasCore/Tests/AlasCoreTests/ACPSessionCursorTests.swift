import Foundation
import Testing
import AlasCore

struct ACPSessionCursorTests {
    private static func update(_ json: String) throws -> ACPSessionUpdate {
        try JSONDecoder().decode(ACPSessionUpdate.self, from: Data(json.utf8))
    }

    @Test(arguments: [
        (#"{"type":"user_message","messageId":"u2","position":"before"}"#, #"{"fork":{},"rewind":{}}"#,
         ACPSessionCursor(cursorId: "c", anchor: .init(entity: .userMessage("u2"), position: .before), canRewind: true)),
        (#"{"type":"agent_message","messageId":"a1","position":"after"}"#, #"{"fork":{}}"#,
         ACPSessionCursor(cursorId: "c", anchor: .init(entity: .agentMessage("a1"), position: .after))),
        (#"{"type":"agent_thought","messageId":"t1","position":"after"}"#, #"{"fork":{}}"#,
         ACPSessionCursor(cursorId: "c", anchor: .init(entity: .agentThought("t1"), position: .after))),
        (#"{"type":"tool_call","toolCallId":"tc1","position":"after"}"#, #"{}"#,
         ACPSessionCursor(cursorId: "c", anchor: .init(entity: .toolCall("tc1"), position: .after), canFork: false)),
        (#"{"type":"compaction","compactionId":"k1","position":"after"}"#, #"{"fork":{}}"#,
         ACPSessionCursor(cursorId: "c", anchor: .init(entity: .compaction("k1"), position: .after))),
    ])
    func decodesCursorUpdate(anchor: String, capabilities: String, expected: ACPSessionCursor) throws {
        let decoded = try Self.update(
            #"{"sessionUpdate":"cursor_update","cursorId":"c","capabilities":\#(capabilities),"anchor":\#(anchor)}"#)
        #expect(decoded == .cursorUpdate(expected))
    }

    @Test(arguments: [
        #"{"sessionUpdate":"cursor_update","capabilities":{"fork":{}},"anchor":{"type":"user_message","messageId":"u","position":"before"}}"#,
        #"{"sessionUpdate":"cursor_update","cursorId":"c","anchor":{"type":"turn","turnId":"t","position":"before"}}"#,
        #"{"sessionUpdate":"cursor_update","cursorId":"c","anchor":{"type":"user_message","messageId":"u","position":"inside"}}"#,
        #"{"sessionUpdate":"cursor_update","cursorId":"c","anchor":{"type":"tool_call","messageId":"u","position":"after"}}"#,
        #"{"sessionUpdate":"cursor_update","cursorId":"c"}"#,
    ])
    func cursorItCannotPlaceIsIgnored(json: String) throws {
        #expect(try Self.update(json) == .unknown("cursor_update"))
    }

    @Test(arguments: [
        (#"{"rewound":true}"#, ACPSessionRewindOutcome.rewound),
        (#"{"rewound":false,"reason":"busy"}"#, .refused(.busy)),
        (#"{"rewound":false,"reason":"backgroundWork"}"#, .refused(.backgroundWork)),
        (#"{"rewound":false,"reason":"beforeCompaction"}"#, .refused(.beforeCompaction)),
        (#"{"rewound":false,"reason":"clearedContext"}"#, .refused(.clearedContext)),
        (#"{"rewound":false,"reason":"providerRefused"}"#, .refused(.providerRefused)),
        (#"{"rewound":false,"reason":"persistFailed"}"#, .refused(.persistFailed)),
        (#"{"rewound":false,"reason":"later"}"#, .refused(.other("later"))),
        (#"{"rewound":false}"#, .refused(.other(""))),
    ])
    func decodesRewindOutcome(json: String, expected: ACPSessionRewindOutcome) throws {
        #expect(try JSONDecoder().decode(ACPSessionRewindOutcome.self, from: Data(json.utf8)) == expected)
    }

    // MARK: Which user message a cursor lies before

    private let u1 = UUID(), u2 = UUID(), u3 = UUID()

    private func cursor(_ id: String, _ position: ACPSessionCursor.Position, _ entity: ACPSessionCursor.Entity) -> ACPSessionCursor {
        .init(cursorId: id, anchor: .init(entity: entity, position: position))
    }

    @Test func replayedCursorLiesBeforeItsUserMessage() {
        let rows: [ACPSessionCursorRow] = [
            .user(id: u1, messageId: "m1"), .entity(.agentMessage("a1")),
            .user(id: u2, messageId: "m2"), .entity(.agentMessage("a2")),
        ]
        var cursors = ACPSessionCursors()
        cursors.record(cursor("before:m2", .before, .userMessage("m2")))
        #expect(cursors.cursor(beforeUserRow: u2, in: rows)?.cursorId == "before:m2")
        #expect(cursors.cursor(beforeUserRow: u1, in: rows) == nil)
    }

    @Test func liveCursorLiesBeforeThePromptSentAfterItsAnchor() {
        // A steer inside the next turn is not the prompt the cursor is for.
        let steer = UUID()
        let rows: [ACPSessionCursorRow] = [
            .user(id: u1, messageId: nil), .entity(.toolCall("tc1")), .other,
            .user(id: u2, messageId: nil), .entity(.agentMessage("a2")),
            .user(id: steer, messageId: nil), .entity(.agentMessage("a3")),
        ]
        var cursors = ACPSessionCursors()
        cursors.record(cursor("c2", .after, .toolCall("tc1")))
        #expect(cursors.cursor(beforeUserRow: u2, in: rows)?.cursorId == "c2")
        #expect(cursors.cursor(beforeUserRow: steer, in: rows) == nil)
        #expect(cursors.cursor(beforeUserRow: u1, in: rows) == nil)
    }

    @Test func newerCursorWithTheSameAnchorReplacesTheOneOfATurnThatReportedNothing() {
        let rows: [ACPSessionCursorRow] = [
            .user(id: u1, messageId: nil), .entity(.agentMessage("a1")),
            .user(id: u2, messageId: nil), .other,
            .user(id: u3, messageId: nil), .entity(.agentMessage("a3")),
        ]
        var cursors = ACPSessionCursors()
        cursors.record(cursor("c2", .after, .agentMessage("a1")))
        cursors.record(cursor("c3", .after, .agentMessage("a1")))
        #expect(cursors.cursor(beforeUserRow: u3, in: rows)?.cursorId == "c3")
        #expect(cursors.cursor(beforeUserRow: u2, in: rows) == nil)
    }

    @Test func replayOfALiveCursorReplacesItByID() {
        var cursors = ACPSessionCursors()
        cursors.record(cursor("before:m2", .after, .agentMessage("a1")))
        cursors.record(cursor("before:m2", .before, .userMessage("m2")))
        #expect(cursors.entries.map(\.cursor.anchor.position) == [.before])
    }

    @Test func cursorBoundToARowIgnoresItsAnchor() {
        // A replay over stored rows that never learned the agent's ids.
        let rows: [ACPSessionCursorRow] = [
            .user(id: u1, messageId: nil), .other, .user(id: u2, messageId: nil),
        ]
        var cursors = ACPSessionCursors()
        cursors.record(cursor("before:m2", .before, .userMessage("m2")), userRow: u2)
        #expect(cursors.cursor(beforeUserRow: u2, in: rows)?.cursorId == "before:m2")
    }

    @Test func rewindRemovesTheCursorsAtAndAfterTheCut() {
        let rows: [ACPSessionCursorRow] = [
            .user(id: u1, messageId: "m1"), .entity(.agentMessage("a1")),
            .user(id: u2, messageId: "m2"), .entity(.agentMessage("a2")),
            .user(id: u3, messageId: "m3"),
        ]
        var cursors = ACPSessionCursors()
        cursors.record(cursor("before:m2", .before, .userMessage("m2")))
        cursors.record(cursor("before:m3", .before, .userMessage("m3")))
        cursors.record(cursor("elsewhere", .after, .toolCall("unknown")))
        cursors.removeCursors(atOrAfterRow: 4, in: rows)
        #expect(cursors.entries.map(\.cursor.cursorId) == ["before:m2", "elsewhere"])
    }
}
