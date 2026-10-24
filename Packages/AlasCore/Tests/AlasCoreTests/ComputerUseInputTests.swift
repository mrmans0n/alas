import CoreGraphics
import Foundation
import Testing
import AlasModel
@testable import AlasPlatform

struct ComputerUseInputTests {
    private typealias Chord = ComputerUseKeyChord
    private typealias Window = ComputerUseInputGeometry.ScreenWindow
    private typealias SavedType = ComputerUsePastePolicy.SavedType

    @Test(arguments: [
        (ShortcutBinding?.some(.init(key: ".", modifiers: [.control, .option, .command])), true, true),
        (.some(.init(key: ".", modifiers: [.control, .option, .command])), false, false),
        (nil, true, false),
    ] as [(ShortcutBinding?, Bool, Bool)])
    func theStopShortcutIsRegisteredOnlyWhileAnAgentDrives(binding: ShortcutBinding?, driving: Bool, registered: Bool) {
        #expect((ComputerUseStopShortcut.registration(binding: binding, driverActive: driving) != nil) == registered)
    }

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
        ("cmd+delete", true), ("ctrl+y", true), ("ctrl+k", true), ("cmd+shift+v", true), ("cmd+opt+shift+v", true),
        ("cmd+a", false), ("return", false), ("tab", false), ("ctrl+tab", false),
    ])
    private func chordsThatMayEditText(text: String, edits: Bool) throws {
        #expect(try #require(Chord.parse(text)).mayEditText == edits)
    }

    /// A web field can read as focused in its page while the app's focused element is the
    /// address bar: a chord that may edit text is refused when any focused element is secure.
    @Test(arguments: [("ctrl+y", true), ("cmd+delete", true), ("shift+cmd+v", true), ("tab", false), ("return", false)])
    func editingChordsAreRefusedWhenAnyFocusedElementIsSecure(keys: String, refused: Bool) throws {
        let chord = try #require(Chord.parse(keys))
        let addressBar = ComputerUseSecureFocus.Element(role: "AXTextField")
        let password = ComputerUseSecureFocus.Element(role: "AXTextField", subrole: "AXSecureTextField")
        #expect(ComputerUseSecureFocus.refuses(chord, focused: [addressBar, password]) == refused)
        #expect(!ComputerUseSecureFocus.refuses(chord, focused: [addressBar]))
    }

    @Test(arguments: [
        (ComputerUseSecureFocus.Element(role: "AXTextField"), true),
        (.init(role: "AXTextArea"), true), (.init(role: "AXComboBox"), true), (.init(role: "AXSearchField"), true),
        (.init(role: "AXSecureTextField"), true), (.init(role: "AXTextField", subrole: "AXSecureTextField"), true),
        (.init(role: "AXButton"), false), (.init(role: "AXStaticText"), false), (.init(role: nil), false),
    ])
    func textEntryElementsAreRecognized(element: ComputerUseSecureFocus.Element, isTextEntry: Bool) {
        #expect(ComputerUseSecureFocus.isTextEntry(element) == isTextEntry)
    }

    /// Only a web page's field takes the click through AX focus; a native one keeps the plain click.
    @Test(arguments: [
        (ComputerUseSecureFocus.Element(role: "AXTextField"), true, true),
        (.init(role: "AXTextField", subrole: "AXSecureTextField"), true, true),
        (.init(role: "AXTextField"), false, false),
        (.init(role: "AXButton"), true, false),
    ])
    func onlyWebFieldsTakeClicksThroughFocus(element: ComputerUseSecureFocus.Element, inWebArea: Bool, focuses: Bool) {
        #expect(ComputerUseSecureFocus.focusesOnClick(element, inWebArea: inWebArea) == focuses)
    }

    @Test func pointsMapThroughTheScreenshotFrameAndAreBoundedByTheCurrentFrame() {
        let frame = CGRect(x: 100, y: 50, width: 800, height: 600)
        let pixel = CGPoint(x: 200, y: 100)
        #expect(ComputerUseInputGeometry.globalPoint(
            pixel: pixel, screenshotFrame: frame, scale: 2, currentFrame: frame
        ) == CGPoint(x: 200, y: 100))
        // Moved or resized since the screenshot, even where the old point stays inside.
        for current in [CGRect(x: 150, y: 50, width: 800, height: 600), CGRect(x: 100, y: 50, width: 900, height: 600)] {
            #expect(ComputerUseInputGeometry.globalPoint(
                pixel: pixel, screenshotFrame: frame, scale: 2, currentFrame: current
            ) == nil)
        }
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

    /// A ref click is refused only where inspect reports the element hidden; one without a size can't tell.
    @Test(arguments: [
        (CGRect(x: 10, y: 250, width: 100, height: 20), false),
        (CGRect(x: -150, y: 10, width: 200, height: 20), true),
        (CGRect(x: 10, y: 250, width: 0, height: 0), true),
    ])
    func elementsShowWhereAnyOfThemIsInsideTheClips(frame: CGRect, shown: Bool) {
        let clips = [CGRect(x: -200, y: 0, width: 700, height: 400), CGRect(x: 0, y: 0, width: 300, height: 200)]
        #expect(ComputerUseInputGeometry.isShown(frame, clippedTo: clips) == shown)
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

    @Test(arguments: [(0, true), (3, true), (8, true), (23, true), (24, false), (25, false), (500, false), (-2147483601, false)])
    func appWindowsSitBelowTheMenuBar(layer: Int, listed: Bool) {
        #expect(ComputerUseInputGeometry.isAppWindowLayer(layer) == listed)
    }

    /// An x/y input goes as events unless the app's own hit test finds another process's element
    /// at the point inside the window (a System Settings pane); then as AX there. Another
    /// process's element that doesn't hold the point is refused.
    @Test(arguments: [
        (Optional(Hit(pid: 10, frame: inner)), Route.events),
        (Hit(pid: 20, frame: inner), .ax),
        (Hit(pid: 20, frame: nil), .ax),
        // A row half scrolled out of the pane still holds the point.
        (Hit(pid: 20, frame: halfOut), .ax),
        (Hit(pid: 20, frame: elsewhere), .covered),
        (nil, .events),
    ] as [(Hit?, Route)])
    func pointInputsReachContentAnotherProcessDraws(appHit: Hit?, route: Route) {
        #expect(ComputerUseInputGeometry.pointRoute(
            point: CGPoint(x: 750, y: 100), targetPID: 10, window: CGRect(x: 0, y: 0, width: 800, height: 600),
            appHit: appHit) == route)
    }

    /// The app's hit test at a point it has nothing at answers with its menu bar or an element
    /// elsewhere: no hit. An unreadable frame still counts.
    @Test(arguments: [
        (String?("AXMenuBar"), Optional(CGRect(x: 0, y: 0, width: 1728, height: 33)), false),
        ("AXButton", CGRect(x: 740, y: 90, width: 20, height: 20), true),
        ("AXButton", CGRect(x: 0, y: 0, width: 20, height: 20), false),
        ("AXButton", nil, true),
    ])
    func aHitOnlyCountsWhereItHoldsThePoint(role: String?, frame: CGRect?, real: Bool) {
        #expect(ComputerUseInputGeometry.isRealHit(role: role, frame: frame, point: CGPoint(x: 750, y: 100)) == real)
    }

    /// In content another process draws, a click goes to the deepest pressable element at the
    /// point and a scroll to the deepest scroll area; neither to the window, and none means events.
    @Test(arguments: [
        (ComputerUseRemoteContent.Input.click, ["AXWindow", "AXScrollArea", "AXGroup", "AXButton", "AXStaticText"], Int?(3)),
        (.click, ["AXWindow", "AXScrollArea", "AXGroup", "AXStaticText"], nil),
        (.click, ["AXWindow"], nil),
        (.scroll, ["AXWindow", "AXScrollArea", "AXGroup", "AXScrollArea", "AXButton"], 3),
        (.scroll, ["AXWindow", "AXGroup"], nil),
    ])
    func remoteContentInputGoesToTheDeepestElementThatTakesIt(
        input: ComputerUseRemoteContent.Input, roles: [String], target: Int?
    ) {
        #expect(ComputerUseRemoteContent.target(for: input, path: roles.map { .init(role: $0) }) == target)
    }

    @Test func remoteContentClickAlsoTakesAnyElementWithAPress() {
        let path: [ComputerUseRemoteContent.Step] = [.init(role: "AXWindow"), .init(role: "AXGroup", actions: ["AXPress"]), .init(role: "AXImage")]
        #expect(ComputerUseRemoteContent.target(for: .click, path: path) == 1)
    }

    /// A point is on screen only on a display: AeroSpace parks hidden windows in the corner, with
    /// a 1-point sliver on the display.
    @Test(arguments: [
        (CGPoint(x: 500, y: 500), true),
        (CGPoint(x: 0, y: 0), true),
        (CGPoint(x: 1727.5, y: 1100), true),
        (CGPoint(x: 2562, y: 1148), false),
        (CGPoint(x: -800, y: 300), true),
        (CGPoint(x: -800, y: 1200), false),
    ])
    func pointsAreOnScreenOnlyOnADisplay(point: CGPoint, onScreen: Bool) {
        let displays = [CGRect(x: 0, y: 0, width: 1728, height: 1117), CGRect(x: -1920, y: -200, width: 1920, height: 1080)]
        #expect(ComputerUseInputGeometry.pointIsOnScreen(point, displays: displays) == onScreen)
    }

    /// A window is on screen when its centre or a quarter of it is: AeroSpace's 1-point sliver of a
    /// parked window isn't.
    @Test(arguments: [
        (CGRect(x: 100, y: 100, width: 800, height: 600), true),
        (CGRect(x: 1727, y: 1065, width: 876, height: 625), false),
        (CGRect(x: 1400, y: 100, width: 800, height: 600), true),
        (CGRect(x: 1500, y: 900, width: 800, height: 600), false),
        (CGRect(x: 3000, y: 3000, width: 100, height: 100), false),
    ])
    func windowsAreOnScreenWhenTheirCentreOrAQuarterIs(frame: CGRect, onScreen: Bool) {
        #expect(ComputerUseInputGeometry.frameIsOnScreen(frame, displays: [CGRect(x: 0, y: 0, width: 1728, height: 1117)]) == onScreen)
    }

    /// A key or text for an off-screen window goes only through AX, and only while that window is
    /// its app's focused one; never as events reported delivered.
    @Test(arguments: [
        (true, false, false, ComputerUseInputGeometry.OffScreenInput.events),
        (false, true, true, .ax),
        (false, true, false, .refuse),
        // Another of the app's windows is focused: its menu item or field isn't this window's.
        (false, false, true, .refuse),
    ])
    func inputForOffScreenWindowsGoesOnlyThroughAXWhileFocused(
        onScreen: Bool, focused: Bool, delivered: Bool, route: ComputerUseInputGeometry.OffScreenInput
    ) {
        #expect(ComputerUseInputGeometry.offScreenInput(
            windowOnScreen: onScreen, targetIsFocusedWindow: focused, deliveredThroughAX: delivered) == route)
    }

    typealias Hit = ComputerUseInputGeometry.PointHit
    typealias Route = ComputerUseInputGeometry.PointRoute
    private static let inner = CGRect(x: 200, y: 50, width: 600, height: 550)
    private static let halfOut = CGRect(x: 700, y: 50, width: 400, height: 300)
    private static let elsewhere = CGRect(x: 900, y: 400, width: 100, height: 100)

    /// A drag checks the user first, then activates; then, with its points read again, waits for
    /// parked or covered windows to come up, raises the drop window when the source covers it, and
    /// refuses an overlap, a hidden or off-screen point, or a cover that stays.
    @Test(arguments: [
        (0.5, false, State.offScreen, State.clear, false, 0.0, Step.userActive),
        (0.5, true, .clear, .clear, false, 0, .userActive),
        (60, false, .offScreen, .offScreen, false, 0, .activate),
        // A parked window comes back after activation.
        (60, true, .offScreen, .hidden, false, 0.2, .raiseSource),
        (60, true, .offScreen, .clear, false, 1, .offScreen),
        (60, true, .hidden, .clear, false, 1, .hidden(.start)),
        (60, true, .clear, .hidden, false, 1, .hidden(.end)),
        // Another app's window over the start until the source comes up.
        (60, true, .byOther, .clear, false, 0.3, .raiseSource),
        (60, true, .byOther, .clear, false, 1, .covered(.start)),
        // The same app's drop window over the start: the source is raised.
        (60, true, .byOtherDragWindow, .clear, false, 0.3, .raiseSource),
        (60, true, .clear, .byOtherDragWindow, false, 0.3, .raiseDrop),
        (60, true, .byOtherDragWindow, .clear, true, 0.3, .overlap),
        (60, true, .clear, .byOtherDragWindow, true, 0.3, .overlap),
        (60, true, .clear, .byOther, false, 1, .covered(.end)),
        (60, true, .clear, .clear, true, 0.3, .drag),
    ] as [(TimeInterval, Bool, State, State, Bool, TimeInterval, Step)])
    func dragsCheckTheUserThenActivateThenTheirPoints(
        idle: TimeInterval, activated: Bool, start: State, drop: State, raisedDrop: Bool, waited: TimeInterval, step: Step
    ) {
        #expect(ComputerUseTakeover.dragStep(
            idleSeconds: idle, activated: activated, start: start, drop: drop, raisedDrop: raisedDrop, waited: waited) == step)
    }

    typealias State = ComputerUseTakeover.DragPointState
    typealias Step = ComputerUseTakeover.DragStep

    @Test func dragsLookThroughIgnoredWindows() {
        // Alas's own overlay 3 is frontmost over both windows.
        let windows = [
            Window(id: 3, frame: CGRect(x: 0, y: 0, width: 400, height: 400)),
            Window(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            Window(id: 2, frame: CGRect(x: 200, y: 200, width: 100, height: 100)),
        ]
        let start = CGPoint(x: 20, y: 20), end = CGPoint(x: 220, y: 220)
        #expect(ComputerUseInputGeometry.coveredDragPoint(
            start: start, in: 1, end: end, in: 2, windows: windows, ignoring: [3]) == nil)
        #expect(ComputerUseInputGeometry.coveredDragPoint(
            start: start, in: 1, end: end, in: 2, windows: windows) == .start)
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

    /// A drag's activation that the user's typing elsewhere kept from the front reads as the user being active.
    @Test(arguments: [(0.5, ComputerUseTakeover.ActivationFailure.userActive), (1.9, .userActive), (2.0, .notFrontmost), (60.0, .notFrontmost)])
    func anActivationRefusedDuringUserInputIsTheUserBeingActive(idle: TimeInterval, failure: ComputerUseTakeover.ActivationFailure) {
        #expect(ComputerUseTakeover.activationFailure(idleSeconds: idle) == failure)
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
    /// no telling theirs from the drag's own, so that ends it too. Keys typed under Secure Input
    /// never reach the monitor, so the HID key time (`secureInputKeyAt`) counts as well.
    @Test(arguments: [
        (nil, nil, true), (99.0, nil, false), (101.0, nil, true),
        (99.0, 100.9, true), (99.0, 96.0, false),
    ] as [(TimeInterval?, TimeInterval?, Bool)])
    private func dragTakeover(lastUserInput: TimeInterval?, secureInputKeyAt: TimeInterval?, tookOver: Bool) {
        #expect(
            ComputerUseTakeover.tookOverDrag(
                lastUserInput: lastUserInput, dragBegan: 100, secureInputKeyAt: secureInputKeyAt) == tookOver)
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

    @Test(arguments: [
        // One plain-text item, in every flavour it may carry: pasted and put back.
        ([[SavedType(type: "public.utf16-external-plain-text", size: 24), SavedType(type: "public.utf8-plain-text", size: 12)]], true),
        ([], true),
        // A two-file Finder copy: file URLs and their names as text.
        ([[SavedType(type: "public.file-url", size: 40), SavedType(type: "public.utf8-plain-text", size: 14)],
          [SavedType(type: "public.file-url", size: 42), SavedType(type: "public.utf8-plain-text", size: 28)]], false),
        ([[SavedType(type: "public.png", size: 2_000_000), SavedType(type: "public.tiff", size: 30_000_000)]], false),
        ([[SavedType(type: "public.utf8-plain-text", size: 3)], [SavedType(type: "public.utf8-plain-text", size: 3)]], false),
        ([[SavedType(type: "public.rtf", size: 300), SavedType(type: "public.utf8-plain-text", size: 12)]], false),
        ([[SavedType(type: "public.utf8-plain-text", size: 5), SavedType(type: "dyn.ah62d4rv4ge8", size: nil)]], false),
        ([[SavedType(type: "public.utf8-plain-text", size: 20 * 1024 * 1024)]], false),
    ] as [([[ComputerUsePastePolicy.SavedType]], Bool)])
    func pastesOnlyOverAPlainTextClipboard(items: [[ComputerUsePastePolicy.SavedType]], pastes: Bool) {
        #expect(ComputerUsePastePolicy.canPaste(items) == pastes)
    }
}

