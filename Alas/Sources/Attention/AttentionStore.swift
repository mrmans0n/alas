import Foundation
import Observation

@Observable
@MainActor
final class AttentionStore {
    private let url: URL
    private let persistence: any PersistenceStoreProtocol
    private let now: () -> Date
    private let maxEvents: Int
    private let resolvedRetention: TimeInterval

    private(set) var document: AttentionDocument
    private(set) var loadError: Error?
    private(set) var writeError: Error?

    init(
        url: URL = Paths.attentionEventsFile,
        persistence: any PersistenceStoreProtocol = PersistenceStore(),
        now: @escaping () -> Date = Date.init,
        maxEvents: Int = 2_000,
        resolvedRetention: TimeInterval = 30 * 86_400
    ) {
        self.url = url
        self.persistence = persistence
        self.now = now
        self.maxEvents = maxEvents
        self.resolvedRetention = resolvedRetention
        do {
            let result = try persistence.readIfExistsReportingRecovery(AttentionDocument.self, from: url)
            document = result.value ?? AttentionDocument()
            loadError = result.recoveryError
        } catch {
            document = AttentionDocument()
            loadError = error
        }
        writeError = nil
        retain(at: now())
    }

    var events: [AttentionEvent] { document.events }
    var acknowledgments: [UUID: AttentionAcknowledgment] { document.acknowledgments }

    func observe(_ observation: AttentionObservation, at date: Date) {
        switch observation {
        case .active(let signal):
            let previous = document.observations[signal.sourceKey]
            guard previous?.isActive != true || previous?.fingerprint != signal.fingerprint else {
                retryPersistingUnwrittenDocumentIfNeeded()
                return
            }
            if let previous,
               shouldUpdateActiveObservationWithoutNewEvent(sourceKey: signal.sourceKey, previousFingerprint: previous.fingerprint, currentFingerprint: signal.fingerprint) {
                document.observations[signal.sourceKey] = AttentionStoredObservation(
                    isActive: true,
                    fingerprint: signal.fingerprint,
                    eventID: previous.eventID
                )
                updateEvent(for: previous.eventID, with: signal)
                retain(at: date)
                persist()
                return
            }
            let event = AttentionEvent(signal: signal, occurredAt: date)
            document.events.append(event)
            document.observations[signal.sourceKey] = AttentionStoredObservation(
                isActive: true,
                fingerprint: signal.fingerprint,
                eventID: event.id
            )
        case .inactive(let sourceKey):
            guard let previous = document.observations[sourceKey],
                  previous.isActive != false
            else {
                retryPersistingUnwrittenDocumentIfNeeded()
                return
            }
            document.observations[sourceKey] = AttentionStoredObservation(
                isActive: false,
                fingerprint: nil,
                eventID: previous.eventID
            )
        }
        retain(at: date)
        persist()
    }

    func appendHistory(_ event: AttentionHistoryEvent, at date: Date? = nil) {
        let occurrenceDate = date ?? now()
        document.events.append(AttentionEvent(history: event, occurredAt: occurrenceDate))
        retain(at: occurrenceDate)
        persist()
    }

    func acknowledge(eventID: UUID, at date: Date) {
        acknowledge(eventIDs: [eventID], at: date)
    }

    func acknowledge(eventIDs: [UUID], at date: Date) {
        var changed = false
        let knownIDs = Set(document.events.map(\.id))
        for eventID in eventIDs where knownIDs.contains(eventID) && document.acknowledgments[eventID] == nil {
            document.acknowledgments[eventID] = AttentionAcknowledgment(eventID: eventID, acknowledgedAt: date)
            changed = true
        }
        guard changed else {
            retryPersistingUnwrittenDocumentIfNeeded()
            return
        }
        retain(at: date)
        persist()
    }

    func registerAlias(from legacyOwner: AttentionWorktreeIdentity, to lineageOwner: AttentionWorktreeIdentity) {
        registerAliases([(from: legacyOwner, to: lineageOwner)])
    }

    func registerAliases(_ aliases: [(from: AttentionWorktreeIdentity, to: AttentionWorktreeIdentity)], retryExisting: Bool = true) {
        var changed = false
        var sawExistingAlias = false
        for alias in aliases {
            guard alias.from != alias.to else { continue }
            if document.aliases[alias.from] == alias.to {
                sawExistingAlias = true
                changed = migrateObservations(from: alias.from, to: alias.to) || changed
                continue
            }
            if document.aliases[alias.from] != nil {
                changed = migrateObservations(from: alias.from, to: alias.to) || changed
                continue
            }
            document.aliases[alias.from] = alias.to
            _ = migrateObservations(from: alias.from, to: alias.to)
            changed = true
        }
        guard changed else {
            if sawExistingAlias, retryExisting { retryPersistingUnwrittenDocumentIfNeeded() }
            return
        }
        retain(at: now())
        persist()
    }

