import Testing
import Foundation
@testable import Alas

struct TerminalTabStateCodableTests {
    @Test func newShapeRoundTripsLeafOnly() throws {
        // When a leaf with legacy divergent sessionId is encoded, sessionId is mirrored to id.
        // After round-trip, the state will have sessionId == id (the new invariant).
        let state = TerminalTabState(
            id: "tab-1",
            title: "main",
            root: .leaf(PaneLeaf(id: "leaf-1", sessionId: "sess-1", lastCwd: "/tmp")),
            focusedLeafId: "leaf-1"
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TerminalTabState.self, from: data)
        // The decoded state has sessionId mirrored to id
        let expectedState = TerminalTabState(
            id: "tab-1",
            title: "main",
            root: .leaf(PaneLeaf(id: "leaf-1", sessionId: "leaf-1", lastCwd: "/tmp")),
            focusedLeafId: "leaf-1"
        )
        #expect(decoded == expectedState)
    }

    @Test func newShapeRoundTripsNestedTree() throws {
        // When leaves with legacy divergent sessionIds are encoded, sessionId is mirrored to id.
        // After round-trip, each leaf will have sessionId == id (the new invariant).
        let nested: PaneNode = .split(PaneSplit(
            id: "s1", axis: .vertical, fraction: 0.5,
            children: [
                .leaf(PaneLeaf(id: "a", sessionId: "sa", lastCwd: nil)),
                .split(PaneSplit(id: "s2", axis: .horizontal, fraction: 0.3,
                                 children: [
                                    .leaf(PaneLeaf(id: "b", sessionId: "sb", lastCwd: "/home")),
                                    .leaf(PaneLeaf(id: "c", sessionId: "sc", lastCwd: nil)),
                                 ]))
            ]
        ))
        let state = TerminalTabState(id: "tab", title: "t", root: nested, focusedLeafId: "b")
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TerminalTabState.self, from: data)
        // After encoding and decoding, sessionIds are mirrored to their respective ids
        let expectedNested: PaneNode = .split(PaneSplit(
            id: "s1", axis: .vertical, fraction: 0.5,
            children: [
                .leaf(PaneLeaf(id: "a", sessionId: "a", lastCwd: nil)),
                .split(PaneSplit(id: "s2", axis: .horizontal, fraction: 0.3,
                                 children: [
                                    .leaf(PaneLeaf(id: "b", sessionId: "b", lastCwd: "/home")),
                                    .leaf(PaneLeaf(id: "c", sessionId: "c", lastCwd: nil)),
                                 ]))
            ]
        ))
        let expectedState = TerminalTabState(id: "tab", title: "t", root: expectedNested, focusedLeafId: "b")
        #expect(decoded == expectedState)
    }

    @Test func legacyShapeDecodesIntoSingleLeafWithIdEqualToSessionId() throws {
        // Legacy persisted state had only a top-level sessionId. Migration
        // now uses that sessionId as the leaf id so the in-memory leaf
        // already satisfies the "leaf.id == sessionId" invariant.
        let legacyJSON = #"""
        {"id":"tab-1","title":"main","sessionId":"sess-1"}
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TerminalTabState.self, from: legacyJSON)
        #expect(decoded.id == "tab-1")
        #expect(decoded.title == "main")
        if case .leaf(let l) = decoded.root {
            #expect(l.id == "sess-1")
            #expect(l.sessionId == "sess-1")
            #expect(decoded.focusedLeafId == "sess-1")
            #expect(l.lastCwd == nil)
        } else {
            Issue.record("legacy state should decode to a single leaf")
        }
    }

    @Test func convenienceInitUsesSessionIdAsLeafId() {
        // Regression for the bug where fresh terminal tabs had leaf.id != sessionId,
        // causing the registry (keyed by leaf.id post-zmx) to miss on Split/close paths.
        let state = TerminalTabState(id: "tab-1", title: "bash", sessionId: "live-session-UUID")
        guard case .leaf(let leaf) = state.root else {
            Issue.record("convenience init must produce a single leaf")
            return
        }
        #expect(leaf.id == "live-session-UUID")
        #expect(leaf.sessionId == "live-session-UUID")
        #expect(state.focusedLeafId == "live-session-UUID")
    }

    @Test func encodingNeverEmitsTopLevelSessionIdKey() throws {
        let state = TerminalTabState(
            id: "tab-1",
            title: "main",
            root: .leaf(PaneLeaf(id: "leaf-1", sessionId: "sess-1", lastCwd: nil)),
            focusedLeafId: "leaf-1"
        )
        let data = try JSONEncoder().encode(state)
        let parsed = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(parsed["root"] != nil)
        #expect(parsed["focusedLeafId"] != nil)
        #expect(parsed["sessionId"] == nil,
                "Top-level sessionId leaked into the new shape — encode(to:) should never emit it.")
    }

    @Test func decodeWithRootButNoFocusedLeafIdFallsBackToFirstLeaf() throws {
        let json = #"""
        {"id":"t","title":"x","root":{"kind":"leaf","id":"leaf-1","sessionId":"s","lastCwd":null}}
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TerminalTabState.self, from: json)
        #expect(decoded.focusedLeafId == "leaf-1")
    }

    @Test func decodesLegacyPayloadWithoutRunScriptKey() throws {
        let json = #"{"id":"t1","title":"Terminal","sessionId":"s1"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TerminalTabState.self, from: json)
        #expect(decoded.runScriptKey == nil)
    }

    @Test func roundTripsRunScriptKey() throws {
        let state = TerminalTabState(id: "t1", title: "Dev", sessionId: "s1", runScriptKey: "repo:dev.sh")
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TerminalTabState.self, from: data)
        #expect(decoded.runScriptKey == "repo:dev.sh")
        #expect(decoded.runScriptLeafId == "s1")
    }

    @Test func backfillsRunScriptLeafIdForPayloadsPredatingIt() throws {
        // Persisted between runScriptKey's introduction and runScriptLeafId's:
        // has the key but not the leaf id.
        let json = #"""
        {"id":"t1","title":"Dev","root":{"kind":"leaf","id":"leaf-1","sessionId":"leaf-1","lastCwd":null},"focusedLeafId":"leaf-1","runScriptKey":"repo:dev.sh"}
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TerminalTabState.self, from: json)
        #expect(decoded.runScriptKey == "repo:dev.sh")
        #expect(decoded.runScriptLeafId == "leaf-1")
    }
}
