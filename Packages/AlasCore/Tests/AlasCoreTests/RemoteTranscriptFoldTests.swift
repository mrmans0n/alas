import Foundation
import Testing
import AlasCore

/// Wire indices start mid-history (a paged window) throughout, so the fold
/// is pinned to positions in `messages`, not to the wire `index`.
struct RemoteTranscriptFoldTests {
    private static let firstIndex = 90

    private func row(_ id: String, _ kind: String, _ position: Int, phase: String? = nil,
                     createdAt: Int64? = nil) -> RemoteWireMessage {
        .init(stableId: id, kind: kind, text: id, json: nil, index: Self.firstIndex + position,
              phase: phase, createdAt: createdAt)
    }

    private func tool(_ id: String, _ position: Int, kind: String? = nil,
                      fold: RemoteWireMessage.Fold?) throws -> RemoteWireMessage {
        let call = ACPToolCall(toolCallId: id, title: id, kind: kind, status: "completed")
        let json = String(decoding: try JSONEncoder().encode(call), as: UTF8.self)
        return .init(stableId: id, kind: "toolCall", text: nil, json: json, index: Self.firstIndex + position,
                     fold: fold)
    }

    private func read(_ id: String, _ position: Int) throws -> RemoteWireMessage {
        try tool(id, position, fold: .init(joins: true, verb: "read"))
    }

    private func fold(_ messages: [RemoteWireMessage], isTurnActive: Bool = false) -> [ACPTranscriptRenderRow] {
        RemoteTranscriptFold.renderRows(
            messages: messages, isTurnActive: isTurnActive, isExpanded: { _ in false }, memberLimit: { _ in nil }
        )
    }

    private func collapsedGroup(_ row: ACPTranscriptRenderRow) -> ACPTranscriptToolCallGroup? {
        if case .toolCallGroup(let group) = row { group } else { nil }
    }

    private func label(_ group: ACPTranscriptToolCallGroup, in messages: [RemoteWireMessage]) -> String {
        ACPToolCallGroupSummary(
            toolCalls: RemoteTranscriptFold.summaryToolCalls(of: group, in: messages),
            kind: group.kind, isLive: group.isLive
        ).label
    }

    private func finishedTurn(userAt: Int64? = nil, agentAt: Int64? = nil) throws -> [RemoteWireMessage] {
        [
            row("u", "user", 0, createdAt: userAt),
            try read("r1", 1),
            try read("r2", 2),
            try tool("x", 3, fold: .init(joins: true, verb: "run")),
            row("a", "agent", 4, createdAt: agentAt),
        ]
    }

