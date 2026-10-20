import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

/// The gate observations pass through on their way into the attention store.
/// When the store could not be loaded, the startup snapshot's signals are held
/// back instead of re-raising everything already seen before the failure. A
/// held signal stays held while it only shrinks, and is admitted once it
/// changes any other way.
@MainActor
public final class AttentionIntake {
    public let store: AttentionStore
    /// Startup signals held back while the store could not be loaded, with
    /// the fingerprint last seen for each source.
    public var suppressedStartupSignals: [AttentionSourceKey: String] = [:]
    /// Told about every active signal admitted to the store.
    public var onAdmit: (AttentionSignal) -> Void = { _ in }

    public init(store: AttentionStore) {
        self.store = store
    }

    public func observe(_ observation: AttentionObservation, at date: Date = Date()) {
        switch observation {
        case .active(let signal):
            if let suppressed = suppressedStartupSignals[signal.sourceKey] {
                if suppressed == signal.fingerprint {
                    return
                }
                if Self.isFingerprintShrink(sourceKey: signal.sourceKey, from: suppressed, to: signal.fingerprint) {
                    suppressedStartupSignals[signal.sourceKey] = signal.fingerprint
                    return
                }
                suppressedStartupSignals[signal.sourceKey] = nil
            }
            onAdmit(signal)
        case .inactive(let sourceKey):
            suppressedStartupSignals[sourceKey] = nil
        }
        store.observe(observation, at: date)
    }

    /// Observes a snapshot of every live signal. During the initial snapshot
    /// after a failed load, sources the store has no record of are held back.
    public func reconcile(observations: [AttentionObservation], isInitialSnapshot: Bool = true, at date: Date = Date()) {
        for observation in observations {
            guard let signal = observation.activeSignal else {
                observe(observation, at: date)
                continue
            }
            if isInitialSnapshot, store.loadError != nil,
               store.document.observations[signal.sourceKey] == nil,
               suppressedStartupSignals[signal.sourceKey] == nil {
                suppressedStartupSignals[signal.sourceKey] = signal.fingerprint
            }
            observe(.active(signal), at: date)
        }
    }

    /// Whether a source's fingerprint only lost members: fewer conflicts,
    /// fewer failing checks, or fewer feedback threads on the same head.
    public nonisolated static func isFingerprintShrink(
        sourceKey: AttentionSourceKey,
        from previous: String,
        to current: String
    ) -> Bool {
        if sourceKey.rawValue.hasSuffix(":conflicts") {
            return isStrictNonEmptySubset(decodedSet(current), of: decodedSet(previous))
        }
        if sourceKey.rawValue.hasSuffix(":checks") {
            return isHeadScopedSetShrink(from: previous, to: current, droppedPrefixCount: 1)
        }
        if sourceKey.rawValue.hasSuffix(":feedback") {
            return isHeadScopedThreadSetShrink(from: previous, to: current)
        }
        return false
    }

    private nonisolated static func isHeadScopedThreadSetShrink(from previous: String, to current: String) -> Bool {
        let previousParts = previous.split(separator: "|", omittingEmptySubsequences: false)
        let currentParts = current.split(separator: "|", omittingEmptySubsequences: false)
        guard previousParts.count >= 4,
              currentParts.count >= 3,
              previousParts[0] == currentParts[0],
              previousParts[1] == "decision",
              currentParts[1] == "decision",
              previousParts[2] == currentParts[2],
              previousParts[3] == "threads"
        else { return false }
        if currentParts.count == 3 {
            return true
        }
        guard currentParts[3] == "threads" else { return false }
        return isStrictNonEmptySubset(
            Set(currentParts.dropFirst(4).map(String.init)),
            of: Set(previousParts.dropFirst(4).map(String.init))
        )
    }

    private nonisolated static func isHeadScopedSetShrink(from previous: String, to current: String, droppedPrefixCount: Int) -> Bool {
        let previousParts = previous.split(separator: "|", omittingEmptySubsequences: false)
        let currentParts = current.split(separator: "|", omittingEmptySubsequences: false)
        guard previousParts.first == currentParts.first else { return false }
        return isStrictNonEmptySubset(
            Set(currentParts.dropFirst(droppedPrefixCount).map(String.init)),
            of: Set(previousParts.dropFirst(droppedPrefixCount).map(String.init))
        )
    }

    private nonisolated static func decodedSet(_ fingerprint: String) -> Set<String> {
        if let values = decodeLengthPrefixedSet(fingerprint) {
            return Set(values)
        }
        return Set(fingerprint.split(separator: "|").map(String.init))
    }

    private nonisolated static func decodeLengthPrefixedSet(_ fingerprint: String) -> [String]? {
        var index = fingerprint.startIndex
        var values: [String] = []
        while index < fingerprint.endIndex {
            guard let separator = fingerprint[index...].firstIndex(of: ":"),
                  let count = Int(fingerprint[index ..< separator])
            else { return nil }
            let valueStart = fingerprint.index(after: separator)
            guard let valueEnd = fingerprint.index(valueStart, offsetBy: count, limitedBy: fingerprint.endIndex)
            else { return nil }
            values.append(String(fingerprint[valueStart ..< valueEnd]))
            index = valueEnd
        }
        return values
    }

    private nonisolated static func isStrictNonEmptySubset(_ current: Set<String>, of previous: Set<String>) -> Bool {
        !current.isEmpty && current.isStrictSubset(of: previous)
    }
}
