import CoreGraphics
import Foundation
import Testing
@testable import AlasPlatform

struct ComputerUseInputTests {
    private typealias Chord = ComputerUseKeyChord
    private typealias Window = ComputerUseInputGeometry.ScreenWindow

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

    /// Chords that can change the focused field's text get the secure-field check that typing gets.
    @Test(arguments: [
        ("a", true), ("shift+a", true), ("space", true), ("cmd+v", true), ("5", true),
        ("opt+e", true), ("shift+opt+a", true), ("delete", true), ("opt+delete", true), ("forwardDelete", true),
        ("cmd+delete", true), ("ctrl+y", true), ("ctrl+k", true),
        ("cmd+a", false), ("cmd+shift+v", false), ("return", false), ("tab", false), ("ctrl+tab", false),
    ])
    private func chordsThatMayEditText(text: String, edits: Bool) throws {
        #expect(try #require(Chord.parse(text)).mayEditText == edits)
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

    /// A drop lands in the frontmost window over the point, which may not be the one aimed at.
    @Test(arguments: [
        (CGPoint(x: 50, y: 50), 1),
        (CGPoint(x: 150, y: 150), 2),
        (CGPoint(x: 500, y: 500), nil),
    ] as [(CGPoint, UInt32?)])
    func dropPointsHitTheFrontmostWindow(point: CGPoint, expected: UInt32?) {
        // Front to back: window 1 overlaps window 2's top-left corner.
        let windows = [
            Window(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            Window(id: 2, frame: CGRect(x: 50, y: 50, width: 200, height: 200)),
        ]
        #expect(ComputerUseInputGeometry.topmostWindow(at: point, in: windows) == expected)
    }

    /// Pointer input lands on the part of the element its scroll area shows. A retry click needs
    /// the element's own centre in view; a drag takes any visible part, and nothing when none shows
    /// (a name cell scrolled under the sidebar).
    @Test(arguments: [
        // Fully shown.
        (CGRect(x: 10, y: 10, width: 100, height: 20), true, CGPoint(x: 60, y: 20)),
        // A wide row cut off on the right: the centre of what shows.
        (CGRect(x: 0, y: 10, width: 400, height: 20), true, CGPoint(x: 150, y: 20)),
        // Scrolled below the area.
        (CGRect(x: 10, y: 250, width: 100, height: 20), true, nil),
        // Mostly scrolled off the left: the retry skips it, a drag uses what shows.
        (CGRect(x: -150, y: 10, width: 200, height: 20), true, nil),
        (CGRect(x: -150, y: 10, width: 200, height: 20), false, CGPoint(x: 25, y: 20)),
        // Entirely under the area's left edge.
        (CGRect(x: -100, y: 10, width: 80, height: 20), false, nil),
    ] as [(CGRect, Bool, CGPoint?)])
    func pointerInputLandsOnTheVisiblePart(frame: CGRect, requireOwnCenter: Bool, expected: CGPoint?) {
        let window = CGRect(x: -200, y: 0, width: 700, height: 400)
        let scrollArea = CGRect(x: 0, y: 0, width: 300, height: 200)
        #expect(ComputerUseInputGeometry.visibleCenter(
            of: frame, clippedTo: [window, scrollArea], requireOwnCenter: requireOwnCenter) == expected)
    }

