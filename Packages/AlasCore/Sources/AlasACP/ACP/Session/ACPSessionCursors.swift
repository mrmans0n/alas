import Foundation

/// A transcript row as the session cursors see it.
public enum ACPSessionCursorRow: Equatable, Sendable {
    /// A user message: its local id and the agent's id for it, when known.
    case user(id: UUID, messageId: String?)
    /// Something the agent can anchor a cursor to, other than a user message.
    case entity(ACPSessionCursor.Entity)
    /// A row the agent has no id for: a notice, a plan, a file edit.
    case other
}

/// The cursors a session's agent announced, and the user message each lies
/// before.
///
/// An agent places a cursor by an anchor. A replay anchors it `before` the
/// replayed user message. A live ACP v1 prompt is not echoed back, so its
/// cursor is anchored `after` the last entity the client holds, and the user
/// message is the one sent since.
public struct ACPSessionCursors: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let cursor: ACPSessionCursor
        /// The user row the cursor was matched to when it arrived, for a
        /// replay over rows that never learned the agent's message ids.
        public let userRow: UUID?
    }

    public private(set) var entries: [Entry] = []

    public init() {
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// A cursor replaces the one with its id, and the one with its anchor: a
    /// turn that reported nothing leaves the next prompt the same anchor, and
    /// the agent means the newer cursor.
    public mutating func record(_ cursor: ACPSessionCursor, userRow: UUID? = nil) {
        entries.removeAll { $0.cursor.cursorId == cursor.cursorId || $0.cursor.anchor == cursor.anchor }
        entries.append(.init(cursor: cursor, userRow: userRow))
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    /// The cursor before the user row `id`, if the agent announced one.
    public func cursor(beforeUserRow id: UUID, in rows: [ACPSessionCursorRow]) -> ACPSessionCursor? {
        guard let index = rows.firstIndex(where: { if case .user(id, _) = $0 { true } else { false } }) else { return nil }
        // The newest wins when two entries resolve to one row.
        return entries.last { userRowIndex(of: $0, in: rows) == index }?.cursor
    }

    /// Drops the cursors at and after row `index`: a rewind removed their
    /// messages. Cursors that match no row stay.
    public mutating func removeCursors(atOrAfterRow index: Int, in rows: [ACPSessionCursorRow]) {
        entries = entries.filter { entry in
            userRowIndex(of: entry, in: rows).map { $0 < index } ?? true
        }
    }

    private func userRowIndex(of entry: Entry, in rows: [ACPSessionCursorRow]) -> Int? {
        if let bound = entry.userRow {
            return rows.firstIndex { if case .user(bound, _) = $0 { true } else { false } }
        }
        let anchor = entry.cursor.anchor
        guard let anchored = rows.lastIndex(where: { Self.row($0, is: anchor.entity) }) else { return nil }
        switch anchor.position {
        case .before:
            if case .user = rows[anchored] { return anchored }
            return nil
        case .after:
            // The prompts sent since the anchor, up to the agent's next
            // output. The cursor is before the last: an earlier one belongs
            // to a turn that reported nothing, and its cursor was replaced.
            var candidate: Int?
            for index in rows.index(after: anchored)..<rows.endIndex {
                switch rows[index] {
                case .user: candidate = index
                case .entity: return candidate
                case .other: continue
                }
            }
            return candidate
        }
    }

    private static func row(_ row: ACPSessionCursorRow, is entity: ACPSessionCursor.Entity) -> Bool {
        switch (row, entity) {
        case (.user(_, let messageId?), .userMessage(let id)): messageId == id
        case (.entity(let held), _): held == entity
        default: false
        }
    }
}
