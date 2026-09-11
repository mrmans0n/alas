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
            guard previous?.isActive != true || previous?.fingerprint != signal.fingerprint else { return }
            let event = AttentionEvent(signal: signal, occurredAt: date)
            document.events.append(event)
            document.observations[signal.sourceKey] = AttentionStoredObservation(
                isActive: true,
                fingerprint: signal.fingerprint,
                eventID: event.id
            )
        case .inactive(let sourceKey):
            guard document.observations[sourceKey]?.isActive != false else { return }
            document.observations[sourceKey] = AttentionStoredObservation(
                isActive: false,
                fingerprint: nil,
                eventID: document.observations[sourceKey]?.eventID
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
        guard document.events.contains(where: { $0.id == eventID }), document.acknowledgments[eventID] == nil else { return }
        document.acknowledgments[eventID] = AttentionAcknowledgment(eventID: eventID, acknowledgedAt: date)
        retain(at: date)
        persist()
    }

    func registerAlias(from legacyOwner: AttentionWorktreeIdentity, to lineageOwner: AttentionWorktreeIdentity) {
        guard legacyOwner != lineageOwner, document.aliases[legacyOwner] != lineageOwner else { return }
        document.aliases[legacyOwner] = lineageOwner
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

    private func persist() {
        do {
            try persistence.write(document, to: url)
            writeError = nil
        } catch {
            writeError = error
        }
    }
}