    func event(id: UUID) -> AttentionEvent? {
        document.events.first { $0.id == id }
    }

    private func retain(at date: Date) {
        let cutoff = date.addingTimeInterval(-resolvedRetention)
        let acknowledgedIDs = Set(document.acknowledgments.keys)
        document.events.removeAll { event in
            acknowledgedIDs.contains(event.id) && event.occurredAt < cutoff
        }

        while document.events.count > maxEvents,
              let index = oldestEventIndex(where: { document.acknowledgments[$0.id] != nil }) {
            document.events.remove(at: index)
        }
        while document.events.count > maxEvents,
              let index = oldestEventIndex(where: { !$0.requiresAction }) {
            document.events.remove(at: index)
        }
        while document.events.count > maxEvents {
            guard let index = oldestEventIndex(where: { document.acknowledgments[$0.id] == nil }) else { break }
            document.events.remove(at: index)
        }

        let retainedIDs = Set(document.events.map(\.id))
        document.acknowledgments = document.acknowledgments.filter { retainedIDs.contains($0.key) }
        document.observations = document.observations.filter { _, observation in
            observation.isActive || observation.eventID.map(retainedIDs.contains) ?? false
        }
        // Keep a bounded set of active tombstones after event pruning so an
        // unchanged, acknowledged occurrence can remain deduplicated on reload.
        let orphanKeys = document.observations.keys.filter {
            document.observations[$0]?.eventID.map(retainedIDs.contains) != true
        }.sorted { $0.rawValue < $1.rawValue }
        for key in orphanKeys.dropLast(maxEvents) { document.observations[key] = nil }

        // Resolve alias chains before trimming them: a retained event needs at
        // most one alias, regardless of how often its worktree was renamed.
        let referencedOwners = Set(document.events.map(\.owner))
        for owner in Array(document.aliases.keys) {
            var destination = document.aliases[owner]!
            var visited: Set<AttentionWorktreeIdentity> = [owner]
            while visited.insert(destination).inserted, let next = document.aliases[destination] {
                destination = next
            }
            document.aliases[owner] = destination
        }
        let aliasKeys = document.aliases.keys.sorted {
            if referencedOwners.contains($0) != referencedOwners.contains($1) { return referencedOwners.contains($0) }
            return $0.storageKey < $1.storageKey
        }
        for key in aliasKeys.dropFirst(maxEvents) { document.aliases[key] = nil }
    }

    private func oldestEventIndex(where predicate: (AttentionEvent) -> Bool) -> Int? {
        document.events.indices
            .filter { predicate(document.events[$0]) }
            .min { lhs, rhs in
                let lhsEvent = document.events[lhs]
                let rhsEvent = document.events[rhs]
                if lhsEvent.occurredAt != rhsEvent.occurredAt {
                    return lhsEvent.occurredAt < rhsEvent.occurredAt
                }
                return lhs < rhs
            }
    }

    @discardableResult
    private func migrateObservations(from legacyOwner: AttentionWorktreeIdentity, to lineageOwner: AttentionWorktreeIdentity) -> Bool {
        var changed = false
        var migratedSourceKeys: [(from: AttentionSourceKey, to: AttentionSourceKey)] = []
        for (sourceKey, observation) in document.observations {
            guard let migratedKey = migratedSourceKey(sourceKey, from: legacyOwner, to: lineageOwner),
                  migratedKey != sourceKey else { continue }
            migratedSourceKeys.append((from: sourceKey, to: migratedKey))
            if let existing = document.observations[migratedKey] {
                if observation.isActive, !existing.isActive {
                    document.observations[migratedKey] = observation
                }
            } else {
                document.observations[migratedKey] = observation
            }
            document.observations[sourceKey] = nil
            changed = true
        }
        for sourceKey in migratedSourceKeys {
            changed = migrateEvents(from: sourceKey.from, to: sourceKey.to, legacyOwner: legacyOwner, lineageOwner: lineageOwner) || changed
        }
        changed = rebindOwnerIndependentEvents(from: legacyOwner, to: lineageOwner) || changed
        return changed
    }

    @discardableResult
    private func rebindOwnerIndependentEvents(from legacyOwner: AttentionWorktreeIdentity, to lineageOwner: AttentionWorktreeIdentity) -> Bool {
        var changed = false
        for (sourceKey, observation) in document.observations {
            guard observation.isActive,
                  observation.eventID != nil,
                  migratedSourceKey(sourceKey, from: legacyOwner, to: lineageOwner) == nil
            else { continue }
            for index in document.events.indices {
                let event = document.events[index]
                guard event.owner == legacyOwner, event.sourceKey == sourceKey else { continue }
                document.events[index] = AttentionEvent(
                    id: event.id,
                    sourceKey: event.sourceKey,
                    fingerprint: event.fingerprint,
                    owner: lineageOwner,
                    kind: event.kind,
                    title: event.title,
                    body: event.body,
                    jumpTarget: event.jumpTarget,
                    display: event.display,
                    occurredAt: event.occurredAt,
                    requiresAction: event.requiresAction
                )
                changed = true
            }
        }
        return changed
    }

