import Foundation

public enum ACPSessionAttachFreshness: Sendable {
    public static func isFresh(restoredFromPersistence: Bool, remoteSessionId: String?) -> Bool {
        !restoredFromPersistence && (remoteSessionId?.isEmpty ?? true)
    }
}
