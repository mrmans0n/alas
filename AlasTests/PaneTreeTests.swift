import Testing
import Foundation
@testable import Alas

struct PaneTreeTests {
    private func leaf(_ id: String, session: String = "s") -> PaneNode {
        .leaf(PaneLeaf(id: id, sessionId: session, lastCwd: nil))
    }

    private func split(_ id: String, _ axis: SplitAxis, _ fraction: Double, _ children: [PaneNode]) -> PaneNode {
        .split(PaneSplit(id: id, axis: axis, fraction: fraction, children: children))
    }

    @Test func firstLeafReturnsLeftmostLeaf() {
        let tree = split("s1", .vertical, 0.5, [
            split("s2", .horizontal, 0.5, [leaf("a"), leaf("b")]),
            leaf("c"),
        ])
        #expect(tree.firstLeaf().id == "a")
    }

    @Test func leavesEnumeratesInRenderOrder() {
        let tree = split("s1", .vertical, 0.5, [
            split("s2", .horizontal, 0.5, [leaf("a"), leaf("b")]),
            split("s3", .horizontal, 0.5, [leaf("c"), leaf("d")]),
        ])
        #expect(tree.leaves().map(\.id) == ["a", "b", "c", "d"])
    }

    @Test func decodingSplitWithEmptyChildrenThrows() {
        let json = """
        {
          "kind": "split",
          "id": "s1",
          "axis": "vertical",
          "fraction": 0.5,
          "children": []
        }
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PaneNode.self, from: Data(json.utf8))
        }
    }

    @Test func decodingValidSplitPreservesChildren() throws {
        let json = """
        {
          "kind": "split",
          "id": "s1",
          "axis": "vertical",
          "fraction": 0.5,
          "children": [
            { "kind": "leaf", "id": "a", "sessionId": "sa" },
            { "kind": "leaf", "id": "b", "sessionId": "sb" }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(PaneNode.self, from: Data(json.utf8))
        #expect(decoded.leaves().map(\.id) == ["a", "b"])
        #expect(decoded.firstLeaf().id == "a")
    }

    @Test func findReturnsLeafAndPath() throws {
        let tree = split("s1", .vertical, 0.5, [
            leaf("a"),
            split("s2", .horizontal, 0.5, [leaf("b"), leaf("c")]),
        ])
        let result = try #require(tree.find(leafId: "c"))
        #expect(result.leaf.id == "c")
        #expect(result.path == ["s1", "s2"])
    }

    @Test func findReturnsNilForMissingLeaf() {
        let tree: PaneNode = .leaf(PaneLeaf(id: "a", sessionId: "s", lastCwd: nil))
        #expect(tree.find(leafId: "missing") == nil)
    }

    @Test func replacingLeafSwapsTheTargetedLeaf() {
        let tree = split("s1", .vertical, 0.5, [leaf("a"), leaf("b")])
        let replacement = split("new-split", .horizontal, 0.5, [leaf("b"), leaf("c")])
        let result = tree.replacingLeaf(id: "b", with: replacement)
        guard case .split(let root) = result,
              case .leaf(let l0) = root.children[0],
              case .split(let inner) = root.children[1] else {
            Issue.record("expected split with leaf + split")
            return
        }
        #expect(l0.id == "a")
        #expect(inner.id == "new-split")
    }

    @Test func removingLeafCollapsesSingleChildSplit() throws {
        let tree = split("s1", .vertical, 0.5, [leaf("a"), leaf("b")])
        let result = try #require(tree.removingLeaf(id: "b"))
        if case .leaf(let only) = result {
            #expect(only.id == "a")
        } else {
            Issue.record("expected collapse to leaf 'a'")
        }
    }

    @Test func removingLeafReturnsNilWhenRemovingLastLeaf() {
        let tree: PaneNode = .leaf(PaneLeaf(id: "a", sessionId: "s", lastCwd: nil))
        #expect(tree.removingLeaf(id: "a") == nil)
    }

    @Test func removingLeafFromNestedSplitCollapsesUpwards() throws {
        let tree = split("s1", .vertical, 0.5, [
            leaf("a"),
            split("s2", .horizontal, 0.5, [leaf("b"), leaf("c")]),
        ])
        let result = try #require(tree.removingLeaf(id: "c"))
        if case .split(let root) = result,
           case .leaf(let l0) = root.children[0],
           case .leaf(let l1) = root.children[1] {
            #expect(l0.id == "a")
            #expect(l1.id == "b")
        } else {
            Issue.record("expected split[leaf a, leaf b]")
        }
    }
}
