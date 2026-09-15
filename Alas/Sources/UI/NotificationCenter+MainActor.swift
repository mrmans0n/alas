import Foundation

extension NotificationCenter {
    /// Registers a main-queue observer whose body runs main-actor-isolated.
    /// Sound because `queue: .main` guarantees the block is delivered on the
    /// main thread, which is where the main actor runs.
    ///
    /// The body takes no `Notification`: `Notification` is not `Sendable`
    /// (its `object` and `userInfo` are untyped references), so handing it to
    /// the main actor from the nonisolated delivery block would be sending a
    /// non-`Sendable` value across isolation. Every observer that only needs
    /// "this fired" uses this overload; the one that needs to identify the
    /// posting object uses `addMainActorObjectObserver` below, which crosses
    /// only a `Sendable` identity.
    func addMainActorObserver(
        forName name: Notification.Name,
        object: Any?,
        using body: @escaping @MainActor @Sendable () -> Void
    ) -> any NSObjectProtocol {
        addObserver(forName: name, object: object, queue: .main) { _ in
            MainActor.assumeIsolated { body() }
        }
    }

    /// Variant for observers registered with `object: nil` that still need to
    /// filter by the posting object. Only the object's `ObjectIdentifier` —
    /// which is `Sendable` — crosses into the main actor, so the notification
    /// itself never leaves the delivery block. Compare the value against
    /// `ObjectIdentifier(someObject)` inside the body.
    ///
    /// The identity is `nil` when the notification carried no object.
    /// A distinct base name rather than an overload: both bodies are usually
    /// written as trailing closures, where the argument label disappears.
    func addMainActorObjectObserver(
        forName name: Notification.Name,
        object: Any?,
        using body: @escaping @MainActor @Sendable (ObjectIdentifier?) -> Void
    ) -> any NSObjectProtocol {
        addObserver(forName: name, object: object, queue: .main) { note in
            let identity = note.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated { body(identity) }
        }
    }
}
