import SwiftUI

/// Type-erased Equatable. Replaces the legacy `.equatable()` row gating:
/// the hosting pool skips a rootView update (and re-measure) when the new
/// token equals the old one.
struct ACPRowEqualityToken {
    private let base: Any
    private let equalsBase: (Any) -> Bool

    init<T: Equatable>(_ value: T) {
        base = value
        equalsBase = { ($0 as? T) == value }
    }

    func isEqual(to other: ACPRowEqualityToken) -> Bool {
        equalsBase(other.base)
    }
}

/// One row the AppKit scroller should display: a stable identity, an
/// equality token deciding whether hosted content must be rebuilt, and a
/// deferred SwiftUI builder (only invoked when the row is actually mounted).
struct ACPTranscriptRowSpec {
    let id: String
    let equalityToken: ACPRowEqualityToken
    let build: () -> AnyView

    /// Whether this row's hosting view must stay mounted even while entirely
    /// outside the reconciler's mount band. Message rows are stateless
    /// renderings of transcript data — releasing their hosting view and
    /// rebuilding it later is harmless. A handful of synthetic rows are not:
    /// they carry view-local `@State`/`@FocusState` (an in-progress form,
    /// most notably `ACPUserInputPrompt`'s `formState`) that a fresh
    /// `NSHostingView` would silently discard. Set `true` only for rows that
    /// actually hold such state; the reconciler unions these into the mount
    /// band's `keep` set without expanding the band itself, so the exemption
    /// stays small and bounded (at most a handful of live prompts) rather
    /// than defeating the mount band's memory bound.
    var keepsMountedOffscreen: Bool = false
}
