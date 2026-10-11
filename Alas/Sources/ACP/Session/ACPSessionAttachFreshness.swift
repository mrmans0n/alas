import Foundation

enum ACPSessionAttachFreshness {
    static func isFresh(restoredFromPersistence: Bool, remoteSessionId: String?) -> Bool {
        !restoredFromPersistence && (remoteSessionId?.isEmpty ?? true)
    }
}
