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
    public static func tookOverDrag(lastUserInput: TimeInterval?, dragBegan: TimeInterval) -> Bool {
        guard let lastUserInput else { return true }
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
