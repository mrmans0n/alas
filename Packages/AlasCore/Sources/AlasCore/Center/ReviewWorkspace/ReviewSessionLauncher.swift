import Foundation

public enum ReviewSessionLauncher {
    @MainActor
    @discardableResult
    public static func openOrFocus(
        target: ReviewSessionTarget,
        now: () -> Date = Date.init,
        findActive: (ReviewSessionID) throws -> ReviewSessionRecord?,
        save: (ReviewSessionRecord) throws -> Void,
        open: (ReviewSessionRecord) -> Void,
        onFailure: ((any Error) -> Void)? = nil
    ) -> Bool {
        do {
            if var record = try findActive(target.id) {
                if record.target != target {
                    record.target = target
                    record.updatedAt = now()
                    try save(record)
                }
                open(record)
                return true
            }

            let createdAt = now()
            let record = ReviewSessionRecord(
                id: target.id,
                target: target,
                createdAt: createdAt,
                updatedAt: createdAt
            )
            try save(record)
            open(record)
            return true
        } catch {
            onFailure?(error)
            return false
        }
    }
}
