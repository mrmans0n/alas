import Foundation

/// Decides whether synthesized input may go ahead while the user may still be driving the Mac.
public enum ComputerUseTakeover {
    public static let idleThreshold: TimeInterval = 2
    public static let maxWait: TimeInterval = 10

    public enum Decision: Equatable, Sendable { case proceed, wait, refuse }

    /// `direct` means the activation fallback was requested (the target must be brought to the front).
    public static func decide(
        targetIsFrontmost: Bool, idleSeconds: TimeInterval, direct: Bool, waited: TimeInterval
    ) -> Decision {
        guard idleSeconds < idleThreshold else { return .proceed }
        if direct { return .refuse }
        guard targetIsFrontmost else { return .proceed }
        return waited < maxWait ? .wait : .refuse
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
        let fallback = ComputerUseTakeover.decide(
            targetIsFrontmost: false, idleSeconds: idleSeconds, direct: true, waited: 0)
        return fallback == .refuse ? .refuse : .activation
    }
}
