import CoreGraphics

/// Outcome of classifying a single scroll-position observation.
enum ACPScrollDecision: Equatable {
    case noChange
    case userScrolledUp
    case userAtBottom
}

/// Pure decision logic shared by `ACPScrollEventObserver`. Kept free of
/// AppKit/SwiftUI so it can be exercised in unit tests.
enum ACPScrollDirectionClassifier {
    /// Sub-pixel jitter is ignored. 0.5pt comfortably covers Retina rounding
    /// noise; anything larger can be treated as deliberate direction.
    static let upwardEpsilon: CGFloat = 0.5

    /// Distance from the bottom of the document at which the user is
    /// considered to be "at the tail." Matches the prior `tailTolerance`.
    static let bottomTolerance: CGFloat = 36

    /// Distance from the bottom before an upward scroll pauses tail following.
    /// Roughly eight transcript text lines: enough to filter trackpad/layout
    /// micro-hops while still respecting a deliberate scroll away.
    static let pauseTolerance: CGFloat = 160

    static func decide(
        previousOffsetY: CGFloat?,
        newOffsetY: CGFloat,
        viewportHeight: CGFloat,
        contentHeight: CGFloat,
        isRestoring: Bool,
        isUserDriven: Bool = false
    ) -> ACPScrollDecision {
        let distanceFromBottom = max(0, contentHeight - viewportHeight - newOffsetY)
        if distanceFromBottom <= bottomTolerance { return .userAtBottom }
        guard let prev = previousOffsetY else { return .noChange }
        let movedUp = newOffsetY < prev - upwardEpsilon
        guard distanceFromBottom > pauseTolerance, movedUp else { return .noChange }
        if isRestoring && !isUserDriven { return .noChange }
        return .userScrolledUp
    }
}
