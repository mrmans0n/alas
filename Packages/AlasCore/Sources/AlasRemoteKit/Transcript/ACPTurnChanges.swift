import Foundation

/// The files one finished turn edited, drawn as a card under the turn's answer.
public struct ACPTurnChanges: Equatable, Sendable {
    public struct File: Hashable, Sendable {
        public let path: String
        public var added: Int
        public var removed: Int

        public init(path: String, added: Int, removed: Int) {
            self.path = path
            self.added = added
            self.removed = removed
        }
    }

    /// The facts about one transcript message the card reads.
    public enum Item: Equatable, Sendable {
        case user, agent, other
        /// A file write the client handled for the agent.
        case fileEdit(File)
        /// What a finished tool call reported writing; see `written(by:worktreeRoot:)`.
        case toolCallEdits([File])
    }

    /// The patches a completed tool call wrote, by path relative to `worktreeRoot`. Proposed changes,
    /// unreadable patches and failed calls change nothing.
    public static func written(by call: ACPToolCall, worktreeRoot: String?) -> [File] {
        guard call.status == "completed" else { return [] }
        return call.diffs.filter { $0.source == .toolCall && $0.isValid }.map {
            File(path: ACPToolCallPresentation.displayPath($0.path, worktreeRoot: worktreeRoot),
                 added: $0.added, removed: $0.removed)
        }
    }

    /// Merged by path, in the order each was first edited.
    public let files: [File]
    /// Where the turn starts: its user message.
    public let userIndex: Int

    public var added: Int { files.reduce(0) { $0 + $1.added } }
    public var removed: Int { files.reduce(0) { $0 + $1.removed } }

    public init(files: [File], userIndex: Int) {
        self.files = files
        self.userIndex = userIndex
    }

    /// The changes of the turn whose answer is at `index`: the last agent message before the next
    /// user message, or before the end once the turn is over. Nil for any other row, and for a turn
    /// with fewer than two edits, whose one edit card already says it all, or whose user message is not
    /// in `item`. Reads only that turn.
    public static func forAnswer(
        at index: Int, count: Int, isTurnActive: Bool, item: (Int) -> Item
    ) -> ACPTurnChanges? {
        guard (0..<count).contains(index), item(index) == .agent else { return nil }
        var next = index + 1
        while next < count {
            let following = item(next)
            if following == .user { break }
            if following == .agent { return nil }
            next += 1
        }
        if next == count, isTurnActive { return nil }

        // Walking back from the answer, so newest first.
        var edits: [(file: File, fromToolCall: Bool)] = []
        var start = index - 1
        while start >= 0 {
            let current = item(start)
            if current == .user { break }
            switch current {
            case .fileEdit(let file): edits.append((file, false))
            case .toolCallEdits(let files): edits += files.reversed().map { ($0, true) }
            default: break
            }
            start -= 1
        }
        // An adapter can report a write as a patch on its tool call and also make it through the
        // client, so a path a tool call reports leaves out the turn's file writes to it.
        let reported = Set(edits.filter(\.fromToolCall).map(\.file.path))
        edits.removeAll { !$0.fromToolCall && reported.contains($0.file.path) }
        // A paged window can start mid-turn, and the edits before it are not there to count.
        guard start >= 0, edits.count >= 2 else { return nil }

        var files: [File] = []
        var position: [String: Int] = [:]
        for edit in edits.reversed().map(\.file) {
            if let at = position[edit.path] {
                files[at].added += edit.added
                files[at].removed += edit.removed
            } else {
                position[edit.path] = files.count
                files.append(edit)
            }
        }
        return ACPTurnChanges(files: files, userIndex: start)
    }
}
