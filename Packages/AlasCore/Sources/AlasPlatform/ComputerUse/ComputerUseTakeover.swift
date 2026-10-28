import CoreGraphics
import Foundation

/// Decides whether synthesized input may go ahead while the user may still be driving the Mac.
public enum ComputerUseTakeover {
    public static let idleThreshold: TimeInterval = 2
    public static let maxWait: TimeInterval = 10

    public enum Decision: Equatable, Sendable { case proceed, wait, refuse }

    /// `direct` means the activation fallback was requested (the target must be brought to the
    /// front): it waits for an active user wherever they are, as a background input waits for one
    /// in the target app, and refuses after `maxWait`.
    public static func decide(
        targetIsFrontmost: Bool, idleSeconds: TimeInterval, direct: Bool, waited: TimeInterval
    ) -> Decision {
        guard idleSeconds < idleThreshold else { return .proceed }
        guard direct || targetIsFrontmost else { return .proceed }
        return waited < maxWait ? .wait : .refuse
    }

    /// Where one of a drag's points stands, read after activation.
    public enum DragPointState: Equatable, Sendable {
        /// Its element doesn't show (scrolled out of view, hidden), or isn't on screen yet.
        case hidden
        /// Off every display: its window is parked (another Space, an AeroSpace workspace).
        case offScreen
        /// Its own window is topmost there.
        case clear
        /// The drag's other window is over it: the drop window over the start, or the source over the drop.
        case byOtherDragWindow
        /// Another app's window, or another of the app's, is over it.
        case byOther
    }

    /// The next step of a drag, which always goes with the target app in front.
    public enum DragStep: Equatable, Sendable {
        /// The user is typing or using the mouse: refused before anything else happens.
        case userActive
        /// Bring the target to the front: a parked or covered window is expected until then.
        case activate
        /// Raise the source window (AXRaise, main), read the points again and look once more:
        /// a parked window comes back and windows come up a moment after the activation.
        case raiseSource
        /// The source window covers the drop point: raise the drop window once.
        case raiseDrop
        case hidden(ComputerUseInputGeometry.DragPoint)
        case offScreen
        /// The two windows overlap at the points: one can't show without covering the other.
        case overlap
        case covered(ComputerUseInputGeometry.DragPoint)
        case drag
    }

    /// How long a drag's windows get after activation to come back on screen and up.
    public static let dragSettleWait: TimeInterval = 1

    /// User activity first, then activation; then, with the points read again after it, their
    /// visibility, the start point's coverage (raising the source window) and the drop point's
    /// (raising the drop window only when the source covers it). Each refusal only comes once
    /// `dragSettleWait` passed, except an overlap: raising either window then covers the other's point.
    public static func dragStep(
        idleSeconds: TimeInterval, activated: Bool, start: DragPointState, drop: DragPointState, raisedDrop: Bool,
        waited: TimeInterval
    ) -> DragStep {
        if idleSeconds < idleThreshold { return .userActive }
        guard activated else { return .activate }
        let settling = waited < dragSettleWait
        let unresolved: [DragPointState] = [.hidden, .offScreen]
        if unresolved.contains(start) || unresolved.contains(drop) {
            if settling { return .raiseSource }
            if start == .offScreen || drop == .offScreen { return .offScreen }
            return .hidden(start == .hidden ? .start : .end)
        }
        switch start {
        case .byOtherDragWindow where raisedDrop: return .overlap
        case .byOtherDragWindow, .byOther: return settling ? .raiseSource : .covered(.start)
        default: break
        }
        switch drop {
        case .byOtherDragWindow: return raisedDrop ? .overlap : .raiseDrop
        case .byOther: return settling ? .raiseSource : .covered(.end)
        default: return .drag
        }
    }

    /// What refuses a drag that goes to the front before its app is brought there, from the
    /// windows' frames now and the points as resolved in them (nil: the element doesn't show).
    /// Only windows on screen are judged: a parked one (another Space, an AeroSpace workspace)
    /// comes back with the activation, maybe elsewhere, so `dragStep` judges it after. A hidden
    /// element or a point off every display in a window on screen stays so; two windows of the
    /// drag where each covers the other's point (one stacked on the other) can't both show.
    /// Coverage by other windows is left for after the activation, which raises the app's.
    public static func dragRefusalBeforeActivation(
        start: CGPoint?, end: CGPoint?, sourceFrame: CGRect, dropFrame: CGRect, sameWindow: Bool, displays: [CGRect]
    ) -> DragStep? {
        let sourceShows = ComputerUseInputGeometry.frameIsOnScreen(sourceFrame, displays: displays)
        let dropShows = ComputerUseInputGeometry.frameIsOnScreen(dropFrame, displays: displays)
        if sourceShows {
            guard let start else { return .hidden(.start) }
            if !ComputerUseInputGeometry.pointIsOnScreen(start, displays: displays) { return .offScreen }
        }
        if dropShows {
            guard let end else { return .hidden(.end) }
            if !ComputerUseInputGeometry.pointIsOnScreen(end, displays: displays) { return .offScreen }
        }
        if !sameWindow, sourceShows, dropShows, let start, let end,
           dropFrame.contains(start), sourceFrame.contains(end) {
            return .overlap
        }
        return nil
    }

