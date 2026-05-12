import Testing
import Foundation
@testable import Alas

struct TerminalTabStateCodableTests {
    @Test func newShapeRoundTripsLeafOnly() throws {
        let state = TerminalTabState(
            id: "tab-1",
            title: "main",
            root: .leaf(PaneLeaf(id: "leaf-1", sessionId: "sess-1", lastCwd: "/tmp")),
            focusedLeafId: "leaf-1"
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TerminalTabState.self, from: data)
        #expect(decoded == state)
    }

    @Test func newShapeRoundTripsNestedTree() throws {
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
        #expect(decoded == state)
    }

    @Test func legacyShapeDecodesIntoSingleLeaf() throws {
        let legacyJSON = #"""
        {"id":"tab-1","title":"main","sessionId":"sess-1"}
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TerminalTabState.self, from: legacyJSON)
        #expect(decoded.id == "tab-1")
        #expect(decoded.title == "main")
        if case .leaf(let l) = decoded.root {
            #expect(l.sessionId == "sess-1")
            #expect(decoded.focusedLeafId == l.id)
            #expect(l.lastCwd == nil)
        } else {
            Issue.record("legacy state should decode to a single leaf")
        }
    }

    @Test func encodingAlwaysIncludesRootAndFocusedLeafId() throws {
        let state = TerminalTabState(
            id: "tab-1",
            title: "main",
            root: .leaf(PaneLeaf(id: "leaf-1", sessionId: "sess-1", lastCwd: nil)),
            focusedLeafId: "leaf-1"
        )
        let data = try JSONEncoder().encode(state)
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(raw.contains("\"root\""))
        #expect(raw.contains("\"focusedLeafId\""))
    }
}