    @Test func readsAndRunsFoldIntoOneGroup() throws {
        let messages = try finishedTurn()
        let rows = fold(messages)

        #expect(rows.map(\.id) == ["u", "tcg-r1", "a"])
        let group = try #require(collapsedGroup(rows[1]))
        #expect(group.members.map(\.index) == [1, 2, 3])
        #expect(RemoteTranscriptFold.summaryToolCalls(of: group, items: messages.map(RemoteTranscriptFold.item(for:)))
            == RemoteTranscriptFold.summaryToolCalls(of: group, in: messages))
        #expect(group.kind == .completedTurn(duration: nil))
        #expect(label(group, in: messages) == "Worked · read 2 files, ran 1 command")
    }

    @Test func durationComesFromWireTimes() throws {
        let messages = try finishedTurn(userAt: 0, agentAt: 125_000)
        let rows = fold(messages)

        let group = try #require(collapsedGroup(rows[1]))
        #expect(label(group, in: messages).hasPrefix("Worked for 2m 5s"))
    }

    @Test func hiddenRowNeitherSplitsNorCounts() throws {
        let marker = RemoteWireMessage(stableId: "h", kind: "toolCall", text: nil, json: nil,
                                       index: Self.firstIndex + 1, isHidden: true)
        let messages = [try read("r1", 0), marker, try read("r2", 2), row("a", "agent", 3)]
        let rows = fold(messages, isTurnActive: true)

        #expect(rows.map(\.id) == ["tcg-r1", "a"])
        let group = try #require(collapsedGroup(rows[0]))
        #expect(group.members.map(\.stableId) == ["r1", "r2"])
    }

    @Test func nonJoiningCallBreaksTheRun() throws {
        let messages = [
            try read("r1", 0), try read("r2", 1),
            try tool("c", 2, fold: .init(joins: false, verb: "other")),
            try read("r3", 3), try read("r4", 4),
        ]

        #expect(fold(messages).map(\.id) == ["tcg-r1", "c", "tcg-r3"])
    }

    @Test(arguments: [
        ("execute", ACPToolCallGroupSummary.Verb.run),
        ("read", .read),
        ("fetch", .search),
        ("think", .other),
    ])
    func olderMacFallsBackToKind(kind: String, expectedVerb: ACPToolCallGroupSummary.Verb) throws {
        let message = try tool("t", 0, kind: kind, fold: nil)

        #expect(RemoteTranscriptFold.item(for: message)
            == .toolCall(.init(status: "completed", joins: true, verb: expectedVerb)))
    }

    @Test(arguments: ["toolCall", "hidden", "commentary"])
    func itemFromDecodedRowMatchesItemFromMessage(_ variant: String) throws {
        var message = variant == "commentary" ? row("c", "agent", 0, phase: "commentary")
            : try tool("t", 0, kind: "read", fold: nil)
        message.isHidden = variant == "hidden" ? true : nil

        #expect(RemoteTranscriptFold.item(for: message, row: RemoteTranscriptRow(message: message))
            == RemoteTranscriptFold.item(for: message))
    }

    @Test func commentaryIsNotTheAnswer() throws {
        let messages = [
            row("u", "user", 0),
            row("c", "agent", 1, phase: "commentary"),
            try read("r", 2),
            row("a", "agent", 3),
        ]
        let rows = fold(messages)

        #expect(rows.map(\.id) == ["u", "tcg-c", "a"])
        let group = try #require(collapsedGroup(rows[1]))
        #expect(group.members.map(\.stableId) == ["c", "r"])
        #expect(group.kind == .completedTurn(duration: nil))
    }

    @Test(arguments: [
        ("data:image/png;base64,iVBORw0KGgo=",
         RemoteTranscriptImageSource.inline(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))),
        ("/tmp/a.png", .host(path: "/tmp/a.png")),
        ("file:///tmp/a.png", .host(path: "/tmp/a.png")),
        ("shots/a.png", .host(path: "shots/a.png")),
        ("https://example.com/a.png", .unavailable),
        ("", .unavailable),
    ])
    func imageSourcesResolveLikeTheMac(source: String, expected: RemoteTranscriptImageSource) {
        #expect(RemoteTranscriptImageSource.resolve(source: source) == expected)
    }

    @Test func assetPrefersInlineData() {
        let both = ACPToolCallAsset.image(data: "iVBORw0KGgo=", uri: "/tmp/a.png", name: nil)
        #expect(RemoteTranscriptImageSource.resolve(asset: both)
            == .inline(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])))
        #expect(RemoteTranscriptImageSource.resolve(asset: ACPToolCallAsset(kind: .image)) == .unavailable)
    }

    /// `u` user, `a` agent, `o` anything else, `e<path>` a file write and `t<paths>` a tool call's patches,
    /// each adding and removing one line per path.
    @Test(arguments: [
        ("u ea eb ea a", 4, false, "a+2-2 b+1-1"),
        ("u ea eb ea a", 4, true, nil),
        ("u ea eb a u o", 3, true, "a+1-1 b+1-1"),
        ("u ea eb a o a", 3, false, nil),
        ("u ea o a", 3, false, nil),
        ("ea u eb ec a", 4, false, "b+1-1 c+1-1"),
        ("eb ec a", 2, false, nil),
        ("u tab a", 2, false, "a+1-1 b+1-1"),
        ("u ea ta eb a", 4, false, "a+1-1 b+1-1"),
    ] as [(String, Int, Bool, String?)])
    func turnChangesSumTheEditsOfAFinishedTurnUnderItsAnswer(
        transcript: String, answer: Int, isTurnActive: Bool, expected: String?
    ) {
        let items: [ACPTurnChanges.Item] = transcript.split(separator: " ").map { token in
            switch token {
            case "u": .user
            case "a": .agent
            case "o": .other
            default:
                token.first == "t"
                    ? .toolCallEdits(token.dropFirst().map { .init(path: String($0), added: 1, removed: 1) })
                    : .fileEdit(.init(path: String(token.dropFirst()), added: 1, removed: 1))
            }
        }
        let changes = ACPTurnChanges.forAnswer(at: answer, count: items.count, isTurnActive: isTurnActive) { items[$0] }
        #expect(changes?.files.map { "\($0.path)+\($0.added)-\($0.removed)" }.joined(separator: " ") == expected)
    }
}
