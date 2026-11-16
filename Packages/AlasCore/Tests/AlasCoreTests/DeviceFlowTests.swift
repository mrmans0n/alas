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
    - launchApp: {appId: "com.other"}
    - tapOn: {id: "a, b", text: "ignored"}
    - tapOn: { point: "10%,20%" }
    - swipe: {direction: RIGHT}
    - inputText: "one\ntwo\t\"three\"\\"
    - eraseText: 2
    - inputText: 'it''s # not a comment' # a comment
    - tapOn: {id: 'c, d'}
    - inputText: "caf\u00e9\x21 \U0001F600\/"
    """#

    @Test func everyCommandOfTheSubsetIsRead() throws {
        let flow = try DeviceFlow.parse(Self.yaml)
        #expect(flow.appID == "com.example.hello")
        #expect(flow.steps == [
            .launchApp(nil), .tapOn(.text("Save")), .tapOn(.id("save_button")), .tapOn(.point(x: 0.5, y: 0.8)),
            .inputText(#"Ada "Lovelace""#), .pressKey(.back), .scroll, .swipe(.left),
            .assertVisible(.text("Done")), .assertNotVisible(.id("spinner")), .openLink("myapp://x#y"), .waitForAnimationToEnd,
            .launchApp("com.other"), .tapOn(.id("a, b")), .tapOn(.point(x: 0.1, y: 0.2)), .swipe(.right),
            .inputText("one\ntwo\t\"three\"\\"), .eraseText(2), .inputText("it's # not a comment"), .tapOn(.id("c, d")),
            .inputText("café! 😀/"),
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
        ("---\n- eraseText: none\n", 2, "eraseText"),
        // Options the subset lacks would change what the step does, so they are refused.
        ("---\n- launchApp:\n    clearState: true\n", 3, "clearState"),
        ("---\n- launchApp: {clearState: true}\n", 2, "clearState"),
        ("---\n- tapOn: {text: Save, index: 2}\n", 2, "index"),
        ("---\n- inputText: \"a\\qb\"\n", 2, "\\q"),
        ("---\n- inputText: \"\\u00g9\"\n", 2, "\\u"),
        ("---\n- inputText: 'open\n", 2, "isn't closed"),
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

    @Test(arguments: [
        (DeviceScreenPoint(x: 0.1, y: 700.0 / 800 + 0.01), "s1e2" as String?), // the button, not the whole-width title
        (DeviceScreenPoint(x: 0.5, y: 0.01), "s1e1"),
        (DeviceScreenPoint(x: 0.5, y: 0.5), nil),
    ])
    func aPointNamesTheSmallestNamedElementUnderIt(point: DeviceScreenPoint, ref: String?) {
        #expect(DeviceFlow.element(at: point, in: Self.snapshot)?.ref == ref)
    }

    @Test(arguments: [
        (DeviceScreenPoint(x: 0.5, y: 0.5), DeviceScreenPoint(x: 0.52, y: 0.51), nil as DeviceFlow.Direction?), // a tap
        (.init(x: 0.5, y: 0.8), .init(x: 0.45, y: 0.3), .up),
        (.init(x: 0.5, y: 0.3), .init(x: 0.5, y: 0.4), .down),
        (.init(x: 0.9, y: 0.5), .init(x: 0.2, y: 0.6), .left),
        (.init(x: 0.2, y: 0.5), .init(x: 0.9, y: 0.45), .right),
    ])
    func aDragIsASwipeAlongItsLongerAxis(from: DeviceScreenPoint, to: DeviceScreenPoint, direction: DeviceFlow.Direction?) {
        #expect(DeviceFlow.swipeDirection(from: from, to: to) == direction)
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
