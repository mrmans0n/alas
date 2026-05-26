import Foundation

/// Pure-logic helpers for the Draft Commit tab's Amend prefill behavior.
/// Extracted from `DraftCommitTabView`'s `@State` so the rules can be
/// exercised without instantiating a SwiftUI view.
enum DraftAmendPrefill {
    /// Decide whether to apply a HEAD prefill given the current draft.
    /// Returns the new draft fields when prefill should happen, or nil
    /// when the user has already typed something (preserve their draft).
    static func apply(
        priorSubject: String,
        priorBody: String,
        currentSubject: String,
        currentBody: String
    ) -> (subject: String, body: String)? {
        let blankSubject = currentSubject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let blankBody = currentBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard blankSubject && blankBody else { return nil }
        return (priorSubject, priorBody)
    }

    /// Decide whether to clear a prior prefill when the user toggles Amend off.
    /// Returns true iff the current draft is still byte-identical to the
    /// values we prefilled — in which case it's safe to wipe. If the user
    /// edited even one character of either field, the clear is suppressed
    /// so we don't clobber their work.
    static func shouldClear(
        wasPrefilled: Bool,
        prefilledSubject: String,
        prefilledBody: String,
        currentSubject: String,
        currentBody: String
    ) -> Bool {
        guard wasPrefilled else { return false }
        return currentSubject == prefilledSubject && currentBody == prefilledBody
    }
}
