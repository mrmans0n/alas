import Foundation
import Testing
import AlasCore

struct DeviceSnapshotTests {
    /// Shaped like serve-sim's `describeUI` output for an iOS home screen.
    static let json = Data(#"""
    [{"type":"Application","role_description":"application","AXLabel":" ","frame":{"x":0,"y":0,"width":402,"height":874},"enabled":true,
      "children":[
        {"type":"Button","role_description":"button","AXLabel":"Maps","AXValue":"Widget","AXUniqueId":"Maps","enabled":true,
         "frame":{"x":24,"y":88,"width":168,"height":191},"children":[]},
        {"type":"Group","role_description":"group","AXLabel":null,"frame":{"x":0,"y":300,"width":402,"height":400},"enabled":true,
         "children":[
           {"type":"Cell","role_description":"cell","AXLabel":"General","frame":{"x":16,"y":320,"width":370,"height":52},"enabled":true,"children":[]},
           {"type":"SearchField","role_description":"search field","AXLabel":null,"AXValue":null,"frame":{"x":16,"y":800,"width":370,"height":40},"enabled":true,"children":[]}
         ]}
      ]}]
    """#.utf8)

    @Test func keepsLabelledAndInteractiveNodesInOrder() throws {
        let snapshot = try DeviceSnapshot.parse(Self.json, generation: 1)
        #expect(snapshot.screenWidth == 402 && snapshot.screenHeight == 874)
        #expect(snapshot.elements.map(\.role) == ["button", "cell", "search field"])
        #expect(snapshot.elements[0] == DeviceElement(
            ref: "s1e1", role: "button", label: "Maps", value: "Widget", id: "Maps",
            x: 24, y: 88, width: 168, height: 191, enabled: true
        ))
    }

    @Test func refsCarryTheirSnapshot() throws {
        let second = try DeviceSnapshot.parse(Self.json, generation: 2)
        #expect(second.elements.map(\.ref) == ["s2e1", "s2e2", "s2e3"])
        #expect(second.element(ref: "s2e2")?.label == "General")
        #expect(second.element(ref: "s1e2") == nil)
    }

    @Test func centerIsAFractionOfTheScreen() throws {
        let snapshot = try DeviceSnapshot.parse(Self.json, generation: 1)
        let cell = try #require(snapshot.element(ref: "s1e2"))
        #expect(snapshot.center(of: cell) == DeviceScreenPoint(x: 201.0 / 402, y: 346.0 / 874))
    }

    @Test(arguments: [
        (nil, 200, ["s1e1", "s1e2", "s1e3"], false),
        ("GENERAL", 200, ["s1e2"], false),
        ("field", 200, ["s1e3"], false),
        (nil, 2, ["s1e1", "s1e2"], true),
    ] as [(String?, Int, [String], Bool)])
    func queryAndLimitFilter(query: String?, limit: Int, refs: [String], truncated: Bool) throws {
        let snapshot = try DeviceSnapshot.parse(Self.json, generation: 1)
        let filtered = snapshot.filtered(query: query, limit: limit)
        #expect(filtered.elements.map(\.ref) == refs)
        #expect(filtered.truncated == truncated)
    }

    @Test func anEmptyTreeIsAnError() {
        #expect(throws: DeviceSnapshotError.self) { try DeviceSnapshot.parse(Data("[]".utf8), generation: 1) }
    }
}

struct DeviceSnapshotDiffTests {
    /// Elements as (role, label, value, y, enabled); refs number from 1 in the given generation.
    private func snap(_ generation: Int, _ items: [(String, String, String?, Double, Bool)]) -> DeviceSnapshot {
        DeviceSnapshot(
            generation: generation, screenWidth: 402, screenHeight: 874,
            elements: items.enumerated().map { index, item in
                DeviceElement(
                    ref: "s\(generation)e\(index + 1)", role: item.0, label: item.1, value: item.2, id: nil,
                    x: 0, y: item.3, width: 402, height: 44, enabled: item.4
                )
            }
        )
    }

    @Test func aChangedValueKeepsItsRef() {
        let diff = DeviceSnapshotDiff(
            previous: snap(1, [("textfield", "Name", "", 100, true), ("button", "Save", nil, 200, true)]),
            next: snap(2, [("textfield", "Name", "Ada", 100, true), ("button", "Save", nil, 200, true)])
        )
        #expect(!diff.screenChanged)
        #expect(diff.changed == [.init(ref: "s1e1", field: "value", from: "", to: "Ada")])
        #expect(diff.snapshot.elements.map(\.ref) == ["s1e1", "s1e2"])
    }

    @Test func addedAndRemovedElements() {
        let diff = DeviceSnapshotDiff(
            previous: snap(1, [("button", "A", nil, 0, true), ("button", "B", nil, 50, true), ("button", "C", nil, 100, true)]),
            next: snap(2, [("button", "A", nil, 0, true), ("button", "B", nil, 50, true), ("button", "D", nil, 100, true)])
        )
        #expect(diff.added.map(\.ref) == ["s2e3"])
        #expect(diff.removed.map(\.ref) == ["s1e3"])
        #expect(diff.snapshot.elements.map(\.ref) == ["s1e1", "s1e2", "s2e3"])
    }

    @Test func scrollingIsNotAChange() {
        let diff = DeviceSnapshotDiff(
            previous: snap(1, [("cell", "General", nil, 300, true), ("cell", "Privacy", nil, 350, true)]),
            next: snap(2, [("cell", "General", nil, 200, true), ("cell", "Privacy", nil, 250, true)])
        )
        #expect(diff.added.isEmpty && diff.removed.isEmpty && diff.changed.isEmpty)
        #expect(diff.snapshot.elements.map(\.y) == [200, 250])
        #expect(diff.snapshot.elements.map(\.ref) == ["s1e1", "s1e2"])
    }

    @Test func elementsWithTheSameLabelPairInOrder() {
        let diff = DeviceSnapshotDiff(
            previous: snap(1, [("cell", "Row", nil, 0, true), ("cell", "Row", nil, 50, true), ("button", "Edit", nil, 90, true)]),
            next: snap(2, [("cell", "Row", nil, -20, false), ("cell", "Row", nil, 30, true), ("button", "Edit", nil, 90, true)])
        )
        #expect(diff.changed == [.init(ref: "s1e1", field: "enabled", from: "true", to: "false")])
    }

    @Test func aNewScreenOrNoEarlierSnapshotGivesTheWholeScreen() {
        let next = snap(2, [("button", "W", nil, 0, true), ("button", "X", nil, 50, true), ("button", "Y", nil, 100, true)])
        let replaced = DeviceSnapshotDiff(
            previous: snap(1, [("button", "A", nil, 0, true), ("button", "B", nil, 50, true), ("button", "Y", nil, 100, true)]),
            next: next
        )
        #expect(replaced.screenChanged)
        #expect(replaced.snapshot == next)
        #expect(replaced.json()["elements"] as? [[String: Any]] != nil)
        #expect(DeviceSnapshotDiff(previous: nil, next: next).screenChanged)
    }

    @Test func longListsAreTruncated() {
        let many = (0..<250).map { ("button", "B\($0)", String?.none, Double($0), true) }
        let diff = DeviceSnapshotDiff(
            previous: snap(1, many.prefix(250).map { ($0.0, $0.1, $0.2, $0.3, $0.4) }),
            next: snap(2, many + (0..<250).map { ("button", "N\($0)", String?.none, Double($0), true) })
        )
        let json = diff.json()
        #expect((json["added"] as? [Any])?.count == 200)
        #expect(json["truncated"] as? Bool == true)
    }
}
