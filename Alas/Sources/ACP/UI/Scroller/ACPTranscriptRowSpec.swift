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
}
