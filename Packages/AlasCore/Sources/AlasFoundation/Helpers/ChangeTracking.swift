import Foundation

/// A synchronous change stream that needs no Combine or SwiftUI. Observers run
/// in subscription order, on the sender's thread, before `send` returns.
public final class ChangeSignal<Value> {
    private var observers: [(id: UInt64, handler: (Value) -> Void)] = []
    private var nextID: UInt64 = 0

    /// Storage an adapter can use to cache its own bridge for this signal, so
    /// it hands every subscriber the same publisher.
    public var adapterStorage: AnyObject?

    public init() {}

    public func send(_ value: Value) {
        for observer in observers { observer.handler(value) }
    }

    /// Calls `handler` with every value sent until the subscription is
    /// cancelled or released.
    public func observe(_ handler: @escaping (Value) -> Void) -> ChangeSubscription {
        let id = nextID
        nextID &+= 1
        observers.append((id, handler))
        return ChangeSubscription { [weak self] in
            self?.observers.removeAll { $0.id == id }
        }
    }
}

extension ChangeSignal where Value == Void {
    public func send() { send(()) }
}

/// Ends an observation when cancelled or released.
public final class ChangeSubscription: Hashable {
    private var onCancel: (() -> Void)?

    public init(_ onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    deinit { cancel() }

    public func cancel() {
        let onCancel = onCancel
        self.onCancel = nil
        onCancel?()
    }

    public func store(in set: inout Set<ChangeSubscription>) {
        set.insert(self)
    }

    public static func == (lhs: ChangeSubscription, rhs: ChangeSubscription) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// An object that announces, just before any `@Tracked` property changes,
/// that it is about to change.
@MainActor
public protocol ChangeTracking: AnyObject {
    var willChange: ChangeSignal<Void> { get }
}

/// The value and change stream behind one `@Tracked` property. Its signal
/// fires with the new value before the property stores it.
public final class TrackedValue<Value> {
    public internal(set) var value: Value
    public let signal = ChangeSignal<Value>()

    init(_ value: Value) {
        self.value = value
    }
}

/// A stored property of a `ChangeTracking` object that announces changes:
/// setting it sends the owner's `willChange`, then `$property.signal` with the
/// new value, then stores the value.
@propertyWrapper
public struct Tracked<Value> {
    private let storage: TrackedValue<Value>

    public init(wrappedValue: Value) {
        storage = TrackedValue(wrappedValue)
    }

    @MainActor
    public static subscript<Owner: ChangeTracking>(
        _enclosingInstance owner: Owner,
        wrapped _: ReferenceWritableKeyPath<Owner, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<Owner, Self>
    ) -> Value {
        get { owner[keyPath: storageKeyPath].storage.value }
        set {
            let storage = owner[keyPath: storageKeyPath].storage
            owner.willChange.send()
            storage.signal.send(newValue)
            storage.value = newValue
        }
    }

    @available(*, unavailable, message: "@Tracked is only available on properties of ChangeTracking classes")
    public var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }

    public var projectedValue: TrackedValue<Value> { storage }
}
