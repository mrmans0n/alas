import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public enum ACPSessionAttachFreshness: Sendable {
    public static func isFresh(restoredFromPersistence: Bool, remoteSessionId: String?) -> Bool {
        !restoredFromPersistence && (remoteSessionId?.isEmpty ?? true)
    }
}
