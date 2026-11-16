import Foundation
import Testing
import AlasCore

struct DeviceFlowTests {
    static let yaml = #"""
    appId: com.example.hello
    # Signs in, then checks the greeting.
    ---
    - launchApp
    - tapOn: "Save"
    - tapOn:
        id: "save_button"
    - tapOn:
        point: "50%,80%"
    - inputText: "Ada \"Lovelace\""
    - pressKey: Back
    - scroll
    - swipe:
        direction: LEFT
    - assertVisible: Done   # trailing comment
    - assertNotVisible:
        id: spinner
    - openLink: "myapp://x#y"
    - waitForAnimationToEnd
    """#

    @Test func everyCommandOfTheSubsetIsRead() throws {
        let flow = try DeviceFlow.parse(Self.yaml)
        #expect(flow.appID == "com.example.hello")
        #expect(flow.steps == [
            .launchApp(nil), .tapOn(.text("Save")), .tapOn(.id("save_button")), .tapOn(.point(x: 0.5, y: 0.8)),
            .inputText(#"Ada "Lovelace""#), .pressKey(.back), .scroll, .swipe(.left),
            .assertVisible(.text("Done")), .assertNotVisible(.id("spinner")), .openLink("myapp://x#y"), .waitForAnimationToEnd,
        ])
        #expect(flow.lines.prefix(3) == [4, 5, 6])
    }

    @Test func whatItWritesReadsBackTheSame() throws {
        let flow = try DeviceFlow.parse(Self.yaml)
        let again = try DeviceFlow.parse(flow.yaml)
        #expect(again.steps == flow.steps)
        #expect(again.appID == flow.appID)
    }

    @Test(arguments: [
        ("---\n- launchApp\n- runFlow: other.yaml\n", 3, "runFlow"),
        ("---\n- tapOn:\n    point: \"half\"\n", 3, "point"),
        ("---\n- swipe:\n    direction: SIDEWAYS\n", 2, "SIDEWAYS"),
    ])
    func whatTheSubsetLacksIsRefusedByLine(yaml: String, line: Int, mentions: String) {
        #expect {
            try DeviceFlow.parse(yaml)
        } throws: { error in
            guard let error = error as? DeviceFlowError else { return false }
            return error.line == line && error.message.contains(mentions)
        }
    }

    private static let snapshot = DeviceSnapshot(generation: 1, screenWidth: 400, screenHeight: 800, elements: [
        DeviceElement(ref: "s1e1", role: "text", label: "Save", value: nil, id: nil, x: 0, y: 0, width: 400, height: 40, enabled: true),
        DeviceElement(
            ref: "s1e2", role: "button", label: "save", value: nil, id: nil, x: 0, y: 700, width: 200, height: 44,
            enabled: true, isControl: true
        ),
        DeviceElement(
            ref: "s1e3", role: "button", label: "Save changes", value: nil, id: "save_button", x: 200, y: 700, width: 200,
            height: 44, enabled: true, isControl: true
        ),
    ])

    @Test(arguments: [
        (DeviceFlow.Selector.text("Save"), "s1e2" as String?), // an exact control beats an exact non-control
        (.text("CHANGES"), "s1e3"), // then contains
        (.id("save_button"), "s1e3"),
        (.text("Delete"), nil),
    ])
    func selectorsFindTheirElement(selector: DeviceFlow.Selector, ref: String?) {
        #expect(DeviceFlow.find(selector, in: Self.snapshot)?.ref == ref)
    }

    @Test func theRecorderNamesByLabelThenIDThenPoint() {
        let labelled = Self.snapshot.elements[1]
        let idOnly = DeviceElement(ref: "e", role: "button", label: nil, value: nil, id: "go", x: 0, y: 0, width: 1, height: 1, enabled: true)
        let at = DeviceScreenPoint(x: 0.503, y: 0.8)
        #expect(DeviceFlow.selector(for: labelled, at: at) == .text("save"))
        #expect(DeviceFlow.selector(for: idOnly, at: at) == .id("go"))
        #expect(DeviceFlow.selector(for: nil, at: at) == .point(x: 0.5, y: 0.8))
    }
}
