import Foundation
import Testing
@testable import Alas

@Suite
struct PaneLeafEncodeTests {
    @Test
    func encodeAlwaysWritesSessionIdEqualToId() throws {
        // Even if a leaf was constructed with a legacy/divergent sessionId,
        // encoding should mirror it back to id.
        let leaf = PaneLeaf(id: "leaf-AAA", sessionId: "legacy-UUID-BBB", lastCwd: nil)
        let data = try JSONEncoder().encode(PaneNode.leaf(leaf))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"sessionId\":\"leaf-AAA\""))
        #expect(json.contains("\"id\":\"leaf-AAA\""))
    }

    @Test
    func decodeNormalizesLegacyDivergentSessionIdToId() throws {
        // Old persisted shape had `sessionId` as a per-launch UUID unrelated
        // to `id`. Decode must normalize sessionId → id so the in-memory leaf
        // satisfies the new invariant before any downstream lookup
        // (registry, TerminalTabView, zmx kill, harness).
        let json = """
        {"kind":"leaf","id":"leaf-AAA","sessionId":"legacy-UUID-BBB","lastCwd":null}
        """
        let data = Data(json.utf8)
        let node = try JSONDecoder().decode(PaneNode.self, from: data)
        guard case .leaf(let leaf) = node else {
            Issue.record("expected leaf node")
            return
        }
        #expect(leaf.id == "leaf-AAA")
        #expect(leaf.sessionId == "leaf-AAA", "legacy sessionId must be normalized to id on decode")
    }
}
