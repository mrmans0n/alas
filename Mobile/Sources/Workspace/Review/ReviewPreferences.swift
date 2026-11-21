import AlasRemoteKit
import Foundation

/// Phone-wide review settings and the per-review viewed marks.
@MainActor @Observable
final class ReviewPreferences {
    static let shared = ReviewPreferences()
    private static let wrapsKey = "reviewWrapsLines"

    var wrapsLines: Bool = UserDefaults.standard.object(forKey: wrapsKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(wrapsLines, forKey: Self.wrapsKey) }
    }

    /// `scope` is the review session id, or `"commit." + sha`.
    func marks(for scope: String) -> ReviewViewedMarks {
        ReviewViewedMarks(stored: UserDefaults.standard.dictionary(forKey: "reviewViewed." + scope) as? [String: String] ?? [:])
    }

    func save(_ marks: ReviewViewedMarks, for scope: String) {
        UserDefaults.standard.set(marks.stored, forKey: "reviewViewed." + scope)
    }
}