@Suite struct ComputerUseCursorMotionTests {
    typealias Motion = ComputerUseCursorMotion

    @Test(arguments: [
        (CGPoint.zero, CGPoint.zero, Duration.milliseconds(300)),
        (CGPoint.zero, CGPoint(x: 750, y: 0), .milliseconds(350)),
        (CGPoint.zero, CGPoint(x: 3000, y: 4000), .milliseconds(400)),
    ] as [(CGPoint, CGPoint, Duration)])
    func glidesTakeThreeToFourHundredMilliseconds(from: CGPoint, to: CGPoint, expected: Duration) {
        #expect(Motion.glideDuration(from: from, to: to) == expected)
    }

    @Test func easingStartsAndEndsAtRestAndIsSymmetric() {
        #expect(Motion.eased(0) == 0)
        #expect(Motion.eased(1) == 1)
        #expect(Motion.eased(0.5) == 0.5)
        #expect(Motion.eased(-1) == 0 && Motion.eased(2) == 1)
        #expect(Motion.eased(0.1) < 0.1)
    }

    /// CG frames have a top-left origin on the primary display; AppKit's have a bottom-left one.
    @Test(arguments: [
        (CGRect(x: 100, y: 50, width: 400, height: 300), CGRect(x: 100, y: 650, width: 400, height: 300)),
        // A display above the primary one: negative CG y.
        (CGRect(x: 0, y: -500, width: 200, height: 100), CGRect(x: 0, y: 1400, width: 200, height: 100)),
        // A display left of the primary one.
        (CGRect(x: -800, y: 0, width: 200, height: 100), CGRect(x: -800, y: 900, width: 200, height: 100)),
    ] as [(CGRect, CGRect)])
    func cgFramesFlipAgainstThePrimaryDisplay(cg: CGRect, appKit: CGRect) {
        #expect(Motion.appKitFrame(fromCG: cg, primaryScreenHeight: 1000) == appKit)
    }

