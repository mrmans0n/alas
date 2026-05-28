import Foundation

struct QueuedPrompt: Identifiable, Equatable, Codable {
    enum Status: String, Codable, Equatable { case pending, sending }

    let id: UUID
    var blocks: [ACPContentBlock]
    let enqueuedAt: Date
    var status: Status
    var lastError: String?
    /// Set the first time `sendNow` dispatches this item: the user prompt
    /// has been appended to the transcript. Retries (after `lastError`)
    /// don't re-record it, so the message list doesn't grow a duplicate
    /// user bubble per retry. Persisted so a relaunch-mid-attempt
    /// doesn't double-record either.
    var transcriptRecorded: Bool

    init(id: UUID = UUID(),
         blocks: [ACPContentBlock],
         enqueuedAt: Date = Date(),
         status: Status = .pending,
         lastError: String? = nil,
         transcriptRecorded: Bool = false)
    {
        self.id = id
        self.blocks = blocks
        self.enqueuedAt = enqueuedAt
        self.status = status
        self.lastError = lastError
        self.transcriptRecorded = transcriptRecorded
    }

    enum CodingKeys: String, CodingKey {
        case id, blocks, enqueuedAt, status, lastError, transcriptRecorded
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        blocks = try c.decode([ACPContentBlock].self, forKey: .blocks)
        enqueuedAt = try c.decode(Date.self, forKey: .enqueuedAt)
        status = try c.decode(Status.self, forKey: .status)
        lastError = try? c.decode(String.self, forKey: .lastError)
        transcriptRecorded = (try? c.decode(Bool.self, forKey: .transcriptRecorded)) ?? false
    }

    /// Used by the persistence decoder: any item that was mid-send when
    /// the app exited gets reset to `.pending` so the next flusher run
    /// re-attempts the prompt. `lastError` is preserved so a previously
    /// failed item that the user hasn't acked stays visibly errored.
    func normalizedAfterRestore() -> QueuedPrompt {
        guard status == .sending else { return self }
        var copy = self
        copy.status = .pending
        return copy
    }
}
