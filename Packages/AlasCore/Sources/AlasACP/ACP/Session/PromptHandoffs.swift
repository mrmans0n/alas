import Foundation
import os
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

#if DEBUG
public typealias ACPRemoteFileWriteForTesting = @MainActor (
    _ path: String,
    _ content: String,
    _ beforeRemoteWrite: @MainActor @Sendable () async throws -> Void
) async throws -> ACPFileWriter.Result
#endif

package struct QueueDispatchProvenancePersistenceError: LocalizedError {
    package var errorDescription: String? {
        "Could not save queued message dispatch state."
    }

    public init() {
    }
}

package final class QueueDispatchHandoffTracker: @unchecked Sendable {
    private enum State: Equatable {
        case provenancePending
        case handedOff
        case cancelled
    }

    private let lock = NSLock()
    private var states: [UUID: State] = [:]

    package func markProvenancePending(_ itemId: UUID) {
        lock.lock()
        states[itemId] = .provenancePending
        lock.unlock()
    }

    package func markHandedOff(_ itemId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch states[itemId] {
        case .provenancePending:
            states[itemId] = .handedOff
            return true
        case .cancelled:
            return false
        case .handedOff, nil:
            return true
        }
    }

    package func takeUnhandedItemIDs() -> Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        let unhanded = Set(states.compactMap { itemId, state in
            state == .provenancePending ? itemId : nil
        })
        for itemId in unhanded {
            states[itemId] = .cancelled
        }
        return unhanded
    }

    package func finish(_ itemId: UUID) {
        lock.lock()
        states[itemId] = nil
        lock.unlock()
    }

    public init() {}
}

/// Prompts whose request crossed the transport handoff, marked from the transport's own callback, which may run off
/// the main actor and before the prompt's continuation does. A transport reports a handoff even for a request it
/// failed to send, before or after resuming the failure, so a send failure is final: a later `mark` does not undo it.
public final class PromptHandoffs: @unchecked Sendable {
    private let lock = NSLock()
    private var promptIDs: Set<Int> = []
    private var unsentIDs: Set<Int> = []

    public func mark(_ promptID: Int) {
        lock.lock()
        if !unsentIDs.contains(promptID) { promptIDs.insert(promptID) }
        lock.unlock()
    }

    /// The send failed without the agent answering: the prompt never reached it.
    public func markUnsent(_ promptID: Int) {
        lock.lock()
        unsentIDs.insert(promptID)
        promptIDs.remove(promptID)
        lock.unlock()
    }

    public func contains(_ promptID: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return promptIDs.contains(promptID)
    }

    public func forget(below promptID: Int) {
        lock.lock()
        promptIDs = promptIDs.filter { $0 >= promptID }
        unsentIDs = unsentIDs.filter { $0 >= promptID }
        lock.unlock()
    }

    public init() {}
}