    /// Elements are glided to the centre of their part inside the clips, as an event click lands:
    /// the window (0, 0, 100, 100) and the scroll area (0, 0, 100, 80) holding them. With an outline.
    @Test(arguments: [
        (ComputerUseCursorInputKind.click, CGPoint(x: 5, y: 5), nil,
         ComputerUseCursorCue.glide(to: CGPoint(x: 5, y: 5), outline: nil, click: true)),
        (.scroll, CGPoint(x: 5, y: 5), nil, .glide(to: CGPoint(x: 5, y: 5), outline: nil, click: false)),
        (.click, nil, CGRect(x: 0, y: 0, width: 20, height: 10),
         .glide(to: CGPoint(x: 10, y: 5), outline: CGRect(x: 0, y: 0, width: 20, height: 10), click: true)),
        // Half of it scrolled below the scroll area's bottom edge.
        (.scroll, nil, CGRect(x: 0, y: 70, width: 20, height: 20),
         .glide(to: CGPoint(x: 10, y: 75), outline: CGRect(x: 0, y: 70, width: 20, height: 20), click: false)),
        // Wholly outside the clips: the pointer stays where it is rather than leave the panel.
        (.click, nil, CGRect(x: 200, y: 200, width: 20, height: 10), ComputerUseCursorCue.none),
        (.click, nil, CGRect(x: 0, y: 85, width: 20, height: 10), ComputerUseCursorCue.none),
        (.type, nil, CGRect(x: 0, y: 0, width: 20, height: 10), .outline(CGRect(x: 0, y: 0, width: 20, height: 10))),
        (.type, nil, nil, ComputerUseCursorCue.none),
        (.key, CGPoint(x: 5, y: 5), nil, ComputerUseCursorCue.none),
        (.drag, CGPoint(x: 5, y: 5), nil, .hide),
        (.click, nil, nil, ComputerUseCursorCue.none),
    ] as [(ComputerUseCursorInputKind, CGPoint?, CGRect?, ComputerUseCursorCue)])
    func eachInputGetsItsCue(kind: ComputerUseCursorInputKind, point: CGPoint?, frame: CGRect?, expected: ComputerUseCursorCue) {
        let clips = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 0, y: 0, width: 100, height: 80)]
        #expect(ComputerUseCursorCue.cue(for: kind, point: point, elementFrame: frame, clips: clips) == expected)
    }

    typealias Key = ComputerUseCursorWindowKey

    /// A glide starts where the pointer last was in that window, kept inside it if the window
    /// shrank, and at the centre of a window it hasn't been in.
    @Test(arguments: [
        (Key(pid: 1, windowID: 10), [Key(pid: 1, windowID: 10): CGPoint(x: 30, y: 40)], CGPoint(x: 30, y: 40)),
        (Key(pid: 1, windowID: 11), [Key(pid: 1, windowID: 10): CGPoint(x: 30, y: 40)], CGPoint(x: 100, y: 50)),
        // A recycled window id in another app is another window.
        (Key(pid: 2, windowID: 10), [Key(pid: 1, windowID: 10): CGPoint(x: 30, y: 40)], CGPoint(x: 100, y: 50)),
        (Key(pid: 1, windowID: 10), [:], CGPoint(x: 100, y: 50)),
        (Key(pid: 1, windowID: 10), [Key(pid: 1, windowID: 10): CGPoint(x: 500, y: -5)], CGPoint(x: 200, y: 0)),
    ] as [(Key, [Key: CGPoint], CGPoint)])
    func glidesStartWhereThePointerLastWasInThatWindow(window: Key, last: [Key: CGPoint], expected: CGPoint) {
        #expect(Motion.startPoint(in: window, size: CGSize(width: 200, height: 100), last: last) == expected)
    }
}

