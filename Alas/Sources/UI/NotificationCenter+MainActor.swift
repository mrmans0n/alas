import Foundation

extension NotificationCenter {
    /// Registers a main-queue observer whose body runs main-actor-isolated.
    /// Sound because `queue: .main` guarantees the block is delivered on the
    /// main thread, which is where the main actor runs.
    func addMainActorObserver(
        forName name: Notification.Name,
        object: Any?,
        using body: @escaping @MainActor (Notification) -> Void
    ) -> any NSObjectProtocol {
        addObserver(forName: name, object: object, queue: .main) { note in
            MainActor.assumeIsolated { body(note) }
        }
    }
}
