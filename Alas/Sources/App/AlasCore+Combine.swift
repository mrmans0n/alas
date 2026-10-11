import Combine
import Foundation

// The app's SwiftUI views and Combine pipelines watch AlasCore types through
// these adapters; the package itself depends on neither framework.

extension ChangeSignal: @retroactive Publisher {
    public typealias Output = Value
    public typealias Failure = Never

    public func receive<S: Subscriber>(subscriber: S) where S.Input == Value, S.Failure == Never {
        let subject = PassthroughSubject<Value, Never>()
        let subscription = observe { subject.send($0) }
        subject
            .handleEvents(receiveCancel: { subscription.cancel() })
            .receive(subscriber: subscriber)
    }
}

/// Matches `@Published`'s publisher: the current value on subscription, then
/// each new value just before it is stored.
extension TrackedValue: @retroactive Publisher {
    public typealias Output = Value
    public typealias Failure = Never

    public func receive<S: Subscriber>(subscriber: S) where S.Input == Value, S.Failure == Never {
        let subject = CurrentValueSubject<Value, Never>(value)
        let subscription = signal.observe { subject.send($0) }
        subject
            .handleEvents(receiveCancel: { subscription.cancel() })
            .receive(subscriber: subscriber)
    }
}

private final class ObjectWillChangeBridge {
    let publisher = ObservableObjectPublisher()
    var subscription: ChangeSubscription?
}

extension ChangeSignal where Value == Void {
    /// The one `ObservableObjectPublisher` fed by this signal, so every
    /// subscriber, SwiftUI included, shares it.
    var objectWillChangePublisher: ObservableObjectPublisher {
        if let bridge = adapterStorage as? ObjectWillChangeBridge { return bridge.publisher }
        let bridge = ObjectWillChangeBridge()
        let publisher = bridge.publisher
        bridge.subscription = observe { publisher.send() }
        adapterStorage = bridge
        return publisher
    }
}

extension ACPComposerState: @retroactive ObservableObject {
    public nonisolated var objectWillChange: ObservableObjectPublisher { willChange.objectWillChangePublisher }
}

extension ACPDictationService: @retroactive ObservableObject {
    public nonisolated var objectWillChange: ObservableObjectPublisher { willChange.objectWillChangePublisher }
}

extension ACPSession: @retroactive ObservableObject {
    public nonisolated var objectWillChange: ObservableObjectPublisher { willChange.objectWillChangePublisher }
}

extension ACPSessionManager: @retroactive ObservableObject {
    public nonisolated var objectWillChange: ObservableObjectPublisher { willChange.objectWillChangePublisher }
}

extension ACPSubagentRun: @retroactive ObservableObject {
    public nonisolated var objectWillChange: ObservableObjectPublisher { willChange.objectWillChangePublisher }
}

extension ACPTerminal: @retroactive ObservableObject {
    public nonisolated var objectWillChange: ObservableObjectPublisher { willChange.objectWillChangePublisher }
}

extension ACPTerminalHost: @retroactive ObservableObject {
    public nonisolated var objectWillChange: ObservableObjectPublisher { willChange.objectWillChangePublisher }
}

extension ACPTranscript: @retroactive ObservableObject {
    public nonisolated var objectWillChange: ObservableObjectPublisher { willChange.objectWillChangePublisher }
}

extension ACPUpstreamReferenceStore: @retroactive ObservableObject {
    public nonisolated var objectWillChange: ObservableObjectPublisher { willChange.objectWillChangePublisher }
}

#if DEBUG
extension MemoryDiagnostics: @retroactive ObservableObject {
    public nonisolated var objectWillChange: ObservableObjectPublisher { willChange.objectWillChangePublisher }
}
#endif

extension NextPromptCoordinator: @retroactive ObservableObject {
    public nonisolated var objectWillChange: ObservableObjectPublisher { willChange.objectWillChangePublisher }
}

extension RemoteHostStatusStore: @retroactive ObservableObject {
    public nonisolated var objectWillChange: ObservableObjectPublisher { willChange.objectWillChangePublisher }
}

extension SessionSummaryCoordinator: @retroactive ObservableObject {
    public nonisolated var objectWillChange: ObservableObjectPublisher { willChange.objectWillChangePublisher }
}

extension StreamingText: @retroactive ObservableObject {
    public nonisolated var objectWillChange: ObservableObjectPublisher { willChange.objectWillChangePublisher }
}
