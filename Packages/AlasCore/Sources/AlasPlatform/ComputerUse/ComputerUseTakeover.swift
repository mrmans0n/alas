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
