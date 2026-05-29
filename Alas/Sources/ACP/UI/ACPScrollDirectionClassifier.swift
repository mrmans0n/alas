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
    /// noise; anything larger is treated as user intent.
    static let upwardEpsilon: CGFloat = 0.5

    /// Distance from the bottom of the document at which the user is
    /// considered to be "at the tail." Matches the prior `tailTolerance`.
    static let bottomTolerance: CGFloat = 36

    static func decide(
        previousOffsetY: CGFloat?,
        newOffsetY: CGFloat,
        viewportHeight: CGFloat,
        contentHeight: CGFloat,
        isRestoring: Bool,
        isUserDriven: Bool = false
    ) -> ACPScrollDecision {
        if isRestoring {
            return isUserDriven ? .userScrolledUp : .noChange
        }
        let distanceFromBottom = max(0, contentHeight - viewportHeight - newOffsetY)
        if distanceFromBottom <= bottomTolerance { return .userAtBottom }
        guard let prev = previousOffsetY else { return .noChange }
        if newOffsetY < prev - upwardEpsilon { return .userScrolledUp }
        return .noChange
    }
}
