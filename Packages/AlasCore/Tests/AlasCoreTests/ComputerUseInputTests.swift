import CoreGraphics
import Foundation
import Testing
@testable import AlasPlatform

struct ComputerUseInputTests {
    private typealias Chord = ComputerUseKeyChord

    @Test(arguments: [
        ("cmd+shift+s", Chord(modifiers: [.command, .shift], key: .character("s"))),
        ("Return", Chord(modifiers: [], key: .named(.return))),
        ("ctrl+alt+delete", Chord(modifiers: [.control, .option], key: .named(.delete))),
        ("f5", Chord(modifiers: [], key: .named(.f5))),
        ("⌘+S", Chord(modifiers: [.command], key: .character("s"))),
        ("fn+esc", Chord(modifiers: [.function], key: .named(.escape))),
        ("opt+pgdn", Chord(modifiers: [.option], key: .named(.pageDown))),
        ("cmd+4", Chord(modifiers: [.command], key: .character("4"))),
    ])
    private func parsesChords(text: String, expected: Chord) {
        #expect(Chord.parse(text) == expected)
    }

    @Test(arguments: ["⌘⇧4", "cmd+", "++", "cmd+cmd+s", "shift", "cmd+ab", "", "cmd+s+t", "cmd+ +s"])
    private func rejectsMalformedChords(text: String) {
        #expect(Chord.parse(text) == nil)
    }

    @Test func pointsMapThroughTheScreenshotFrameAndAreBoundedByTheCurrentFrame() {
        let frame = CGRect(x: 100, y: 50, width: 800, height: 600)
        let pixel = CGPoint(x: 200, y: 100)
        #expect(ComputerUseInputGeometry.globalPoint(
            pixel: pixel, screenshotFrame: frame, scale: 2, currentFrame: frame
        ) == CGPoint(x: 200, y: 100))
        #expect(ComputerUseInputGeometry.globalPoint(
            pixel: pixel, screenshotFrame: frame, scale: 2,
            currentFrame: CGRect(x: 900, y: 50, width: 800, height: 600)
        ) == nil)
        #expect(ComputerUseInputGeometry.globalPoint(
            pixel: CGPoint(x: 1700, y: 100), screenshotFrame: frame, scale: 2, currentFrame: frame
        ) == nil)
    }

    @Test func interpolationEndsAtTheTarget() {
        let points = ComputerUseInputGeometry.interpolate(from: .zero, to: CGPoint(x: 10, y: 20), steps: 4)
        #expect(points == [CGPoint(x: 2.5, y: 5), CGPoint(x: 5, y: 10), CGPoint(x: 7.5, y: 15), CGPoint(x: 10, y: 20)])
        #expect(ComputerUseInputGeometry.interpolate(from: .zero, to: CGPoint(x: 1, y: 1), steps: 0) == [CGPoint(x: 1, y: 1)])
        #expect(ComputerUseInputGeometry.center(of: CGRect(x: 10, y: 20, width: 100, height: 40)) == CGPoint(x: 60, y: 40))
    }

    @Test(arguments: [
        (true, 0.5, true, 0.0, ComputerUseTakeover.Decision.refuse),
        (true, 5.0, true, 0.0, .proceed),
        (true, 0.5, false, 3.0, .wait),
        (true, 0.5, false, 10.0, .refuse),
        (false, 0.5, false, 0.0, .proceed),
        (true, 2.0, false, 0.0, .proceed),
    ])
    private func takeoverDecisions(
        frontmost: Bool, idle: TimeInterval, direct: Bool, waited: TimeInterval,
        expected: ComputerUseTakeover.Decision
    ) {
        #expect(ComputerUseTakeover.decide(
            targetIsFrontmost: frontmost, idleSeconds: idle, direct: direct, waited: waited
        ) == expected)
    }
}
