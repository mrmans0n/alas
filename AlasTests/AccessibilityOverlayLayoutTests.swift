import AlasCore
import CoreGraphics
import Testing
@testable import Alas

struct AccessibilityOverlayLayoutTests {
    private func element(
        _ ref: String, label: String?, isControl: Bool, _ x: Double, _ y: Double, _ width: Double, _ height: Double
    ) -> DeviceElement {
        DeviceElement(
            ref: ref, role: "button", label: label, value: nil, id: nil,
            x: x, y: y, width: width, height: height, enabled: true, isControl: isControl
        )
    }

    private func snapshot(width: Double, height: Double, _ elements: [DeviceElement]) -> DeviceSnapshot {
        DeviceSnapshot(generation: 1, screenWidth: width, screenHeight: height, elements: elements)
    }

    @Test(arguments: [
        // A portrait screen in a view half its size.
        (402.0, 874.0, CGSize(width: 201, height: 437)),
        // A landscape screen, as a rotated device describes it, in a landscape view.
        (874.0, 402.0, CGSize(width: 437, height: 201)),
    ])
    func framesScaleFromScreenPointsToTheView(width: Double, height: Double, view: CGSize) {
        let boxes = AccessibilityOverlayLayout.boxes(
            snapshot(width: width, height: height, [element("e1", label: "Save", isControl: true, 20, 100, 100, 44)]), in: view
        )
        #expect(boxes.map(\.rect) == [CGRect(x: 10, y: 50, width: 50, height: 22)])
    }

    @Test func aSnapshotFromTheOtherOrientationDrawsNothing() {
        let boxes = AccessibilityOverlayLayout.boxes(
            snapshot(width: 402, height: 874, [element("e1", label: "Save", isControl: true, 20, 100, 100, 44)]),
            in: CGSize(width: 437, height: 201)
        )
        #expect(boxes.isEmpty)
    }

    @Test(arguments: [
        (nil as String?, true, true),
        ("Save", true, false),
        (nil, false, false),
    ])
    func onlyControlsWithoutALabelAreFlagged(label: String?, isControl: Bool, unlabelled: Bool) {
        let boxes = AccessibilityOverlayLayout.boxes(
            snapshot(width: 402, height: 874, [element("e1", label: label, isControl: isControl, 0, 0, 100, 44)]),
            in: CGSize(width: 402, height: 874)
        )
        #expect(boxes.map(\.unlabelled) == [unlabelled])
    }

    @Test func hoverPicksTheSmallestElementUnderThePointer() {
        let boxes = AccessibilityOverlayLayout.boxes(snapshot(width: 402, height: 874, [
            element("cell", label: "General", isControl: true, 0, 300, 402, 60),
            element("button", label: "Info", isControl: true, 350, 310, 40, 40),
        ]), in: CGSize(width: 402, height: 874))
        #expect(AccessibilityOverlayLayout.hovered(boxes, at: CGPoint(x: 360, y: 320))?.element.ref == "button")
        #expect(AccessibilityOverlayLayout.hovered(boxes, at: CGPoint(x: 100, y: 320))?.element.ref == "cell")
        #expect(AccessibilityOverlayLayout.hovered(boxes, at: CGPoint(x: 100, y: 10)) == nil)
    }
}