@Suite struct ComputerUseTextCheckTests {
    typealias Verdict = ComputerUseTextCheck.Verdict

    @Test(arguments: [
        // A Chromium field that reported success and kept its value, after ⌘A and at the caret.
        ("kotlin", "compose", (location: 0, length: 7), "compose", Verdict.unchanged),
        ("kotlin", "compose", (location: 7, length: 0), "compose", .unchanged),
        ("kotlin", "compose", (location: 7, length: 0), "composekotlin", .landed),
        ("kotlin", "compose", (location: 0, length: 7), "kotlin", .landed),
        // A field that formats what it takes still changed: typing again would double it.
        ("5551234", "", (location: 0, length: 0), "(555) 1234", .landed),
        // Text put over the same selected text leaves the value as it was.
        ("pose", "compose", (location: 3, length: 4), "compose", .landed),
        ("kotlin", nil, (location: 0, length: 0), "kotlin", .unknown),
        ("kotlin", "compose", nil, nil, .unknown),
    ] as [(String, String?, (location: Int, length: Int)?, String?, Verdict)])
    func anInsertLandedWhenTheValueChanged(
        inserted: String, before: String?, selection: (location: Int, length: Int)?, after: String?, verdict: Verdict
    ) {
        #expect(ComputerUseTextCheck.insert(inserted, before: before, selection: selection, after: after) == verdict)
    }

    @Test(arguments: [
        ("kotlin", "compose", "kotlin", Verdict.landed),
        ("kotlin", "compose", "compose", .unchanged),
        ("kotlin", "kotlin", "kotlin", .landed),
        ("5551234", "", "(555) 1234", .landed),
        ("kotlin", nil, "compose", .unknown),
        ("kotlin", "compose", nil, .unknown),
    ] as [(String, String?, String?, Verdict)])
    func aReplaceLandedWhenTheValueIsTheTextOrChanged(text: String, before: String?, after: String?, verdict: Verdict) {
        #expect(ComputerUseTextCheck.replace(with: text, before: before, after: after) == verdict)
    }
}
