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
            document = try persistence.readIfExists(AttentionDocument.self, from: url) ?? AttentionDocument()
            loadError = nil
        } catch {
            document = AttentionDocument()
            loadError = error
        }
        writeError = nil
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
        guard document.events.contains(where: { $0.id == eventID }) else { return }
        document.acknowledgments[eventID] = AttentionAcknowledgment(eventID: eventID, acknowledgedAt: date)
        retain(at: date)
        persist()
    }

    func registerAlias(from legacyOwner: AttentionWorktreeIdentity, to lineageOwner: AttentionWorktreeIdentity) {
        guard legacyOwner != lineageOwner, document.aliases[legacyOwner] != lineageOwner else { return }
        document.aliases[legacyOwner] = lineageOwner
        persist()
    }

    func event(id: UUID) -> AttentionEvent? {
        document.events.first { $0.id == id }
    }

    private func retain(at date: Date) {
        let cutoff = date.addingTimeInterval(-resolvedRetention)
        document.events.removeAll { event in
            document.acknowledgments[event.id] != nil && event.occurredAt < cutoff
        }

        while document.events.count > maxEvents,
              let index = document.events.firstIndex(where: { document.acknowledgments[$0.id] != nil }) {
            document.events.remove(at: index)
        }
        while document.events.count > maxEvents {
            document.events.removeFirst()
        }

        let retainedIDs = Set(document.events.map(\.id))
        document.acknowledgments = document.acknowledgments.filter { retainedIDs.contains($0.key) }
        document.observations = document.observations.filter { _, observation in
            observation.isActive || observation.eventID.map(retainedIDs.contains) ?? false
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
