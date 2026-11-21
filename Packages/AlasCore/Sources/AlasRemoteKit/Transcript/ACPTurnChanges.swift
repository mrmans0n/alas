import Foundation

/// The files one finished turn edited, drawn as a card under the turn's answer.
public struct ACPTurnChanges: Equatable, Sendable {
    public struct File: Equatable, Sendable {
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
        case user, agent, edit(File), other
    }

    /// Merged by path, in the order each was first edited.
    public let files: [File]

    public var added: Int { files.reduce(0) { $0 + $1.added } }
    public var removed: Int { files.reduce(0) { $0 + $1.removed } }

    public init(files: [File]) {
        self.files = files
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

        var edits: [File] = []
        var start = index - 1
        while start >= 0 {
            let current = item(start)
            if current == .user { break }
            if case .edit(let file) = current { edits.append(file) }
            start -= 1
        }
        // A paged window can start mid-turn, and the edits before it are not there to count.
        guard start >= 0, edits.count >= 2 else { return nil }

        var files: [File] = []
        var position: [String: Int] = [:]
        for edit in edits.reversed() {
            if let at = position[edit.path] {
                files[at].added += edit.added
                files[at].removed += edit.removed
            } else {
                position[edit.path] = files.count
                files.append(edit)
            }
        }
        return ACPTurnChanges(files: files)
    }
}
