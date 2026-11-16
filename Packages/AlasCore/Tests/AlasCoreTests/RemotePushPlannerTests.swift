import AlasCore
import Testing

private let k = RemotePushPlanner.Key(originServerId: "srv-a", sessionId: "s1")

struct RemotePushPlannerTests {
    private typealias Key = RemotePushPlanner.Key
    private let key = Key(originServerId: "srv-a", sessionId: "s1")

    @Test func waitsPresentAtStartPushNothing() {
        var planner = RemotePushPlanner(current: [key: "awaitingPermission"])
        #expect(planner.update([key: "awaitingPermission"]).isEmpty)
    }

    @Test(arguments: [
        // A session entering a wait pages once, with the status it entered.
        ("idle", "awaitingPermission", [.attention(k, status: "awaitingPermission")]),
        (nil, "awaitingInput", [.attention(k, status: "awaitingInput")]),
        // A session with no runner reattaching straight into a wait (a restart) is not new.
        ("noRunner", "awaitingPermission", []),
        // Moving from one wait to the other is a new question.
        ("awaitingPermission", "awaitingInput", [.attention(k, status: "awaitingInput")]),
        // Leaving a wait, or disappearing while in one, clears it.
        ("awaitingPermission", "streaming", [.clear(k)]),
        ("awaitingInput", nil, [.clear(k)]),
        // A turn ending, from work or from a wait, finishes; one that never ran, or vanished, does not.
        ("streaming", "idle", [.finished(k)]),
        ("awaitingPermission", "idle", [.clear(k), .finished(k)]),
        ("noRunner", "idle", []),
        ("streaming", nil, []),
        // No change, or starting a turn, does nothing.
        ("awaitingPermission", "awaitingPermission", []),
        ("idle", "streaming", []),
    ] as [(String?, String?, [RemotePushPlanner.Action])])
    func transitions(from: String?, to: String?, expected: [RemotePushPlanner.Action]) {
        var planner = RemotePushPlanner(current: from.map { [key: $0] } ?? [:])
        #expect(planner.update(to.map { [key: $0] } ?? [:]) == expected)
    }

    @Test func baselinedWaitsPushNothingButStillClear() {
        var planner = RemotePushPlanner(current: [:])
        planner.baseline([key: "awaitingInput"])
        #expect(planner.update([key: "awaitingInput"]).isEmpty)
        #expect(planner.update([:]) == [.clear(key)])
    }

    @Test func collapseIdIsShortDeterministicBase64URLPerServer() {
        let a = RemotePushID.collapseId(originServerId: "srv-a", sessionId: "s1")
        #expect(a.count == 32)
        #expect(a.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        #expect(a == RemotePushID.collapseId(originServerId: "srv-a", sessionId: "s1"))
        #expect(a != RemotePushID.collapseId(originServerId: "srv-b", sessionId: "s1"))
    }
}