    private func migrateEvents(
        from legacySourceKey: AttentionSourceKey,
        to lineageSourceKey: AttentionSourceKey,
        legacyOwner: AttentionWorktreeIdentity,
        lineageOwner: AttentionWorktreeIdentity
    ) -> Bool {
        var changed = false
        for index in document.events.indices {
            let event = document.events[index]
            guard event.owner == legacyOwner, event.sourceKey == legacySourceKey else { continue }
            document.events[index] = AttentionEvent(
                id: event.id,
                sourceKey: lineageSourceKey,
                fingerprint: event.fingerprint,
                owner: lineageOwner,
                kind: event.kind,
                title: event.title,
                body: event.body,
                jumpTarget: event.jumpTarget,
                display: event.display,
                occurredAt: event.occurredAt,
                requiresAction: event.requiresAction
            )
            changed = true
        }
        return changed
    }

    private func migratedSourceKey(_ sourceKey: AttentionSourceKey, from legacyOwner: AttentionWorktreeIdentity, to lineageOwner: AttentionWorktreeIdentity) -> AttentionSourceKey? {
        let legacyKey = legacyOwner.storageKey
        let lineageKey = lineageOwner.storageKey
        for prefix in ["git:", "review:", "host:"] {
            let legacyPrefix = "\(prefix)\(legacyKey):"
            guard sourceKey.rawValue.hasPrefix(legacyPrefix) else { continue }
            return AttentionSourceKey(rawValue: "\(prefix)\(lineageKey):\(sourceKey.rawValue.dropFirst(legacyPrefix.count))")
        }
        return nil
    }

    private func shouldUpdateActiveObservationWithoutNewEvent(
        sourceKey: AttentionSourceKey,
        previousFingerprint: String?,
        currentFingerprint: String
    ) -> Bool {
        guard let previousFingerprint else { return false }
        if sourceKey.rawValue.hasSuffix(":conflicts") {
            return isNonEmptySetShrink(from: previousFingerprint, to: currentFingerprint)
        }
        if sourceKey.rawValue.hasSuffix(":checks") {
            return isCheckFailureSetShrink(from: previousFingerprint, to: currentFingerprint)
        }
        if sourceKey.rawValue.hasSuffix(":feedback") {
            return isReviewFeedbackSetShrink(from: previousFingerprint, to: currentFingerprint)
        }
        return false
    }

    private func isCheckFailureSetShrink(from previousFingerprint: String, to currentFingerprint: String) -> Bool {
        let previousParts = previousFingerprint.split(separator: "|", omittingEmptySubsequences: false)
        let currentParts = currentFingerprint.split(separator: "|", omittingEmptySubsequences: false)
        guard previousParts.first == currentParts.first else { return false }
        return isStrictNonEmptySubset(
            Set(currentParts.dropFirst().map(String.init)),
            of: Set(previousParts.dropFirst().map(String.init))
        )
    }

    private func isReviewFeedbackSetShrink(from previousFingerprint: String, to currentFingerprint: String) -> Bool {
        let previousParts = previousFingerprint.split(separator: "|", omittingEmptySubsequences: false)
        let currentParts = currentFingerprint.split(separator: "|", omittingEmptySubsequences: false)
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

    private func isNonEmptySetShrink(from previousFingerprint: String, to currentFingerprint: String) -> Bool {
        isStrictNonEmptySubset(decodedFingerprintSet(currentFingerprint), of: decodedFingerprintSet(previousFingerprint))
    }

    private func decodedFingerprintSet(_ fingerprint: String) -> Set<String> {
        if let values = decodeLengthPrefixedFingerprintSet(fingerprint) {
            return Set(values)
        }
        return Set(fingerprint.split(separator: "|").map(String.init))
    }

    private func decodeLengthPrefixedFingerprintSet(_ fingerprint: String) -> [String]? {
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

    private func isStrictNonEmptySubset(_ current: Set<String>, of previous: Set<String>) -> Bool {
        !current.isEmpty && current.isStrictSubset(of: previous)
    }

    private func persist() {
        do {
            try persistence.write(document, to: url)
            writeError = nil
        } catch {
            writeError = error
        }
    }

    private func retryPersistingUnwrittenDocumentIfNeeded() {
        guard writeError != nil else { return }
        persist()
    }

    private func updateEvent(for eventID: UUID?, with signal: AttentionSignal) {
        guard let eventID,
              let index = document.events.firstIndex(where: { $0.id == eventID }) else { return }
        document.events[index] = AttentionEvent(
            id: eventID,
            signal: signal,
            occurredAt: document.events[index].occurredAt
        )
    }
}