    /// Both of a drag's points must be on the window it uses there; the start is reported first.
    /// A window above the normal layer that shows (a floating panel, a banner, the Dock, the
    /// dragging app's own panel) takes the press or drop too; from the dragging layer up
    /// (drag images, the software cursor, display shields) nothing does.
    @Test(arguments: [
        (CGPoint(x: 20, y: 20), CGPoint(x: 220, y: 220), nil),
        (CGPoint(x: 20, y: 20), CGPoint(x: 120, y: 120), ComputerUseInputGeometry.DragPoint.end),
        (CGPoint(x: 160, y: 160), CGPoint(x: 120, y: 120), .start),
        // Another app's floating panel over the drop.
        (CGPoint(x: 20, y: 20), CGPoint(x: 260, y: 260), .end),
        // The dragging app's own floating panel over the start.
        (CGPoint(x: 10, y: 10), CGPoint(x: 220, y: 220), .start),
        // A transparent overlay, a drag image and the software cursor take nothing.
        (CGPoint(x: 20, y: 20), CGPoint(x: 290, y: 110), nil),
        (CGPoint(x: 20, y: 20), CGPoint(x: 110, y: 290), nil),
        (CGPoint(x: 20, y: 20), CGPoint(x: 290, y: 150), nil),
    ] as [(CGPoint, CGPoint, ComputerUseInputGeometry.DragPoint?)])
    func coveredDragPoints(start: CGPoint, end: CGPoint, expected: ComputerUseInputGeometry.DragPoint?) {
        // Front to back: the software cursor 4, the dragging app's (pid 42) floating panel 5 and
        // drag image 6, another app's transparent overlay 7 and floating panel 8, its window 9 over
        // the middle, start window 1, drop window 2.
        let windows = [
            Window(id: 4, pid: 0, layer: 2_147_483_630, frame: CGRect(x: 280, y: 140, width: 20, height: 20)),
            Window(id: 5, pid: 42, layer: 3, frame: CGRect(x: 0, y: 0, width: 15, height: 15)),
            Window(id: 6, pid: 42, layer: 500, frame: CGRect(x: 100, y: 280, width: 20, height: 20)),
            Window(id: 7, pid: 7, layer: 25, alpha: 0, frame: CGRect(x: 280, y: 100, width: 20, height: 20)),
            Window(id: 8, pid: 7, layer: 3, frame: CGRect(x: 250, y: 250, width: 30, height: 30)),
            Window(id: 9, pid: 7, frame: CGRect(x: 100, y: 100, width: 80, height: 80)),
            Window(id: 1, pid: 42, frame: CGRect(x: 0, y: 0, width: 200, height: 200)),
            Window(id: 2, pid: 42, frame: CGRect(x: 100, y: 100, width: 200, height: 200)),
        ]
        #expect(ComputerUseInputGeometry.coveredDragPoint(
            start: start, in: 1, end: end, in: 2, windows: windows) == expected)
    }

    @Test(arguments: [
        (CGRect(x: 10, y: 10, width: 100, height: 100), false),
        (CGRect(x: 12, y: 8, width: 101, height: 100), false),
        (CGRect(x: 13, y: 10, width: 100, height: 100), true),
        (CGRect(x: 10, y: 10, width: 100, height: 97), true),
    ])
    func dragsThatMoveTheWindow(after: CGRect, moved: Bool) {
        #expect(ComputerUseInputGeometry.windowMoved(from: CGRect(x: 10, y: 10, width: 100, height: 100), to: after) == moved)
    }

    @Test func interpolationEndsAtTheTarget() {
        let points = ComputerUseInputGeometry.interpolate(from: .zero, to: CGPoint(x: 10, y: 20), steps: 4)
        #expect(points == [CGPoint(x: 2.5, y: 5), CGPoint(x: 5, y: 10), CGPoint(x: 7.5, y: 15), CGPoint(x: 10, y: 20)])
        #expect(ComputerUseInputGeometry.interpolate(from: .zero, to: CGPoint(x: 1, y: 1), steps: 0) == [CGPoint(x: 1, y: 1)])
        #expect(ComputerUseInputGeometry.center(of: CGRect(x: 10, y: 20, width: 100, height: 40)) == CGPoint(x: 60, y: 40))
    }

    @Test(arguments: [
        (true, 0.5, true, 0.0, ComputerUseTakeover.Decision.wait),
        (true, 5.0, true, 0.0, .proceed),
        (true, 0.5, false, 3.0, .wait),
        (true, 0.5, false, 10.0, .refuse),
        (false, 0.5, false, 0.0, .proceed),
        (true, 2.0, false, 0.0, .proceed),
        // Direct waits for the user wherever they are, then gives up.
        (false, 0.5, true, 3.0, .wait),
        (false, 0.5, true, 10.0, .refuse),
    ])
    private func takeoverDecisions(
        frontmost: Bool, idle: TimeInterval, direct: Bool, waited: TimeInterval,
        expected: ComputerUseTakeover.Decision
    ) {
        #expect(ComputerUseTakeover.decide(
            targetIsFrontmost: frontmost, idleSeconds: idle, direct: direct, waited: waited
        ) == expected)
    }

    /// The monitor's last user event decides; Alas's own posts reset only the HID idle time.
    @Test(arguments: [
        // Alas just posted (HID idle 0), the user's last input was 5 s ago: idle.
        (100.0, 95.0, 0.0, nil, 5.0, ComputerUseTakeover.Decision.proceed),
        // The user typed 0.5 s ago, in the target app.
        (100.0, 99.5, 0.0, nil, 0.5, .wait),
        // No monitor: the HID idle time is all there is.
        (100.0, nil, 0.3, nil, 0.3, .wait),
        (100.0, nil, 4.0, nil, 4.0, .proceed),
        // Secure Event Input hides the keys from the monitor: the user typing a password is active.
        (100.0, 95.0, 0.0, 0.4, 0.4, .wait),
    ] as [(TimeInterval, TimeInterval?, TimeInterval, TimeInterval?, TimeInterval, ComputerUseTakeover.Decision)])
    private func idleComesFromTheUsersOwnInput(
        now: TimeInterval, lastUserInput: TimeInterval?, hidIdle: TimeInterval, secureInputKeyIdle: TimeInterval?,
        idle: TimeInterval, decision: ComputerUseTakeover.Decision
    ) {
        let seconds = ComputerUseTakeover.userIdleSeconds(
            now: now, lastUserInput: lastUserInput, hidIdle: hidIdle, secureInputKeyIdle: secureInputKeyIdle)
        #expect(seconds == idle)
        #expect(ComputerUseTakeover.decide(targetIsFrontmost: true, idleSeconds: seconds, direct: false, waited: 0) == decision)
    }

    /// A drag ends on any input of the user's since it began; without the input monitor there is
    /// no telling theirs from the drag's own, so that ends it too.
    @Test(arguments: [(nil, true), (99.0, false), (101.0, true)] as [(TimeInterval?, Bool)])
    private func dragTakeover(lastUserInput: TimeInterval?, tookOver: Bool) {
        #expect(ComputerUseTakeover.tookOverDrag(lastUserInput: lastUserInput, dragBegan: 100) == tookOver)
    }

    /// Without a confirmed key window the input falls back to activation, which an active user blocks.
    @Test(arguments: [
        (true, true, 0.5, ComputerUseEventRoute.background),
        (true, false, 5.0, .activation),
        (false, true, 5.0, .activation),
        (true, false, 0.5, .refuse),
        (false, false, 0.5, .refuse),
    ])
    private func eventRoutes(skyLight: Bool, confirmed: Bool, idle: TimeInterval, expected: ComputerUseEventRoute) {
        #expect(ComputerUseEventRoute.choose(skyLightAvailable: skyLight, keyConfirmed: confirmed, idleSeconds: idle) == expected)
    }

    @Test(arguments: [
        (0, [.command]), (1, [.command, .shift]), (2, [.command, .option]), (4, [.command, .control]),
        (8, []), (12, [.control]), (7, [.command, .shift, .option, .control]),
    ] as [(Int, Set<Chord.Modifier>)])
    private func menuModifierMasks(mask: Int, modifiers: Set<Chord.Modifier>) {
        #expect(ComputerUseMenuShortcut.modifiers(mask: mask) == modifiers)
    }

    @Test(arguments: [
        ("cmd+s", "S", nil, 0, true),
        ("cmd+shift+s", "S", nil, 1, true),
        ("cmd+s", "S", nil, 1, false),
        ("ctrl+a", "A", nil, 12, true),
        ("fn+cmd+s", "S", nil, 0, false),
        ("cmd+return", "\r", nil, 0, true),
        // An arrow is reported as a private-use character; its virtual key decides.
        ("cmd+up", "\u{F700}", 126, 0, true),
        ("cmd+up", "\u{F700}", 125, 0, false),
        ("cmd+up", "u", 126, 0, false),
        // No modifiers attribute means command alone; the key compares trimmed and case-insensitively.
        ("cmd+a", "A", nil, nil, true),
        ("cmd+b", " b ", nil, nil, true),
        ("cmd+shift+a", "A", nil, nil, false),
        // Bit 4 is fn (globe): fn+ctrl+F ("Fill") is not ctrl+f.
        ("ctrl+f", "F", nil, 28, false),
        ("cmd+space", " ", nil, nil, true),
    ] as [(String, String?, Int?, Int?, Bool)])
    private func menuShortcutMatching(chord: String, cmdChar: String?, virtualKey: Int?, mask: Int?, matches: Bool) throws {
        let parsed = try #require(Chord.parse(chord))
        let chordKey = parsed.key == .named(.up) ? 126 : nil
        #expect(ComputerUseMenuShortcut.matches(
            parsed, cmdChar: cmdChar, virtualKey: virtualKey, mask: mask, chordVirtualKey: chordKey) == matches)
    }

    @Test(arguments: [("cmd+q", true), ("cmd+opt+q", true), ("cmd+shift+q", true), ("ctrl+q", false), ("q", false), ("cmd+w", false)])
    private func quitChords(text: String, quits: Bool) throws {
        #expect(ComputerUseMenuShortcut.isQuit(try #require(Chord.parse(text))) == quits)
    }

    @Test(arguments: [
        ("Cancel", true), (" cancelar ", true), ("ANNULER", true), ("キャンセル", true), ("İptal", true),
        ("Guardar", false), ("Cancel Download", false), ("", false),
    ])
    private func cancelTitles(title: String, isCancel: Bool) {
        #expect(ComputerUseDialogButton.isCancelTitle(title) == isCancel)
    }

    private typealias Link = (role: String, actions: [String])

    @Test(arguments: [
        // Static text in a button presses the button.
        ([("AXStaticText", []), ("AXButton", ["AXPress"]), ("AXGroup", [])], ComputerUseClickTarget.Choice.press(1)),
        // The element itself wins over a pressable parent.
        ([("AXLink", ["AXPress"]), ("AXButton", ["AXPress"])], .press(0)),
        // Static text in a cell in a row in an outline selects the row.
        ([("AXStaticText", []), ("AXCell", []), ("AXRow", []), ("AXOutline", [])], .selectRow(2)),
        // A pressable group above the row is never reached.
        ([("AXStaticText", []), ("AXCell", []), ("AXRow", []), ("AXGroup", ["AXPress"])], .selectRow(2)),
        // A toolbar stops the climb, and is not a row.
        ([("AXImage", []), ("AXToolbar", ["AXPress"]), ("AXButton", ["AXPress"])], .none),
        // Only four levels, counting the element, may be pressed.
        ([("AXStaticText", []), ("AXGroup", []), ("AXGroup", []), ("AXGroup", []), ("AXButton", ["AXPress"])], .none),
        ([("AXStaticText", []), ("AXGroup", []), ("AXGroup", []), ("AXButton", ["AXPress"])], .press(3)),
    ] as [([Link], ComputerUseClickTarget.Choice)])
    private func clickTargets(chain: [Link], expected: ComputerUseClickTarget.Choice) {
        #expect(ComputerUseClickTarget.choose(chain: chain) == expected)
    }
}