    /// Whether an input brought its app to the front, whatever way it went: the system activated
    /// it, or it wasn't frontmost before the input and is after.
    public static func broughtForward(activated: Bool, frontmostBefore: Bool, frontmostAfter: Bool) -> Bool {
        activated || (!frontmostBefore && frontmostAfter)
    }

    /// Why an activation didn't bring the target to the front in time.
    public enum ActivationFailure: Equatable, Sendable {
        /// The user's input in the last `idleThreshold` kept the front (macOS doesn't take it from
        /// an app the user is typing in): the agent should wait, not retry.
        case userActive
        case notFrontmost
    }

    public static func activationFailure(idleSeconds: TimeInterval) -> ActivationFailure {
        idleSeconds < idleThreshold ? .userActive : .notFrontmost
    }

    /// Whether an activation macOS ignored may be forced through WindowServer: only while the user
    /// is idle, and while the app that was in front still is (`previousIsFront` false: the user
    /// switched apps meanwhile; nil: unknown). Otherwise the activation fails as `activationFailure` says.
    public static func forcesActivation(idleSeconds: TimeInterval, previousIsFront: Bool?) -> Bool {
        idleSeconds >= idleThreshold && previousIsFront != false
    }

    /// Seconds since the user's own input: from the input monitor's last event (`lastUserInput`,
    /// on the same clock as `now`), which events Alas posts never reach; the HID idle time, which
    /// counts those too, only while the monitor isn't running (nil).
    /// `secureInputKeyIdle`: the HID idle time for keys while Secure Event Input is on (nil when
    /// off). The monitor gets no key events then, so a user typing a password would read as idle.
    public static func userIdleSeconds(
        now: TimeInterval, lastUserInput: TimeInterval?, hidIdle: TimeInterval, secureInputKeyIdle: TimeInterval? = nil
    ) -> TimeInterval {
        guard let lastUserInput else { return hidIdle }
        let monitored = max(0, now - lastUserInput)
        return secureInputKeyIdle.map { min(monitored, $0) } ?? monitored
    }

    /// Whether the user took over a drag under way since `dragBegan`: any input of theirs since
    /// then, or the input monitor no longer running (`lastUserInput` nil), since the HID idle
    /// time counts the drag's own events and can't tell the user's from them.
    /// `secureInputKeyAt`: the time of the last key press while Secure Event Input is on (nil when
    /// off), on the same clock; the monitor gets no keys then, so it counts separately.
    public static func tookOverDrag(
        lastUserInput: TimeInterval?, dragBegan: TimeInterval, secureInputKeyAt: TimeInterval? = nil
    ) -> Bool {
        guard let lastUserInput else { return true }
        if let secureInputKeyAt, secureInputKeyAt > dragBegan { return true }
        return lastUserInput > dragBegan
    }
}

/// How a background input that AX couldn't deliver reaches the app.
public enum ComputerUseEventRoute: Equatable, Sendable {
    /// Events posted to the target window once it is its app's key window, without activating the app.
    case background
    /// The app is activated around the events, as `delivery: "direct"` does.
    case activation
    /// The activation fallback would take the screen from a user who is active.
    case refuse

    /// `keyConfirmed`: the app reported the target window as its key window after the attempt.
    public static func choose(skyLightAvailable: Bool, keyConfirmed: Bool, idleSeconds: TimeInterval) -> Self {
        if skyLightAvailable, keyConfirmed { return .background }
        // The coordinator already waited for an idle user; one who is back now isn't waited out again.
        return idleSeconds < ComputerUseTakeover.idleThreshold ? .refuse : .activation
    }
}

/// Tells the user's input from what other processes post, for the input monitor. Alas's posts
/// (its marker) never count. Hardware events carry source pid 0. A single pointer move another
/// process posts (a window manager centring the cursor on the focused window, as AeroSpace does on
/// every focus change) isn't the user's; a stream of them is (Universal Control, Sidecar, Screen
/// Sharing, assistive pointers), from its second move on. Keys, clicks, drags and scrolls count from
/// any source: a remote-control user's are theirs. Used on one thread, the monitor's.
public struct ComputerUsePostedMoves: Sendable {
    /// A posted move counts when the same process posted another this soon before it.
    public static let followWindow: TimeInterval = 0.1

    private var lastMove: (pid: Int64, at: TimeInterval)?

    public init() {}

    /// Whether the event seen at `now` (seconds, any monotonic clock) is the user's.
    public mutating func countsAsUserInput(type: CGEventType, sourcePID: Int64, isAlasPosted: Bool, now: TimeInterval) -> Bool {
        if isAlasPosted { return false }
        guard type == .mouseMoved, sourcePID != 0 else { return true }
        defer { lastMove = (sourcePID, now) }
        guard let lastMove, lastMove.pid == sourcePID else { return false }
        return now - lastMove.at <= Self.followWindow
    }
}
