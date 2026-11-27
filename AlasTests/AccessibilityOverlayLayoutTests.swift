import AlasCore
import CoreGraphics
import Foundation
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
        (402.0, 874.0, CGSize(width: 201, height: 437), false, CGRect(x: 10, y: 50, width: 50, height: 22)),
        // A landscape screen, as a rotated device describes it, in a landscape view.
        (874.0, 402.0, CGSize(width: 437, height: 201), true, CGRect(x: 10, y: 50, width: 50, height: 22)),
        // Without a device shape the view is wider than the screen, which sits centered in it.
        (402.0, 874.0, CGSize(width: 1000, height: 874), false, CGRect(x: 319, y: 100, width: 100, height: 44)),
    ])
    func framesFitTheScreenIntoTheViewAsTheVideoDoes(
        width: Double, height: Double, view: CGSize, landscape: Bool, expected: CGRect
    ) {
        let boxes = AccessibilityOverlayLayout.boxes(
            snapshot(width: width, height: height, [element("e1", label: "Save", isControl: true, 20, 100, 100, 44)]),
            in: view, landscape: landscape
        )
        #expect(boxes.map(\.rect) == [expected])
    }

    @Test func aSnapshotFromTheOtherOrientationDrawsNothing() {
        let boxes = AccessibilityOverlayLayout.boxes(
            snapshot(width: 402, height: 874, [element("e1", label: "Save", isControl: true, 20, 100, 100, 44)]),
            in: CGSize(width: 1000, height: 874), landscape: true
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
            in: CGSize(width: 402, height: 874), landscape: false
        )
        #expect(boxes.map(\.unlabelled) == [unlabelled])
    }

    @Test func hoverPicksTheSmallestElementUnderThePointer() {
        let boxes = AccessibilityOverlayLayout.boxes(snapshot(width: 402, height: 874, [
            element("cell", label: "General", isControl: true, 0, 300, 402, 60),
            element("button", label: "Info", isControl: true, 350, 310, 40, 40),
        ]), in: CGSize(width: 402, height: 874), landscape: false)
        #expect(AccessibilityOverlayLayout.hovered(boxes, at: CGPoint(x: 360, y: 320))?.element.ref == "button")
        #expect(AccessibilityOverlayLayout.hovered(boxes, at: CGPoint(x: 100, y: 320))?.element.ref == "cell")
        #expect(AccessibilityOverlayLayout.hovered(boxes, at: CGPoint(x: 100, y: 10)) == nil)
    }

    @Test func selectionClampsToTheFrozenScreenAndRejectsItsLetterbox() {
        let pixels = CGSize(width: 300, height: 600)
        let view = CGSize(width: 500, height: 400)
        #expect(DeviceBugSelection.crop(
            from: CGPoint(x: 280, y: 120), to: CGPoint(x: 400, y: 450), pixels: pixels, view: view
        ) == CGRect(x: 195, y: 180, width: 105, height: 420))
        #expect(DeviceBugSelection.crop(
            from: CGPoint(x: 100, y: 120), to: CGPoint(x: 200, y: 240), pixels: pixels, view: view
        ) == nil)
    }

    @Test func selectionDescribesAClippedControlButNotTwoPlausibleTargets() {
        let size = CGSize(width: 200, height: 400)
        let crop = CGRect(x: 0, y: 0, width: 100, height: 60)
        let clipped = element("clipped", label: "Save", isControl: true, -50, 15, 100, 30)
        let second = element("second", label: "Cancel", isControl: true, 55, 15, 30, 30)
        #expect(DeviceBugSelection.target(
            in: crop, pixels: size, snapshot: snapshot(width: 200, height: 400, [clipped])
        )?.ref == "clipped")
        #expect(DeviceBugSelection.target(
            in: crop, pixels: size, snapshot: snapshot(width: 200, height: 400, [clipped, second])
        ) == nil)
        #expect(DeviceBugSelection.target(
            in: crop, pixels: size, snapshot: snapshot(width: 400, height: 200, [clipped])
        ) == nil)
    }
}

/// The overlay's reads of the accessibility tree.
@MainActor // AccessibilityOverlayReader is main-actor isolated, like the view that owns it.
struct AccessibilityOverlayReaderTests {
    /// Replies to `describe` only when the test says so, in any order.
    @MainActor
    final class Replies {
        var pending: [CheckedContinuation<Data, Error>] = []

        func describe() async throws -> Data {
            try await withCheckedThrowingContinuation { pending.append($0) }
        }

        static func screen(label: String) -> Data {
            Data(#"""
            [{"type":"Application","frame":{"x":0,"y":0,"width":402,"height":874},
              "children":[{"type":"Button","AXLabel":"\#(label)","frame":{"x":0,"y":0,"width":100,"height":44}}]}]
            """#.utf8)
        }
    }

    @Test func aSupersededReadThatAnswersLastIsDropped() async throws {
        let replies = Replies()
        let reader = AccessibilityOverlayReader { try await replies.describe() }
        async let older: Void = reader.read()
        try await eventually("first read asked") { replies.pending.count == 1 }
        async let newer: Void = reader.read()
        try await eventually("second read asked") { replies.pending.count == 2 }
        replies.pending[1].resume(returning: Replies.screen(label: "New"))
        await newer
        replies.pending[0].resume(returning: Replies.screen(label: "Old"))
        await older
        #expect(reader.snapshot?.elements.map(\.label) == ["New"])
        #expect(!reader.reading)
    }
}
