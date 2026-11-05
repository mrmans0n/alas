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
