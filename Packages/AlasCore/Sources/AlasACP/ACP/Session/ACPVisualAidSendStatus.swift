import Foundation
import Observation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// Delivery state of one visual aid's answer, kept on the session so a card
/// remounted after leaving the mount band still shows a failed send.
@MainActor
@Observable
public final class ACPVisualAidSendStatus {
    public static let failureMessage = "Couldn't send your answer. Try again."
    /// The answer was not sent and the question could not be stored as unanswered again.
    public static let unsavedMessage =
        "Couldn't send your answer, and its unanswered state could not be saved. After a reload this question may show as answered."

    public var error: String?

    public init() {}
}
